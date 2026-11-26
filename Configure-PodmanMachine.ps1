<#
.SYNOPSIS
    Initialises and starts the Podman machine for the runner account.

.DESCRIPTION
    Runs via SSH as the runner user so that Resize-VHD has console access.
    Under run_as_user (service logon), Resize-VHD fails with 'Incorrect
    function' because there is no console; an SSH session provides one.
#>
param(
    [string]$MachineName = 'podman-machine-default',
    [int]$Cpus           = 2,
    [int]$MemoryMB       = 2048,
    [int]$DiskGB         = 20
)

$ErrorActionPreference = 'Stop'

$podmanDirectory = Join-Path $env:ProgramFiles 'Podman'
$podman = Join-Path $podmanDirectory 'podman.exe'

if (-not (Test-Path -Path $podman)) {
    throw 'Podman executable not found.'
}

$env:PATH = "$podmanDirectory;$env:PATH"
$env:CONTAINERS_MACHINE_PROVIDER = 'hyperv'

$machineJson = & $podman machine list --format json

if ($LASTEXITCODE -ne 0) {
    throw 'Unable to list Podman machines.'
}

$machines = @()
if (-not [string]::IsNullOrWhiteSpace($machineJson)) {
    $machines = @($machineJson | ConvertFrom-Json)
}

$machine = $machines |
    Where-Object { $_.Name -eq $MachineName } |
    Select-Object -First 1

if (-not $machine) {
    & $podman machine init `
        --provider hyperv `
        --cpus $Cpus `
        --memory $MemoryMB `
        --disk-size $DiskGB `
        $MachineName

    if ($LASTEXITCODE -ne 0) {
        throw 'Podman machine initialization failed.'
    }
}

# Stop the machine if it is running so the persistent startup task can own the
# lifecycle. gvproxy started inside an SSH session dies when the session ends;
# the startup task runs in the Task Scheduler service context and is not bound
# to a session Job Object, so gvproxy persists across SSH disconnects.
if ($machine -and $machine.Running) {
    & $podman machine stop $MachineName

    if ($LASTEXITCODE -ne 0) {
        throw 'Podman machine stop failed.'
    }
}
