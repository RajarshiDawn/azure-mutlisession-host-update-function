param($context)

if (-not $context.IsReplaying) {
    Write-Host "||||||||||||||||||||||||||||||||||||||||||||||||||||"
    Write-Host "Orchestrator: The orchestration starts from here"
}


$VMs = $context.Input

Write-Host "Orchestrator: Input type: $($VMs.GetType().FullName)"

$VMParsed = $VMs.ToString() | ConvertFrom-Json

Write-Host "Orchestrator: Parsed type: $($VMParsed.GetType().FullName)"

$Tasks = @()

foreach ($VMInstance in $VMParsed) {

    $VMName = $VMInstance.RowKey

    Write-Host "Orchestrator: Starting VMWorker for VM: $VMName"

    $Task = Invoke-DurableActivity `
        -FunctionName "VMWorker" `
        -Input $VMInstance `
        -NoWait

    Write-Host "Orchestrator: VMWorker task created for VM: $VMName"

    $Tasks += $Task
}

Write-Host "Orchestrator: Waiting for $($Tasks.Count) VMWorker task(s) to complete."

$Results = Wait-ActivityFunction -Task $Tasks

Write-Host "Orchestrator: All VMWorkers completed."

return $Results