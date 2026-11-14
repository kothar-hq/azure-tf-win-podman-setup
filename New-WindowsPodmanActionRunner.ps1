<#
.SYNOPSIS
    Registers a Windows GitHub Actions runner that advertises Podman capabilities.

.DESCRIPTION
    Requests a repository-scoped runner registration token from the GitHub REST
    API and then delegates the runner and Podman machine installation to
    Setup-WindowsPodmanActionRunner.ps1.

    By default the runner registers with kothar-hq/host-container-capabilities
    and advertises the labels:
        self-hosted,Windows,WindowsServer2025,podman,windows-podman

.PARAMETER ConfigPath
    Optional path to a JSON file containing github_repository, github_token,
    runner_name, runner_labels, runner_group, and runner_password. Values in
    the file override the corresponding script parameters.

.PARAMETER GitHubRepository
    GitHub repository in owner/name form.

.PARAMETER GitHubToken
    GitHub token with permission to create runner registration tokens for the
    repository.

.PARAMETER RunnerName
    Name used to register the runner. Defaults to the computer name.

.PARAMETER RunnerLabels
    Comma-separated labels advertised by the runner.

.PARAMETER RunnerGroup
    GitHub Actions runner group.

.PARAMETER RunnerPassword
    Password for the local Windows account that runs the runner and Podman.

.PARAMETER SetupScriptPath
    Path to Setup-WindowsPodmanActionRunner.ps1. Defaults to the file next to
    this script.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,

    [string]$GitHubRepository = 'kothar-hq/host-container-capabilities',

    [string]$GitHubToken,

    [string]$RunnerName = $env:COMPUTERNAME,

    [string]$RunnerLabels = 'self-hosted,Windows,WindowsServer2025,podman,windows-podman',

    [string]$RunnerGroup = 'Default',

    [string]$RunnerPassword,

    [string]$SetupScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Config.PSObject.Properties[$Name]

    if ($property) {
        return $property.Value
    }

    return $null
}

if ($ConfigPath) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Runner configuration file not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $configuredRepository = Get-ConfigValue -Config $config -Name 'github_repository'
    $configuredToken = Get-ConfigValue -Config $config -Name 'github_token'
    $configuredRunnerName = Get-ConfigValue -Config $config -Name 'runner_name'
    $configuredLabels = Get-ConfigValue -Config $config -Name 'runner_labels'
    $configuredGroup = Get-ConfigValue -Config $config -Name 'runner_group'
    $configuredPassword = Get-ConfigValue -Config $config -Name 'runner_password'

    if ($configuredRepository) { $GitHubRepository = $configuredRepository }
    if ($configuredToken) { $GitHubToken = $configuredToken }
    if ($configuredRunnerName) { $RunnerName = $configuredRunnerName }
    if ($configuredLabels) { $RunnerLabels = $configuredLabels }
    if ($configuredGroup) { $RunnerGroup = $configuredGroup }
    if ($configuredPassword) { $RunnerPassword = $configuredPassword }
}

if ($GitHubRepository -notmatch '^[^/]+/[^/]+$') {
    throw "GitHubRepository must be in owner/name form. Found: $GitHubRepository"
}

if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    throw 'A GitHub token is required to request a runner registration token.'
}

if ([string]::IsNullOrWhiteSpace($RunnerPassword)) {
    throw 'RunnerPassword is required to create the runner service account.'
}

if ([string]::IsNullOrWhiteSpace($RunnerName)) {
    $RunnerName = $env:COMPUTERNAME
}

if ([string]::IsNullOrWhiteSpace($SetupScriptPath)) {
    $SetupScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Setup-WindowsPodmanActionRunner.ps1'
}

if (-not (Test-Path -LiteralPath $SetupScriptPath)) {
    throw "Setup script not found: $SetupScriptPath"
}

Write-Host "Requesting runner registration token for $GitHubRepository"

$headers = @{
    Authorization          = "Bearer $GitHubToken"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'azure-windows-podman-runner-bootstrap'
}

$registration = Invoke-RestMethod `
    -Method Post `
    -Uri "https://api.github.com/repos/$GitHubRepository/actions/runners/registration-token" `
    -Headers $headers

$tokenProperty = $registration.PSObject.Properties['token']

if (-not $tokenProperty -or [string]::IsNullOrWhiteSpace($tokenProperty.Value)) {
    throw 'GitHub did not return a runner registration token.'
}

Write-Host "Registering runner '$RunnerName' with labels: $RunnerLabels"

$setupArguments = @{
    GitHubUrl               = "https://github.com/$GitHubRepository"
    RunnerRegistrationToken = $tokenProperty.Value
    RunnerName              = $RunnerName
    RunnerLabels            = $RunnerLabels
    RunnerGroup             = $RunnerGroup
    RunnerPassword          = $RunnerPassword
}

& $SetupScriptPath @setupArguments

if (-not $?) {
    throw 'Runner setup failed.'
}
