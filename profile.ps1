if (-not (Get-AzContext)) {
    Disable-AzContextAutosave -Scope Process | Out-Null

    if ($env:IDENTITY_ENDPOINT) {
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    }
    else {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }
}