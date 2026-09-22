param(
    [Parameter(Mandatory = $true)]
    [string]$RowKey,

    [Parameter(Mandatory = $true)]
    [string]$PartitionKey,

    [Parameter(Mandatory = $true)]
    [string]$StorageAccount,

    [Parameter(Mandatory = $true)]
    [string]$TableName
)

# =========================================================
# Windows Update Installation Script
# =========================================================

$LogDirectory = "C:\Update\Logs"

if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogDirectory "WindowsUpdate_$Timestamp.log"
$ResultFile = Join-Path $LogDirectory "result.json"

$Status = "Failed"
$LastUpdateAttemptStatus = "failed"
$LastUpdateAttemptTimestamp = $null
$RebootRequired = $false
$UpdatesFound = 0
$UpdatesInstalled = 0
$InstalledKBs = @()
$UpdateResults = @()
$ErrorMessage = $null

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    Add-Content `
        -Path $LogFile `
        -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}

function Update-Table {
    param(
        [bool]$Enabled,
        [string]$AttemptStatus,
        [string]$AttemptTimestamp,
        [string]$InstalledKBs
    )

    $TokenObject = Get-AzAccessToken `
        -ResourceUrl "https://storage.azure.com/" `
        -ErrorAction Stop

    $Token = [System.Net.NetworkCredential]::new(
        "",
        $TokenObject.Token
    ).Password

    $Uri = "https://$StorageAccount.table.core.windows.net/$TableName" +
    "(PartitionKey='$PartitionKey',RowKey='$RowKey')"

    $Headers = @{
        Authorization  = "Bearer $Token"
        "x-ms-version" = "2019-02-02"
        "x-ms-date"    = (Get-Date).ToUniversalTime().ToString("R")
        Accept         = "application/json;odata=nometadata"
        "If-Match"     = "*"
    }

    $Body = @{
        Enabled                    = $Enabled
        LastUpdateAttemptStatus    = $AttemptStatus
        LastUpdateAttemptTimestamp = $AttemptTimestamp
        LastUpdateInstalledKBs     = $InstalledKBs
    } | ConvertTo-Json -Compress

    Invoke-RestMethod `
        -Method Merge `
        -Uri $Uri `
        -Headers $Headers `
        -ContentType "application/json" `
        -Body $Body `
        -ErrorAction Stop
}

function Test-PendingReboot {

    $Paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    )

    foreach ($Path in $Paths) {
        if (Test-Path $Path) {
            return $true
        }
    }

    return $false
}

function Write-Result {

    $ResultObject = [PSCustomObject]@{
        Status                     = $Status
        RebootRequired             = $RebootRequired
        ComputerName               = $env:COMPUTERNAME
        ExecutionTime              = (Get-Date).ToUniversalTime().ToString("o")
        UpdatesFound               = $UpdatesFound
        UpdatesInstalled           = $UpdatesInstalled
        InstalledKBs               = @($InstalledKBs)
        Updates                    = @($UpdateResults)
        Error                      = $ErrorMessage
        LogFile                    = $LogFile
        LastUpdateAttemptStatus    = $LastUpdateAttemptStatus
        LastUpdateAttemptTimestamp = $LastUpdateAttemptTimestamp
    }

    $Json = $ResultObject |
    ConvertTo-Json -Depth 10 -Compress

    Set-Content `
        -Path $ResultFile `
        -Value $Json `
        -Encoding UTF8

    Write-Host "###RESULT_START###"
    Write-Host $Json
    Write-Host "###RESULT_END###"
}

try {

    Write-Log "Starting Windows Update for $RowKey"

    # Authenticate using the assigned UAMI.
    Connect-AzAccount `
        -Identity `
        -AccountId "04e7dacd-35eb-4c5d-91eb-70eaf637befb" `
        -ErrorAction Stop |
    Out-Null

    # Mark the VM as unavailable before starting.
    Update-Table `
        -Enabled $false `
        -AttemptStatus "failed" `
        -AttemptTimestamp (Get-Date).ToUniversalTime().ToString("o") `
        -InstalledKBs ""

    Write-Log "Table row disabled."

    # -----------------------------------------------------
    # Search for Windows Updates.
    # -----------------------------------------------------

    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()

    Write-Log "Searching for updates..."

    $Result = $Searcher.Search(
        "IsInstalled=0 and IsHidden=0 and Type='Software'"
    )

    $UpdatesFound = $Result.Updates.Count

    Write-Log "Updates found: $UpdatesFound"

    if ($UpdatesFound -eq 0) {

        $Status = "NoUpdates"
        $LastUpdateAttemptStatus = "success"
        $LastUpdateAttemptTimestamp =
        (Get-Date).ToUniversalTime().ToString("o")

        Update-Table `
            -Enabled $true `
            -AttemptStatus $LastUpdateAttemptStatus `
            -AttemptTimestamp $LastUpdateAttemptTimestamp `
            -InstalledKBs ""

        Write-Log "No updates. Table row re-enabled."

        Write-Result
        return
    }

    # -----------------------------------------------------
    # Prepare updates.
    # -----------------------------------------------------

    $UpdatesToInstall =
    New-Object -ComObject Microsoft.Update.UpdateColl

    foreach ($Update in $Result.Updates) {

        Write-Log "Found: $($Update.Title)"

        if (-not $Update.EulaAccepted) {
            $Update.AcceptEula()
        }

        [void]$UpdatesToInstall.Add($Update)
    }

    # -----------------------------------------------------
    # Download updates.
    # -----------------------------------------------------

    $UpdatesToDownload =
    New-Object -ComObject Microsoft.Update.UpdateColl

    foreach ($Update in $UpdatesToInstall) {

        if (-not $Update.IsDownloaded) {
            [void]$UpdatesToDownload.Add($Update)
        }
    }

    if ($UpdatesToDownload.Count -gt 0) {

        Write-Log "Downloading updates..."

        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $UpdatesToDownload

        $DownloadResult = $Downloader.Download()

        Write-Log "Download ResultCode: $($DownloadResult.ResultCode)"

        if ($DownloadResult.ResultCode -ne 2) {
            throw "Download failed. ResultCode=$($DownloadResult.ResultCode)"
        }
    }

    # -----------------------------------------------------
    # Install updates.
    # -----------------------------------------------------

    Write-Log "Installing updates..."

    $Installer = $Session.CreateUpdateInstaller()
    $Installer.Updates = $UpdatesToInstall

    $InstallResult = $Installer.Install()

    $RebootRequired =
    $InstallResult.RebootRequired -or
    (Test-PendingReboot)

    Write-Log "Install ResultCode: $($InstallResult.ResultCode)"
    Write-Log "RebootRequired: $RebootRequired"

    # -----------------------------------------------------
    # Process individual update results.
    # -----------------------------------------------------

    for ($i = 0; $i -lt $UpdatesToInstall.Count; $i++) {

        $Update = $UpdatesToInstall.Item($i)
        $UpdateResult = $InstallResult.GetUpdateResult($i)

        $KB = ($Update.KBArticleIDs -join ", ")

        Write-Log `
            "Result: $($Update.Title) | KB $KB | ResultCode $($UpdateResult.ResultCode) | HResult $($UpdateResult.HResult)"

        $UpdateResults += [PSCustomObject]@{
            Title      = $Update.Title
            KB         = $KB
            ResultCode = $UpdateResult.ResultCode
            HResult    = $UpdateResult.HResult
        }

        if ($UpdateResult.ResultCode -eq 2) {

            $UpdatesInstalled++

            foreach ($KBId in $Update.KBArticleIDs) {

                if ($KBId -and $InstalledKBs -notcontains $KBId) {
                    $InstalledKBs += $KBId
                }
            }
        }
    }

    # -----------------------------------------------------
    # Determine final status.
    # -----------------------------------------------------

    if ($InstallResult.ResultCode -eq 2) {

        $Status = "Succeeded"
        $LastUpdateAttemptStatus = "success"
    }
    elseif ($UpdatesInstalled -gt 0) {

        $Status = "PartiallySucceeded"
        $LastUpdateAttemptStatus = "partiallyfailed"
        $ErrorMessage = "Some updates failed."
    }
    else {

        $Status = "Failed"
        $LastUpdateAttemptStatus = "failed"
        $ErrorMessage = "Installation failed."
    }

    $LastUpdateAttemptTimestamp =
    (Get-Date).ToUniversalTime().ToString("o")

    # -----------------------------------------------------
    # Always re-enable after the attempt.
    # -----------------------------------------------------

    Update-Table `
        -Enabled $true `
        -AttemptStatus $LastUpdateAttemptStatus `
        -AttemptTimestamp $LastUpdateAttemptTimestamp `
        -InstalledKBs ($InstalledKBs -join ",")

    Write-Log "Table row re-enabled."

    Write-Result
}
catch {

    $Status = "Failed"
    $LastUpdateAttemptStatus = "failed"
    $ErrorMessage = $_.Exception.Message
    $LastUpdateAttemptTimestamp =
    (Get-Date).ToUniversalTime().ToString("o")

    Write-Log "ERROR: $ErrorMessage" "ERROR"

    # Always re-enable after failure.
    try {

        Update-Table `
            -Enabled $true `
            -AttemptStatus "failed" `
            -AttemptTimestamp $LastUpdateAttemptTimestamp

        Write-Log "Table row re-enabled after failure."
    }
    catch {

        Write-Log `
            "Could not re-enable table row: $($_.Exception.Message)" `
            "ERROR"
    }

    try {
        Write-Result
    }
    catch {
        Write-Log `
            "Could not write result: $($_.Exception.Message)" `
            "ERROR"
    }

    throw
}