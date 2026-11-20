# Runs through an Azure VM Run Command with run_as_user, which is the failing
# context in podman-container-tools/podman#30266. Everything is also written to
# a log file because run-as output is not always returned to Azure.
# No [Parameter()] attributes: the run_as_user handler appends literal
# "2>file 1>file" arguments, which an advanced script rejects (exit 1, no
# output). A simple param block lets them fall into $args instead.
param(
    [string]$PodmanExe,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'
if (-not $PodmanExe -or -not $LogPath) {
    throw 'PodmanExe and LogPath are required.'
}

function Write-HarnessLog {
    param([Parameter(ValueFromPipeline)][AllowNull()][object]$InputObject)
    process {
        $line = [string]$InputObject
        Write-Host $line
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

# Use Start-Process with file redirection: under run_as_user, Windows
# PowerShell 5.1 silently terminates on `native 2>&1 | ...` once the native
# command writes to stderr, which lost podman's error message.
function Invoke-Podman {
    param([string[]]$Arguments)
    $out = "$LogPath.stdout"
    $err = "$LogPath.stderr"
    $process = Start-Process `
        -FilePath $PodmanExe `
        -ArgumentList $Arguments `
        -RedirectStandardOutput $out `
        -RedirectStandardError $err `
        -NoNewWindow `
        -Wait `
        -PassThru
    "-- podman $($Arguments -join ' ') (exit $($process.ExitCode))" | Write-HarnessLog
    Get-Content -Path $out, $err | Write-HarnessLog
    return $process.ExitCode
}

$prepExit = Invoke-Podman -Arguments @('--log-level=debug', 'system', 'hyperv-prep')
Invoke-Podman -Arguments @('system', 'hyperv-prep', '--status') | Out-Null

"hyperv-prep-exit=$prepExit" | Write-HarnessLog
exit $prepExit
