<#
.SYNOPSIS
    Verifies the Podman machine and GitHub Actions runner installation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RunnerUser,

    [string]$PodmanMachineName = 'podman-machine-default'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Run commands that use run_as_user may inherit SYSTEM's environment block.
$userProfile = Join-Path $env:SystemDrive "Users\$RunnerUser"
$appData = Join-Path $userProfile 'AppData\Roaming'
$localAppData = Join-Path $userProfile 'AppData\Local'
$tempPath = Join-Path $localAppData 'Temp'

New-Item -ItemType Directory -Force -Path $appData, $localAppData, $tempPath |
    Out-Null

$env:USERPROFILE = $userProfile
$env:APPDATA = $appData
$env:LOCALAPPDATA = $localAppData
$env:TEMP = $tempPath
$env:TMP = $tempPath
$env:HOME = $userProfile
$env:HOMEDRIVE = Split-Path -Qualifier $userProfile
$env:HOMEPATH = $userProfile.Substring(2)
$env:CONTAINERS_MACHINE_PROVIDER = 'hyperv'

$podman = Join-Path (Join-Path $env:ProgramFiles 'Podman') 'podman.exe'

if (-not (Test-Path -Path $podman)) {
    throw "Podman executable not found at $podman."
}

Write-Host 'Podman version:'
& $podman version

if ($LASTEXITCODE -ne 0) {
    throw 'Podman client verification failed.'
}

Write-Host 'Podman machine:'
& $podman machine list

if ($LASTEXITCODE -ne 0) {
    throw 'Podman machine verification failed.'
}

Write-Host 'Podman connection:'
$podmanInfo = & $podman info

if ($LASTEXITCODE -ne 0) {
    throw 'Podman connectivity verification failed.'
}

$podmanInfo |
    Select-Object -First 15 |
    ForEach-Object { Write-Host $_ }

$runnerService = Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue |
    Sort-Object Name |
    Select-Object -Last 1

if (-not $runnerService) {
    throw 'GitHub Actions runner service was not found.'
}

if ($runnerService.Status -ne 'Running') {
    throw "GitHub Actions runner service is $($runnerService.Status)."
}

Write-Host 'Runner service:'
Get-Service -Name $runnerService.Name |
    Format-List Name, Status, StartType

Write-Host "Podman machine: $PodmanMachineName"
Write-Host 'Verification complete.'
