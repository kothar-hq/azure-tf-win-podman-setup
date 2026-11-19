# Runs through an Azure VM Run Command with run_as_user, which is the failing
# context in podman-container-tools/podman#30266. Everything is also written to
# a log file because run-as output is not always returned to Azure.
param(
    [Parameter(Mandatory)]
    [string]$PodmanExe,

    [Parameter(Mandatory)]
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-HarnessLog {
    param([Parameter(ValueFromPipeline)][AllowNull()][object]$InputObject)
    process {
        $line = [string]$InputObject
        Write-Output $line
        Add-Content -Path $LogPath -Value $line
    }
}

Set-Content -Path $LogPath -Value "== $PodmanExe"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
"identity=$($identity.Name) sid=$($identity.User.Value)" | Write-HarnessLog
"elevated=$($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))" | Write-HarnessLog
"USERPROFILE=$env:USERPROFILE" | Write-HarnessLog
"profileLoaded=$(Test-Path -Path ('Registry::HKEY_USERS\' + $identity.User.Value))" | Write-HarnessLog

& $PodmanExe version --format '{{.Client.Version}} {{.Client.GitCommit}}' 2>&1 | Write-HarnessLog

$ErrorActionPreference = 'Continue'
& $PodmanExe --log-level=debug system hyperv-prep 2>&1 | Write-HarnessLog
$prepExit = $LASTEXITCODE
& $PodmanExe system hyperv-prep --status 2>&1 | Write-HarnessLog
$ErrorActionPreference = 'Stop'

"hyperv-prep-exit=$prepExit" | Write-HarnessLog
exit $prepExit
