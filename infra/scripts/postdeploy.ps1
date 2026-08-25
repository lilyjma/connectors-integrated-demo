Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    Write-Host "ERROR: The 'connector-namespace' Azure CLI extension is required." -ForegroundColor Red
    Write-Host "Install: irm https://aka.ms/connector-namespace-cli-install-ps | iex" -ForegroundColor Red
    exit 1
}

$outputs = azd env get-values --output json | ConvertFrom-Json

$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$sharepointConnectionName = $outputs.sharepointConnectionName
$teamsConnectionName = $outputs.teamsConnectionName
$functionAppName = $outputs.functionAppName
$subscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
$sharepointSiteUrl = $outputs.sharepointSiteUrl
$sharepointLibraryName = $outputs.sharepointLibraryName
$sharepointFolderPath = $outputs.sharepointFolderPath

if (-not $resourceGroupName -or -not $connectorNamespaceName -or -not $sharepointConnectionName -or `
    -not $teamsConnectionName -or -not $functionAppName -or -not $sharepointSiteUrl -or -not $sharepointLibraryName) {
    Write-Host "ERROR: required azd outputs missing. Run 'azd provision' first." -ForegroundColor Red
    exit 1
}

Write-Host "Fetching connector extension key for $functionAppName..." -ForegroundColor Cyan
$connectorExtensionKey = az functionapp keys list -g $resourceGroupName -n $functionAppName --query "systemKeys.connector_extension" -o tsv
if (-not $connectorExtensionKey) {
    Write-Host "ERROR: could not fetch connector_extension system key from $functionAppName." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 1. Create the SharePoint "When a file is created (properties only)" trigger.
# ---------------------------------------------------------------------------
Write-Host "Creating SharePoint trigger config (OnNewFile -> GetOnNewFileItems)..." -ForegroundColor Yellow
Write-Host "  SharePoint site: $sharepointSiteUrl" -ForegroundColor Cyan
Write-Host "  Library: $sharepointLibraryName" -ForegroundColor Cyan
if ($sharepointFolderPath) { Write-Host "  Folder: $sharepointFolderPath" -ForegroundColor Cyan }

$functionName = 'OnNewFile'
$triggerName = "$sharepointConnectionName-$($functionName.ToLower())"
$callbackUrl = "https://$functionAppName.azurewebsites.net/runtime/webhooks/connector?functionName=$functionName&code=$connectorExtensionKey"
$notifFile = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
@{ callbackUrl = $callbackUrl } | ConvertTo-Json -Compress | Set-Content -Path $notifFile -NoNewline

# Build the trigger parameters; include the optional folderPath only when set.
$triggerParameters = "[{name:dataset,value:'$sharepointSiteUrl'},{name:table,value:'$sharepointLibraryName'}"
if ($sharepointFolderPath) {
    $triggerParameters += ",{name:folderPath,value:'$sharepointFolderPath'}"
}
$triggerParameters += "]"

try {
    az connector-namespace trigger delete `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $triggerName --yes 2>$null | Out-Null

    az connector-namespace trigger create `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $triggerName `
        --connection-details "{connectionName:$sharepointConnectionName,connectorName:sharepointonline}" `
        --operation-name 'GetOnNewFileItems' `
        --parameters "$triggerParameters" `
        --notification-details "@$notifFile" `
        --description 'When a file is created (properties only)' `
        --metadata "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}" `
        -o none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Failed to create the SharePoint trigger config." -ForegroundColor Red
        exit 1
    }
}
finally {
    Remove-Item $notifFile -ErrorAction SilentlyContinue
}

Write-Host "Trigger config created." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Authorize both connections (OAuth consent in the browser).
# ---------------------------------------------------------------------------
function Invoke-AuthorizeConnection {
    param(
        [string]$ConnectionName,
        [string]$FriendlyHint
    )

    Write-Host ""
    Write-Host "Authorizing connection '$ConnectionName'..." -ForegroundColor Yellow

    $currentStatus = az connector-namespace connection show `
        -g $resourceGroupName --namespace $connectorNamespaceName `
        -n $ConnectionName --query "properties.overallStatus" -o tsv 2>$null

    if ($currentStatus -eq "Connected") {
        Write-Host "Connection '$ConnectionName' is already authorized." -ForegroundColor Green
        return
    }

    Write-Host "-> A browser tab will open. $FriendlyHint" -ForegroundColor Cyan

    $consentLink = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $consentLink = az connector-namespace connection list-consent-links `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            --connection-name $ConnectionName `
            --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
            --query "value[0].link" -o tsv 2>$null

        if (-not $consentLink) {
            $consentLink = az connector-namespace connection list-consent-links `
                -g $resourceGroupName --namespace $connectorNamespaceName `
                --connection-name $ConnectionName `
                --parameters "[{parameterName:token,redirectUrl:'https://portal.azure.com'}]" `
                --query "link" -o tsv 2>$null
        }

        if ($consentLink) { break }

        if ($attempt -lt 5) {
            Write-Host "list-consent-links attempt $attempt failed. Retrying in 5 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    if (-not $consentLink) {
        Write-Host "Failed to create consent link for '$ConnectionName'." -ForegroundColor Red
        exit 1
    }

    Write-Host "Consent URL: $consentLink" -ForegroundColor Cyan
    try { Start-Process $consentLink | Out-Null } catch {
        Write-Host "Unable to open a browser automatically. Paste the consent URL into your browser." -ForegroundColor Yellow
    }

    $deadline = (Get-Date).AddMinutes(5)
    $lastPrintedStatus = $currentStatus
    Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan

    do {
        Start-Sleep -Seconds 3
        $currentStatus = az connector-namespace connection show `
            -g $resourceGroupName --namespace $connectorNamespaceName `
            -n $ConnectionName --query "properties.overallStatus" -o tsv 2>$null

        if ($currentStatus -ne $lastPrintedStatus) {
            Write-Host "Connection status: $currentStatus" -ForegroundColor Cyan
            $lastPrintedStatus = $currentStatus
        }

        if ($currentStatus -eq "Connected") { break }
    } while ((Get-Date) -lt $deadline)

    if ($currentStatus -ne "Connected") {
        Write-Host "Timed out waiting for '$ConnectionName' to reach Connected status." -ForegroundColor Red
        exit 1
    }

    Write-Host "Connection '$ConnectionName' is authorized." -ForegroundColor Green
}

Invoke-AuthorizeConnection -ConnectionName $sharepointConnectionName -FriendlyHint "Sign in with the account that has access to the SharePoint site."
Invoke-AuthorizeConnection -ConnectionName $teamsConnectionName -FriendlyHint "Sign in with the account that can post to the target Teams channel."

Write-Host ""
Write-Host "Done. RFP intake is configured end-to-end." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
