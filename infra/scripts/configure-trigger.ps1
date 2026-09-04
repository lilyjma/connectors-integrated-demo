param(
    [Parameter(Mandatory)]
    [ValidateSet('Local', 'Azure')]
    [string]$Target,

    [string]$CallbackBaseUrl
)

$ErrorActionPreference = 'Stop'

if (-not (az extension show --name connector-namespace --query name -o tsv 2>$null)) {
    throw "The 'connector-namespace' Azure CLI extension is required."
}

$outputs = azd env get-values --output json | ConvertFrom-Json
$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$sharepointConnectionName = $outputs.sharepointConnectionName
$functionAppName = $outputs.functionAppName
$subscriptionId = $outputs.AZURE_SUBSCRIPTION_ID
$sharepointSiteUrl = $outputs.sharepointSiteUrl
$sharepointLibraryName = $outputs.sharepointLibraryName
$sharepointFolderPath = $outputs.sharepointFolderPath

if (-not $resourceGroupName -or -not $connectorNamespaceName -or
    -not $sharepointConnectionName -or -not $sharepointSiteUrl -or
    -not $sharepointLibraryName) {
    throw "Required azd outputs are missing. Run 'azd provision' first."
}

$functionName = 'OnNewFile'
$triggerName = "$sharepointConnectionName-$($functionName.ToLower())"

if ($Target -eq 'Local') {
    if ([string]::IsNullOrWhiteSpace($CallbackBaseUrl)) {
        throw "-CallbackBaseUrl is required for a Local target."
    }

    $callbackBase = $CallbackBaseUrl.TrimEnd('/')
    if (-not $callbackBase.StartsWith('https://', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "-CallbackBaseUrl must be a public HTTPS URL."
    }

    $callbackUrl = "$callbackBase/runtime/webhooks/connector?functionName=$functionName"
    $metadata = "{destinationType:functionApp,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}"
}
else {
    if (-not $functionAppName -or -not $subscriptionId) {
        throw "Function App deployment outputs are missing. Run 'azd deploy' first."
    }

    $connectorExtensionKey = az functionapp keys list `
        -g $resourceGroupName -n $functionAppName `
        --query "systemKeys.connector_extension" -o tsv

    if (-not $connectorExtensionKey) {
        throw "Could not fetch the connector_extension system key from '$functionAppName'."
    }

    $callbackUrl = "https://$functionAppName.azurewebsites.net/runtime/webhooks/connector?functionName=$functionName&code=$connectorExtensionKey"
    $metadata = "{destinationType:functionApp,functionAppName:$functionAppName,functionAppResourceGroup:$resourceGroupName,functionAppSubscriptionId:$subscriptionId,functionName:$functionName,recurrenceFrequency:Minute,recurrenceInterval:'5'}"
}

$triggerParameters = "[{name:dataset,value:'$sharepointSiteUrl'},{name:table,value:'$sharepointLibraryName'}"
if ($sharepointFolderPath) {
    $triggerParameters += ",{name:folderPath,value:'$sharepointFolderPath'}"
}
$triggerParameters += "]"

$notificationFile = Join-Path $PSScriptRoot ".notification-details-$([System.Guid]::NewGuid().ToString('N')).json"
@{ callbackUrl = $callbackUrl } | ConvertTo-Json -Compress | Set-Content -Path $notificationFile -NoNewline

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
        --notification-details "@$notificationFile" `
        --description "When a file is created (properties only) - $Target" `
        --metadata "$metadata" `
        --state Enabled `
        -o none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the SharePoint trigger configuration."
    }
}
finally {
    Remove-Item $notificationFile -ErrorAction SilentlyContinue
}

Write-Host "SharePoint trigger now targets $Target." -ForegroundColor Green
if ($Target -eq 'Local') {
    Write-Host "Callback: $callbackUrl" -ForegroundColor Cyan
}
