<#
.SYNOPSIS
    Installs and registers the Windows GitHub Actions runner.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GitHubRepository,

    [Parameter(Mandatory)]
    [string]$GitHubToken,

    [Parameter(Mandatory)]
    [string]$RunnerName,

    [string]$RunnerLabels = 'self-hosted,Windows,WindowsServer2025,podman,windows-podman',

    [string]$RunnerGroup = 'Default',

    [Parameter(Mandatory)]
    [string]$RunnerUser,

    [Parameter(Mandatory)]
    [string]$RunnerPassword,

    [Parameter(Mandatory)]
    [string]$RunnerZipUrl,

    [string]$InstallRoot = 'C:\actions-runner'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($GitHubRepository -notmatch '^[^/]+/[^/]+$') {
    throw "GitHubRepository must be in owner/name form. Found: $GitHubRepository"
}

if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    throw 'A GitHub token is required to request a runner registration token.'
}

$headers = @{
    Authorization          = "Bearer $GitHubToken"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'terraform-azure-podman-runner'
}

$registration = Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.github.com/repos/$GitHubRepository/actions/runners/registration-token" `
    -Headers $headers

$tokenProperty = $registration.PSObject.Properties['token']

if (-not $tokenProperty -or [string]::IsNullOrWhiteSpace($tokenProperty.Value)) {
    throw 'GitHub did not return a runner registration token.'
}

$token = $tokenProperty.Value

Write-Host "Installing runner '$RunnerName' with labels: $RunnerLabels"

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

# Stop any previous runner service so its binaries are not locked during extraction.
$existingServices = @(
    Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue
)

foreach ($existingService in $existingServices) {
    if ($existingService.Status -ne 'Stopped') {
        Stop-Service -Name $existingService.Name -Force
        $existingService.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2))
    }
}

$runnerZip = Join-Path $env:TEMP (Split-Path -Path $RunnerZipUrl -Leaf)
Invoke-WebRequest -Uri $RunnerZipUrl -OutFile $runnerZip -UseBasicParsing
Expand-Archive -Path $runnerZip -DestinationPath $InstallRoot -Force

$configPath = Join-Path $InstallRoot 'config.cmd'
$accountName = $env:COMPUTERNAME + [char]92 + $RunnerUser

Push-Location $InstallRoot

try {
    if (Test-Path -Path '.runner') {
        Write-Host 'Removing the existing runner registration.'

        & $configPath remove --token $token

        if ($LASTEXITCODE -ne 0) {
            & $configPath remove --local

            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to remove the existing runner registration.'
            }
        }
    }
}

finally {
    Pop-Location
}

# Delete any leftover runner service that config.cmd did not remove.
$leftoverServices = @(
    Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue
)

foreach ($leftoverService in $leftoverServices) {
    & sc.exe delete $leftoverService.Name | Out-Null
}

Push-Location $InstallRoot

try {
    $configArguments = @(
        '--unattended'
        '--url', "https://github.com/$GitHubRepository"
        '--token', $token
        '--name', $RunnerName
        '--labels', $RunnerLabels
        '--work', '_work'
        '--runnergroup', $RunnerGroup
        '--replace'
        '--runasservice'
        '--windowslogonaccount', $accountName
        '--windowslogonpassword', $RunnerPassword
    )

    & $configPath @configArguments

    if ($LASTEXITCODE -ne 0) {
        throw "Runner configuration failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$runnerService = Get-Service -Name 'actions.runner*' -ErrorAction SilentlyContinue |
    Sort-Object Name |
    Select-Object -Last 1

if (-not $runnerService) {
    throw 'GitHub Actions runner service was not created.'
}

Set-Service -Name $runnerService.Name -StartupType Automatic

# PowerShell 5.1 does not support AutomaticDelayedStart.
& sc.exe config $runnerService.Name start= delayed-auto | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw 'Unable to configure delayed automatic startup for the runner service.'
}

Start-Service -Name $runnerService.Name
$runnerService.WaitForStatus('Running', [TimeSpan]::FromMinutes(2))

Write-Host "Runner service started: $($runnerService.Name)"
