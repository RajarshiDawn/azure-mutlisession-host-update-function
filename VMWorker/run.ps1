param($context)

Write-Host "Worker:||||||||||||||||||||||||||||||||||||||||||||||||||||"
Write-Host "Worker:Manual worker starts from here"

$rg = $context.ResourceGroup
$vm = $context.RowKey
$pk = $context.PartitionKey

$storageAccount = $env:VMTABLE_ACCOUNT
$tableName = $env:VMTABLE_NAME

Write-Host "$rg ||| $vm ||| $pk ||| $storageAccount ||| $tableName "

$wasRunning = $false

try {
    Write-Host "VMWorker: Processing $vm"

    # Check current VM power state.
    $vmStatus = Get-AzVM `
        -ResourceGroupName $rg `
        -Name $vm `
        -Status `
        -ErrorAction Stop

    $powerState = ($vmStatus.Statuses |
        Where-Object { $_.Code -like "PowerState/*" }).Code
    
    Write-Host "VM power state: $powerState"

    # Start VM when it is not running.
    if ($powerState -ne "PowerState/running") {
        Write-Host "VMWorker: Starting $vm"

        Start-AzVM `
            -ResourceGroupName $rg `
            -Name $vm `
            -ErrorAction Stop | Out-Null

        $wasRunning = $false
    }
    else {
        $wasRunning = $true
    }

    # Ensure Az.Accounts exists inside the VM.
    $installScript = @'
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    
        Install-PackageProvider `
            -Name NuGet `
            -MinimumVersion 2.8.5.201 `
            -Force
    
        Install-Module `
            -Name Az.Accounts `
            -Scope AllUsers `
            -Force `
            -AllowClobber
    }
'@

    Write-Host "VMWorker: Ensuring Az.Accounts exists on $vm"

    Invoke-AzVMRunCommand `
        -ResourceGroupName $rg `
        -VMName $vm `
        -CommandId "RunPowerShellScript" `
        -ScriptString $installScript `
        -ErrorAction Stop | Out-Null

    # Load Update-VM.ps1.
    $scriptPath = Join-Path $PSScriptRoot '..' 'scripts' 'Update-VM.ps1'

    if (-not (Test-Path $scriptPath)) {
        Write-Error "Update script not found: $scriptPath"
    }

    $script = Get-Content $scriptPath -Raw

    # Execute update script inside the VM.
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $rg `
        -VMName $vm `
        -CommandId "RunPowerShellScript" `
        -ScriptString $script `
        -Parameter @{
        RowKey         = $vm
        PartitionKey   = $pk
        StorageAccount = $storageAccount
        TableName      = $tableName
    } `
        -ErrorAction Stop

    $stdout = $result.Value[0].Message

    Write-Host "VMWorker: $vm completed"
    Write-Host $stdout

    # Stop VM if it was originally stopped.
    if (-not $wasRunning) {
        Write-Host "VMWorker: Stopping $vm"

        Stop-AzVM `
            -ResourceGroupName $rg `
            -Name $vm `
            -Force `
            -ErrorAction Stop | Out-Null
    }

    return @{
        RowKey = $vm
        Output = $stdout
        Status = "Succeeded"
    }
}
catch {
    Write-Error "VMWorker: $vm failed: $($_.Exception.Message)"

    # Stop VM if this worker started it.
    if (-not $wasRunning) {
        try {
            Stop-AzVM `
                -ResourceGroupName $rg `
                -Name $vm `
                -Force `
                -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Error "VMWorker: Failed stopping $vm"
        }
    }

    return @{
        RowKey = $vm
        Output = $null
        Status = "Failed"
        Error  = $_.Exception.Message
    }
}