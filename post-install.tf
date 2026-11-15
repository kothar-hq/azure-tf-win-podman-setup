# -------------------------------
# Post-install: run commands that configure Hyper-V, Podman, and the runner
# -------------------------------
data "http" "podman_release" {
  url = "https://api.github.com/repos/containers/podman/releases/latest"

  request_headers = {
    Accept     = "application/vnd.github+json"
    User-Agent = "terraform-azure-podman-runner"
  }
}

data "http" "runner_release" {
  url = "https://api.github.com/repos/actions/runner/releases/latest"

  request_headers = {
    Accept     = "application/vnd.github+json"
    User-Agent = "terraform-azure-podman-runner"
  }
}

locals {
  podman_release = jsondecode(data.http.podman_release.response_body)
  podman_msi_url = [
    for asset in local.podman_release.assets : asset.browser_download_url
    if can(regex("windows[-_]amd64\\.msi$", asset.name))
  ][0]

  runner_release = jsondecode(data.http.runner_release.response_body)
  runner_zip_url = [
    for asset in local.runner_release.assets : asset.browser_download_url
    if can(regex("^actions-runner-win-x64-.*\\.zip$", asset.name))
  ][0]

  create_user_profile = <<-EOT
      # Create a Windows user profile using the native CreateProfile API via P/Invoke.
      function Create-LocalUserProfile {
          [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
          param(
              [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
              [Alias('Name')]
              [ValidateNotNullOrEmpty()]
              [string]$UserName
          )

          begin {
              if (-not ('UserProfileNative' -as [type])) {
                  Add-Type @'
      using System;
      using System.Runtime.InteropServices;
      using System.Text;

      public static class UserProfileNative {
          [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
          public static extern int CreateProfile(
              string sid,
              string username,
              StringBuilder profilePath,
              uint profilePathLength
          );
      }
      '@
              }
          }

          process {
              $user = Get-LocalUser -Name $UserName -ErrorAction Stop
              $sid = $user.SID.Value

              if ($PSCmdlet.ShouldProcess($UserName, 'Create Windows user profile')) {
                  $path = [System.Text.StringBuilder]::new(260)

                  $result = [UserProfileNative]::CreateProfile(
                      $sid,
                      $UserName,
                      $path,
                      [uint32]$path.Capacity
                  )

                  if ($result -ne 0) {
                      $exception = [System.ComponentModel.Win32Exception]::new($result)
                      $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                          $exception,
                          'CreateUserProfileFailed',
                          [System.Management.Automation.ErrorCategory]::InvalidOperation,
                          $UserName
                      )

                      $PSCmdlet.WriteError($errorRecord)
                      return
                  }

                  [PSCustomObject]@{
                      UserName    = $UserName
                      SID         = $sid
                      ProfilePath = $path.ToString()
                      Created     = $true
                  }
              }
          }
      }
    EOT
}

resource "random_password" "runner_password" {
  length           = 32
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "_+"
}

# -------------------------------
# VM Run Command - Install Hyper-V
# -------------------------------
resource "time_sleep" "wait_for_vm_agent" {
  depends_on      = [azurerm_windows_virtual_machine.vm]
  create_duration = "2m"

  triggers = {
    vm_id = azurerm_windows_virtual_machine.vm.id
  }
}

resource "azurerm_virtual_machine_run_command" "install_hyperv" {
  name               = "install-hyperv"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [time_sleep.wait_for_vm_agent]

  source {
    script = <<-EOT
      $ErrorActionPreference = 'Stop'

      $feature = Get-WindowsFeature -Name Hyper-V

      $result = Install-WindowsFeature -Name Hyper-V, Hyper-V-PowerShell -Restart

      if (-not $result.Success) {
          throw 'Hyper-V installation failed.'
      }
    EOT
  }
}

resource "time_sleep" "wait_for_reboot" {
  depends_on      = [azurerm_virtual_machine_run_command.install_hyperv]
  create_duration = "6m"

  triggers = {
    vm_id = azurerm_windows_virtual_machine.vm.id
  }
}

# -------------------------------
# VM Run Command - Install Podman
# -------------------------------
resource "azurerm_virtual_machine_run_command" "install_podman" {
  name               = "install-podman"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [time_sleep.wait_for_reboot]

  timeouts {
    create = "30m"
  }

  parameter {
    name  = "PodmanMsiUrl"
    value = local.podman_msi_url
  }

  source {
    script = <<-EOT
      param(
          [Parameter(Mandatory)]
          [string]$PodmanMsiUrl
      )

      $ErrorActionPreference = 'Stop'

      $installer = Join-Path $env:TEMP (Split-Path -Path $PodmanMsiUrl -Leaf)
      $log = Join-Path $env:TEMP 'podman-msi.log'

      Invoke-WebRequest -Uri $PodmanMsiUrl -OutFile $installer -UseBasicParsing

      $process = Start-Process `
          -FilePath 'msiexec.exe' `
          -ArgumentList @(
              '/i', $installer,
              '/quiet',
              '/norestart',
              '/l*v', $log,
              'ALLUSERS=1',
              'MACHINE_PROVIDER=hyperv'
          ) `
          -Wait `
          -PassThru

      if ($process.ExitCode -notin @(0, 3010)) {
          throw "Podman installation failed with exit code $($process.ExitCode). See $log"
      }

      $podmanDirectory = Join-Path $env:ProgramFiles 'Podman'
      $podman = Join-Path $podmanDirectory 'podman.exe'

      if (-not (Test-Path -Path $podman)) {
          throw "Podman installation did not create $podman."
      }

      $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')

      if ($machinePath -notlike "*$podmanDirectory*") {
          [Environment]::SetEnvironmentVariable(
              'PATH',
              "$machinePath;$podmanDirectory",
              'Machine'
          )
      }
    EOT
  }
}

# -------------------------------
# VM Run Command - Prepare Podman Hyper-V Provider
# -------------------------------
resource "azurerm_virtual_machine_run_command" "prepare_podman_hyperv" {
  name               = "prepare-podman-hyperv"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [azurerm_virtual_machine_run_command.install_podman]
  run_as_user        = azurerm_windows_virtual_machine.vm.admin_username
  run_as_password    = azurerm_windows_virtual_machine.vm.admin_password

  source {
    script = <<-EOT
      $ErrorActionPreference = 'Stop'

      $podman = Join-Path $env:ProgramFiles 'Podman\podman.exe'

      if (-not (Test-Path -Path $podman)) {
          throw 'Podman executable not found.'
      }

      # Pre-create the HKLM VSock entries so the runner account can create
      # and manage Hyper-V machines without an elevated token.
      & $podman system hyperv-prep

      if ($LASTEXITCODE -ne 0) {
          throw 'Podman Hyper-V preparation failed.'
      }
    EOT
  }
}

# -------------------------------
# VM Run Command - Create Runner Account
# -------------------------------
resource "azurerm_virtual_machine_run_command" "create_runner_user" {
  name               = "create-runner-user"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [azurerm_virtual_machine_run_command.prepare_podman_hyperv]
  # run_as_user        = azurerm_windows_virtual_machine.vm.admin_username
  # run_as_password    = azurerm_windows_virtual_machine.vm.admin_password

  parameter {
    name  = "RunnerUser"
    value = var.runner_user
  }

  parameter {
    name  = "InstallRoot"
    value = var.runner_install_root
  }

  protected_parameter {
    name  = "RunnerPassword"
    value = random_password.runner_password.result
  }

  source {
    script = <<-EOT
      param(
          [Parameter(Mandatory)]
          [string]$RunnerUser,

          [Parameter(Mandatory)]
          [string]$RunnerPassword,

          [Parameter(Mandatory)]
          [string]$InstallRoot
      )

      ${local.create_user_profile}

      $ErrorActionPreference = 'Stop'

      $securePassword = ConvertTo-SecureString `
          -String $RunnerPassword `
          -AsPlainText `
          -Force

      $account = Get-LocalUser -Name $RunnerUser -ErrorAction SilentlyContinue

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
              -Password $securePassword `
              -PasswordNeverExpires $true `
              -UserMayChangePassword $false
      }

      $accountName = $env:COMPUTERNAME + [char]92 + $RunnerUser

      # The Hyper-V Administrators group has a well-known SID.
      $hyperVGroupSid = 'S-1-5-32-578'
      $isHyperVAdmin = Get-LocalGroupMember -SID $hyperVGroupSid |
          Where-Object { $_.Name -eq $accountName }

      if (-not $isHyperVAdmin) {
          Add-LocalGroupMember -SID $hyperVGroupSid -Member $accountName
      }

      # Managed Run Command run_as_user relies on Secondary Logon.
      Set-Service -Name seclogon -StartupType Automatic
      Start-Service -Name seclogon

      New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

      $acl = Get-Acl -Path $InstallRoot
      $rule = New-Object Security.AccessControl.FileSystemAccessRule(
          $accountName,
          'Modify',
          'ContainerInherit,ObjectInherit',
          'None',
          'Allow'
      )

      $acl.SetAccessRule($rule)
      Set-Acl -Path $InstallRoot -AclObject $acl


      $profileDirectory = (Create-LocalUserProfile -Name $RunnerUser).ProfilePath

      # When I call the Create-LocalUserProfile cmdlet, it creates the profile directory but the administrators group is the owner. 
      # The subfolders are correctly set up.
      Set-Acl -Path $profileDirectory -AclObject $acl

      if (-not (Test-Path -Path $profileDirectory)) {
          throw "Windows did not create the profile directory $profileDirectory."
      }
    EOT
  }
}

# -------------------------------
# VM Run Command - Initialize Podman Machine
# -------------------------------
resource "azurerm_virtual_machine_run_command" "configure_podman_machine" {
  name               = "configure-podman-machine"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  run_as_user        = var.runner_user
  run_as_password    = random_password.runner_password.result
  depends_on         = [azurerm_virtual_machine_run_command.create_runner_user]

  timeouts {
    create = "60m"
  }

  parameter {
    name  = "MachineName"
    value = var.podman_machine_name
  }

  parameter {
    name  = "RunnerUser"
    value = var.runner_user
  }

  parameter {
    name  = "Cpus"
    value = tostring(var.podman_cpus)
  }

  parameter {
    name  = "MemoryMB"
    value = tostring(var.podman_memory_mb)
  }

  parameter {
    name  = "DiskGB"
    value = tostring(var.podman_disk_gb)
  }

  source {
    script = <<-EOT
      param(
          [Parameter(Mandatory)]
          [string]$MachineName,

          [Parameter(Mandatory)]
          [string]$RunnerUser,

          [Parameter(Mandatory)]
          [int]$Cpus,

          [Parameter(Mandatory)]
          [int]$MemoryMB,

          [Parameter(Mandatory)]
          [int]$DiskGB
      )

      $ErrorActionPreference = 'Stop'

      $podmanDirectory = Join-Path $env:ProgramFiles 'Podman'
      $podman = Join-Path $podmanDirectory 'podman.exe'

      if (-not (Test-Path -Path $podman)) {
          throw 'Podman executable not found.'
      }

      # Keep Podman machine state in the runner account's profile. Run commands
      # that use run_as_user may inherit SYSTEM's environment block, so set the
      # profile paths explicitly.
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

      if (-not $machine -or -not $machine.Running) {
          & $podman machine start $MachineName

          if ($LASTEXITCODE -ne 0) {
              throw 'Podman machine start failed.'
          }
      }

      $deadline = (Get-Date).AddMinutes(10)

      do {
          & $podman info | Out-Null

          if ($LASTEXITCODE -eq 0) {
              break
          }

          Start-Sleep -Seconds 10
      } while ((Get-Date) -lt $deadline)

      if ($LASTEXITCODE -ne 0) {
          throw 'Podman connectivity verification failed.'
      }
    EOT
  }
}

# -------------------------------
# VM Run Command - Start Podman at Boot
# -------------------------------
resource "azurerm_virtual_machine_run_command" "create_podman_startup_task" {
  name               = "create-podman-startup-task"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [azurerm_virtual_machine_run_command.configure_podman_machine]

  parameter {
    name  = "RunnerUser"
    value = var.runner_user
  }

  parameter {
    name  = "MachineName"
    value = var.podman_machine_name
  }

  protected_parameter {
    name  = "RunnerPassword"
    value = random_password.runner_password.result
  }

  source {
    script = <<-EOT
      param(
          [Parameter(Mandatory)]
          [string]$RunnerUser,

          [Parameter(Mandatory)]
          [string]$RunnerPassword,

          [Parameter(Mandatory)]
          [string]$MachineName
      )

      $ErrorActionPreference = 'Stop'

      $podmanDirectory = Join-Path $env:ProgramFiles 'Podman'
      $podman = Join-Path $podmanDirectory 'podman.exe'
      $accountName = $env:COMPUTERNAME + [char]92 + $RunnerUser

      $action = New-ScheduledTaskAction `
          -Execute $podman `
          -Argument "machine start $MachineName"

      $trigger = New-ScheduledTaskTrigger -AtStartup

      # Give Hyper-V and the network stack time to start before the machine.
      $trigger.Delay = 'PT2M'

      $principal = New-ScheduledTaskPrincipal `
          -UserId $accountName `
          -LogonType Password `
          -RunLevel Limited

      # Register-ScheduledTask cannot combine -Principal with -User/-Password,
      # so build the definition and register it as an object.
      $task = New-ScheduledTask `
          -Action $action `
          -Trigger $trigger `
          -Principal $principal

      Register-ScheduledTask `
          -TaskName 'Start-Podman-Machine' `
          -InputObject $task `
          -User $accountName `
          -Password $RunnerPassword `
          -Force |
          Out-Null
    EOT
  }
}

# -------------------------------
# VM Run Command - Install GitHub Actions Runner
# -------------------------------
resource "azurerm_virtual_machine_run_command" "install_runner" {
  name               = "install-github-runner"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [azurerm_virtual_machine_run_command.create_podman_startup_task]

  timeouts {
    create = "45m"
  }

  source {
    script = file("${path.module}/New-WindowsPodmanActionRunner.ps1")
  }

  parameter {
    name  = "GitHubRepository"
    value = var.github_repository
  }

  protected_parameter {
    name  = "GitHubToken"
    value = var.github_token
  }

  parameter {
    name  = "RunnerName"
    value = var.vm_name
  }

  parameter {
    name  = "RunnerLabels"
    value = var.runner_labels
  }

  parameter {
    name  = "RunnerGroup"
    value = var.runner_group
  }

  parameter {
    name  = "RunnerUser"
    value = var.runner_user
  }

  protected_parameter {
    name  = "RunnerPassword"
    value = random_password.runner_password.result
  }

  parameter {
    name  = "RunnerZipUrl"
    value = local.runner_zip_url
  }

  parameter {
    name  = "InstallRoot"
    value = var.runner_install_root
  }
}

# -------------------------------
# VM Run Command - Verify Installation
# -------------------------------
resource "azurerm_virtual_machine_run_command" "verify" {
  name               = "verify-runner"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  run_as_user        = var.runner_user
  run_as_password    = random_password.runner_password.result
  depends_on         = [azurerm_virtual_machine_run_command.install_runner]

  timeouts {
    create = "15m"
  }

  parameter {
    name  = "RunnerUser"
    value = var.runner_user
  }

  parameter {
    name  = "PodmanMachineName"
    value = var.podman_machine_name
  }

  source {
    script = file("${path.module}/Setup-WindowsPodmanActionRunner.ps1")
  }
}

output "runner_password" {
  description = "Password used to run the GitHub Actions runner."
  value       = random_password.runner_password.result
  sensitive   = true
}