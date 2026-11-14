
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GitHubUrl,

    [Parameter(Mandatory)]
    [string]$RunnerRegistrationToken,

    [string]$RunnerName = $env:COMPUTERNAME,

    [string]$RunnerLabels = 'self-hosted,Windows,WindowsServer2025,podman',

    [string]$RunnerGroup = 'Default',

    [string]$RunnerUser = 'podmanrunner',

    [Parameter(Mandatory)]
    [string]$RunnerPassword,

    [string]$PodmanMachineName = 'podman-machine-default',

    [int]$MachineCPUs = 4,

    [int]$MachineMemoryMB = 8192,

    [int]$MachineDiskGB = 80,

    [string]$InstallRoot = 'C:\actions-runner',

    [string]$LogPath = 'C:\ProgramData\PodmanRunner\install.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkRoot = Split-Path $LogPath
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

Start-Transcript -Path $LogPath -Append

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Invoke-External {
    param(
        [string]$File,
        [string[]]$Arguments
    )

    & $File @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "$File exited with code $LASTEXITCODE"
    }
}

function Get-LatestGitHubRelease {
    param([string]$Repository)

    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repository/releases/latest" `
        -Headers @{ 'User-Agent' = 'Azure-Podman-Runner-Installer' }

    return $release
}

try {
    # ---------------------------------------------------------
    # 1. Validate environment
    # ---------------------------------------------------------

    Write-Step 'Validating Windows Server'

    $os = Get-CimInstance Win32_OperatingSystem

    if ($os.Caption -notmatch 'Windows Server 2025') {
        throw "Expected Windows Server 2025. Found: $($os.Caption)"
    }

    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )

    if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )) {
        throw 'Must run as Administrator.'
    }

    # ---------------------------------------------------------
    # 2. Enable Hyper-V
    # ---------------------------------------------------------

    Write-Step 'Installing Hyper-V'

    $hyperV = Get-WindowsFeature Hyper-V

    if (-not $hyperV.Installed) {
        Install-WindowsFeature Hyper-V -IncludeManagementTools |
            Out-Host

        Write-Warning @'
Hyper-V was installed. A reboot is required before continuing.
Reboot the VM and run this extension again.
'@

        exit 3010
    }

    if (-not (Get-Service vmms -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V Virtual Machine Management service is unavailable.'
    }

    # ---------------------------------------------------------
    # 3. Install Podman machine-wide
    # ---------------------------------------------------------

    Write-Step 'Installing Podman'

    $podmanPath = "$env:ProgramFiles\Podman\podman.exe"

    if (-not (Test-Path $podmanPath)) {
        $release = Get-LatestGitHubRelease 'containers/podman'

        $asset = $release.assets |
            Where-Object {
                $_.name -match 'windows_amd64\.msi$'
            } |
            Select-Object -First 1

        if (-not $asset) {
            throw "No Windows AMD64 MSI found in Podman release $($release.tag_name)"
        }

        $installer = Join-Path $WorkRoot $asset.name

        Invoke-WebRequest `
            -Uri $asset.browser_download_url `
            -OutFile $installer

        Invoke-External 'msiexec.exe' @(
            '/i'
            $installer
            '/quiet'
            '/norestart'
            '/l*v'
            "$WorkRoot\podman-msi.log"
            'ALLUSERS=1'
            'MACHINE_PROVIDER=hyperv'
        )

        if (-not (Test-Path $podmanPath)) {
            throw 'Podman installation did not produce podman.exe.'
        }
    }

    $podmanDirectory = Split-Path $podmanPath

    if ($env:PATH -notlike "*$podmanDirectory*") {
        $machinePath = [Environment]::GetEnvironmentVariable(
            'PATH', 'Machine'
        )

        [Environment]::SetEnvironmentVariable(
            'PATH',
            "$machinePath;$podmanDirectory",
            'Machine'
        )
    }

    # ---------------------------------------------------------
    # 4. Create dedicated service account
    # ---------------------------------------------------------

    Write-Step 'Creating Podman runner account'

    $securePassword = ConvertTo-SecureString `
        $RunnerPassword -AsPlainText -Force

    $account = Get-LocalUser -Name $RunnerUser `
        -ErrorAction SilentlyContinue

    if (-not $account) {
        New-LocalUser `
            -Name $RunnerUser `
            -Password $securePassword `
            -PasswordNeverExpires `
            -UserMayNotChangePassword |
            Out-Null
    }
    else {
        Set-LocalUser `
            -Name $RunnerUser `
            -Password $securePassword
    }

    $accountName = "$env:COMPUTERNAME\$RunnerUser"

    Add-LocalGroupMember `
        -Group 'Hyper-V Administrators' `
        -Member $accountName `
        -ErrorAction SilentlyContinue

    # Make sure the runner account can access its installation.
    New-Item -ItemType Directory -Force -Path $InstallRoot |
        Out-Null

    $acl = Get-Acl $InstallRoot

    $rule = New-Object Security.AccessControl.FileSystemAccessRule(
        $accountName,
        'Modify',
        'ContainerInherit,ObjectInherit',
        'None',
        'Allow'
    )

    $acl.SetAccessRule($rule)
    Set-Acl -Path $InstallRoot -AclObject $acl

    # ---------------------------------------------------------
    # 5. Configure Podman machine as the runner account
    # ---------------------------------------------------------

    Write-Step 'Initializing Podman machine'

    $userProfile = "C:\Users\$RunnerUser"

    New-Item -ItemType Directory -Force -Path $userProfile |
        Out-Null

    $userScript = Join-Path $WorkRoot 'Initialize-Podman.ps1'

    @'
$ErrorActionPreference = "Stop"

$podman = "$env:ProgramFiles\Podman\podman.exe"

if (-not (Test-Path $podman)) {
    throw "Podman executable not found."
}

# Explicitly use Hyper-V.
$env:CONTAINERS_MACHINE_PROVIDER = "hyperv"

$machineName = "__MACHINE_NAME__"

$existing = & $podman machine list --format json |
    ConvertFrom-Json

if (-not ($existing | Where-Object { $_.Name -eq $machineName })) {
    & $podman machine init `
        --provider hyperv `
        --cpus __CPUS__ `
        --memory __MEMORY__ `
        --disk-size __DISK__ `
        $machineName

    if ($LASTEXITCODE -ne 0) {
        throw "Podman machine initialization failed."
    }
}

& $podman machine start $machineName

if ($LASTEXITCODE -ne 0) {
    throw "Podman machine start failed."
}

& $podman info

if ($LASTEXITCODE -ne 0) {
    throw "Podman connectivity verification failed."
}
'@ `
        -replace '__MACHINE_NAME__', $PodmanMachineName `
        -replace '__CPUS__', "$MachineCPUs" `
        -replace '__MEMORY__', "$MachineMemoryMB" `
        -replace '__DISK__', "$MachineDiskGB" |
        Set-Content -Path $userScript -Encoding UTF8

    $initTaskName = 'Initialize-Podman-Machine'

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$userScript`""

    $principal = New-ScheduledTaskPrincipal `
        -UserId $accountName `
        -LogonType Password `
        -RunLevel Highest

    $credential = New-Object PSCredential(
        $accountName,
        $securePassword
    )

    Register-ScheduledTask `
        -TaskName $initTaskName `
        -Action $action `
        -Principal $principal `
        -User $accountName `
        -Password $RunnerPassword `
        -Force |
        Out-Null

    Start-ScheduledTask -TaskName $initTaskName

    $deadline = (Get-Date).AddMinutes(15)

    do {
        Start-Sleep -Seconds 5

        $task = Get-ScheduledTask -TaskName $initTaskName
        $taskInfo = Get-ScheduledTaskInfo -TaskName $initTaskName

        if ($taskInfo.LastTaskResult -notin @(0, 267009)) {
            if ($task.State -ne 'Running') {
                throw "Podman initialization task failed: $($taskInfo.LastTaskResult)"
            }
        }

        if ((Get-Date) -gt $deadline) {
            throw 'Timed out initializing Podman machine.'
        }

    } while ($task.State -eq 'Running')

    if ((Get-ScheduledTaskInfo -TaskName $initTaskName).LastTaskResult -ne 0) {
        throw 'Podman initialization failed.'
    }

    Unregister-ScheduledTask `
        -TaskName $initTaskName `
        -Confirm:$false

    # ---------------------------------------------------------
    # 6. Create startup task for Podman
    # ---------------------------------------------------------

    Write-Step 'Configuring Podman startup'

    $startupScript = Join-Path $WorkRoot 'Start-Podman.ps1'

    @'
$podman = "$env:ProgramFiles\Podman\podman.exe"

$machine = "__MACHINE_NAME__"

& $podman machine start $machine

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
'@.Replace('__MACHINE_NAME__', $PodmanMachineName) |
        Set-Content $startupScript -Encoding UTF8

    $startupAction = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$startupScript`""

    $startupTrigger = New-ScheduledTaskTrigger -AtStartup

    $startupPrincipal = New-ScheduledTaskPrincipal `
        -UserId $accountName `
        -LogonType Password `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName 'Start-Podman-Machine' `
        -Action $startupAction `
        -Trigger $startupTrigger `
        -Principal $startupPrincipal `
        -User $accountName `
        -Password $RunnerPassword `
        -Force |
        Out-Null

    # ---------------------------------------------------------
    # 7. Install GitHub Actions runner
    # ---------------------------------------------------------

    Write-Step 'Installing GitHub Actions runner'

    $runnerRelease = Get-LatestGitHubRelease 'actions/runner'

    $runnerAsset = $runnerRelease.assets |
        Where-Object {
            $_.name -match '^actions-runner-win-x64-.*\.zip$'
        } |
        Select-Object -First 1

    if (-not $runnerAsset) {
        throw 'Could not find Windows x64 GitHub runner.'
    }

    New-Item -ItemType Directory -Force -Path $InstallRoot |
        Out-Null

    $runnerZip = Join-Path $WorkRoot $runnerAsset.name

    Invoke-WebRequest `
        -Uri $runnerAsset.browser_download_url `
        -OutFile $runnerZip

    Expand-Archive `
        -Path $runnerZip `
        -DestinationPath $InstallRoot `
        -Force

    Push-Location $InstallRoot

    try {
        # Remove an existing registration only if this directory
        # has already been configured.
        if (Test-Path '.runner') {
            throw 'Runner directory is already configured. Remove its existing registration before reinstalling.'
        }

        $configArguments = @(
            '--unattended'
            '--url', $GitHubUrl
            '--token', $RunnerRegistrationToken
            '--name', $RunnerName
            '--labels', $RunnerLabels
            '--work', '_work'
            '--runnergroup', $RunnerGroup
            '--replace'
            '--runasservice'
            '--windowslogonaccount', $accountName
            '--windowslogonpassword', $RunnerPassword
        )

        Invoke-External '.\config.cmd' $configArguments

    }
    finally {
        Pop-Location
    }

    # ---------------------------------------------------------
    # 8. Start runner service
    # ---------------------------------------------------------

    Write-Step 'Starting GitHub Actions runner'

    $runnerService = Get-Service |
        Where-Object {
            $_.Name -like 'actions.runner*'
        } |
        Sort-Object Name |
        Select-Object -Last 1

    if (-not $runnerService) {
        throw 'GitHub Actions runner service was not created.'
    }

    # Delayed startup gives the Podman startup task time to run.
    Set-Service `
        -Name $runnerService.Name `
        -StartupType AutomaticDelayedStart

    Start-Service -Name $runnerService.Name

    # ---------------------------------------------------------
    # 9. Verification
    # ---------------------------------------------------------

    Write-Step 'Verifying installation'

    Write-Host "Podman:"
    & $podmanPath version

    Write-Host "Runner service:"
    Get-Service -Name $runnerService.Name |
        Format-List Name, Status, StartType

    Write-Host "Podman machine:"
    Write-Host $PodmanMachineName

    Write-Host "Runner:"
    Write-Host $RunnerName

    Write-Host "Install complete."

}
catch {
    Write-Error $_
    throw
}
finally {
    Stop-Transcript
}
