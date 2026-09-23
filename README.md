# azure-mutlisession-host-update-function

Automates Windows VM update management using Azure Functions, Durable Functions, and Azure VM Run Command.

- Uses Durable Functions for scalable VM processing.
- ScheduleTrigger identifies eligible VMs.
- Orchestrator distributes work across VMWorker activities.
- Each VMWorker manages one VM independently.
- Azure VM Run Command executes the guest update script.
- Update-VM.ps1 installs and reports Windows Updates.
- Azure Table Storage tracks VM state and update results.
- Managed identities provide Azure authentication.
- VM power state is restored after processing.
