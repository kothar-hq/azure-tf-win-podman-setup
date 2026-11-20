# The script from podman-container-tools/podman#30266, unchanged except that
# the podman path is a parameter. Used to test whether the failure needs
# Windows PowerShell 5.1's $ErrorActionPreference = 'Stop' handling of native
# stderr, or comes from podman itself. No [Parameter()] attributes: the
# run_as_user handler appends literal "2>file 1>file" arguments.
param(
    [string]$PodmanExe,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$podman = $PodmanExe

if (-not (Test-Path -Path $podman)) {
    throw 'Podman executable not found.'
}

# Leave a marker so the SYSTEM result step can tell how far the script got.
Set-Content -Path $LogPath -Value 'issue-script started'

& $podman system hyperv-prep

if ($LASTEXITCODE -ne 0) {
    Add-Content -Path $LogPath -Value "hyperv-prep-exit=$LASTEXITCODE"
    throw 'Podman Hyper-V preparation failed.'
}

Add-Content -Path $LogPath -Value 'hyperv-prep-exit=0'
