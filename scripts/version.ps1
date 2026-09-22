# version.ps1
# Records the current Windows build to a dated log file.

$LogDir = "C:\CustomLogs"

if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}

$LogFile = Join-Path $LogDir ("winver-{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))

$key = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

$info = [ordered]@{
    Timestamp      = (Get-Date).ToString("o")
    ComputerName   = $env:COMPUTERNAME
    ProductName    = $key.ProductName
    DisplayVersion = $key.DisplayVersion
    BuildNumber    = "$($key.CurrentBuild).$($key.UBR)"
}

$line = ($info.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join " | "

Add-Content -Path $LogFile -Value $line -Encoding UTF8

# Return to Run Command so it appears in the function log
$info | ConvertTo-Json -Compress