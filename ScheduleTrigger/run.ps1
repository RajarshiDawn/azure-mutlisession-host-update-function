param($Request, $durableClient)

# ============================================================
# Manual HTTP Trigger
# Authentication is handled once per worker in profile.ps1.
# ============================================================

Write-Host "Trigger:||||||||||||||||||||||||||||||||||||||||||||||||||||"
Write-Host "Trigger:Manual trigger starts from here"

# Storage configuration. Kept in app settings so the same code
# runs against test and production tables.
$StorageAccountName = $env:VMTABLE_ACCOUNT
$TableName = $env:VMTABLE_NAME

if (-not $StorageAccountName -or -not $TableName) {
    Write-Error "Trigger:VMTABLE_ACCOUNT or VMTABLE_NAME app setting is missing."
    return
}

# ============================================================
# Calculate current 4-hour partition
# ============================================================

$now = [DateTime]::UtcNow
$day = $now.ToString("ddd", [System.Globalization.CultureInfo]::InvariantCulture)
$hour = [int]([math]::Floor($now.Hour / 4) * 4)
$slot = $hour.ToString("D2")

$partitionKey = "$day$slot"

Write-Host "Trigger:Current UTC time : $now"
Write-Host "Trigger:PartitionKey     : $partitionKey"

# ============================================================
# Get Azure Storage OAuth token
# ============================================================

$tokenObj = Get-AzAccessToken `
    -ResourceUrl "https://storage.azure.com/" `
    -ErrorAction SilentlyContinue `
    -ErrorVariable tokenError

if ($tokenError -or -not $tokenObj) {
    Write-Error "Trigger:Unable to obtain Azure Storage access token."
    return
}

# Az.Accounts 5.x returns a SecureString; older versions return a plain string.
if ($tokenObj.Token -is [System.Security.SecureString]) {
    $token = [System.Net.NetworkCredential]::new("", $tokenObj.Token).Password
}
else {
    $token = $tokenObj.Token
}

# ============================================================
# Query Azure Table Storage for this slot
# ============================================================

$filter = [System.Uri]::EscapeDataString("PartitionKey eq '$partitionKey'")
$uri = "https://$StorageAccountName.table.core.windows.net/$TableName()?`$filter=$filter"

$response = Invoke-RestMethod `
    -Method GET `
    -Uri $uri `
    -Headers @{
    Authorization  = "Bearer $token"
    "x-ms-version" = "2020-12-06"
    Accept         = "application/json;odata=nometadata"
} `
    -ErrorAction SilentlyContinue `
    -ErrorVariable queryError

if ($queryError) {
    Write-Error "Trigger:Table query failed: $($queryError[0].Exception.Message)"
    return
}

# ============================================================
# Select enabled VMs and shape the activity input.
# PartitionKey is included explicitly because the worker needs
# it to merge its result back into the same row.
# ============================================================

$VMs = @(
    $response.value |
    Where-Object { "$($_.Enabled)".Trim() -eq "true" } |
    ForEach-Object {
        [ordered]@{
            PartitionKey   = $partitionKey
            RowKey         = $_.RowKey
            ResourceGroup  = $_.ResourceGroup
            SubscriptionId = $_.SubscriptionId
            Enabled        = $_.Enabled
        }
    }
)

Write-Host "Trigger:Rows in slot   : $($response.value.Count)"
Write-Host "Trigger:Enabled VMs    : $($VMs.Count)"

# ============================================================
# Skip the orchestration entirely if nothing is scheduled
# ============================================================

if ($VMs.Count -eq 0) {
    Write-Host "Trigger:No enabled VMs found. No orchestration started."
    return
}

# ============================================================
# Start Durable Orchestrator
# ============================================================

Write-Host "Trigger:Starting Durable Orchestrator with $($VMs.Count) VM(s)"

$InstanceId = Start-DurableOrchestration `
    -FunctionName "Orchestrator" `
    -InputObject $VMs

Write-Host "Trigger:Durable Orchestrator started. Instance ID: $InstanceId"