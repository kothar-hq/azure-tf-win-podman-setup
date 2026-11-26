# -------------------------------
# Post-install: run commands that configure Hyper-V, Podman, and the runner
# -------------------------------
locals {
  use_local_podman_msi = var.podman_msi_path != null

  podman_release_path = var.podman_version == "latest" ? "latest" : "tags/v${var.podman_version}"
  runner_release_path = var.runner_version == "latest" ? "latest" : "tags/v${var.runner_version}"
}

# Skipped when a local MSI is installed instead of a GitHub release.
data "http" "podman_release" {
  count = local.use_local_podman_msi ? 0 : 1
  url   = "https://api.github.com/repos/containers/podman/releases/${local.podman_release_path}"

  request_headers = {
    Accept     = "application/vnd.github+json"
    User-Agent = "terraform-azure-podman-runner"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Podman release ${var.podman_version} was not found on GitHub."
    }
  }
}

data "http" "runner_release" {
  url = "https://api.github.com/repos/actions/runner/releases/${local.runner_release_path}"

  request_headers = {
    Accept     = "application/vnd.github+json"
    User-Agent = "terraform-azure-podman-runner"
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "GitHub Actions runner release ${var.runner_version} was not found on GitHub."
    }
  }
}

locals {
  podman_release_msi_url = local.use_local_podman_msi ? null : [
    for asset in jsondecode(data.http.podman_release[0].response_body).assets : asset.browser_download_url
    if can(regex("windows[-_]amd64\\.msi$", asset.name))
  ][0]

  # Read-only SAS URL for the uploaded MSI (see podman-msi.tf).
  podman_msi_url = local.use_local_podman_msi ? "${azurerm_storage_blob.podman_msi[0].url}${data.azurerm_storage_account_blob_container_sas.podman_msi[0].sas}" : local.podman_release_msi_url

  runner_release = jsondecode(data.http.runner_release.response_body)
  runner_zip_url = [
    for asset in local.runner_release.assets : asset.browser_download_url
    if can(regex("^actions-runner-win-x64-.*\\.zip$", asset.name))
  ][0]


  add_user_to_hyperv_admins = <<-EOT
      # The Hyper-V Administrators group has a well-known SID.
      # Compare SIDs: Get-LocalGroupMember reports names as COMPUTER\user, so a
      # name comparison misses bare user names and re-adding throws.
      $hyperVGroupSid = 'S-1-5-32-578'
      $accountSid = ([Security.Principal.NTAccount]$accountName).Translate(
          [Security.Principal.SecurityIdentifier]
      ).Value
      $isHyperVAdmin = Get-LocalGroupMember -SID $hyperVGroupSid |
          Where-Object { $_.SID.Value -eq $accountSid }

      if (-not $isHyperVAdmin) {
          Add-LocalGroupMember -SID $hyperVGroupSid -Member $accountName
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

resource "azurerm_virtual_machine_run_command" "enable_remote_management" {
  count = var.enable_remote_management ? 1 : 0

  name               = "enable-remote-management"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [time_sleep.wait_for_vm_agent]

  timeouts {
    create = "15m"
  }

  source {
    script = <<-EOT
      $ErrorActionPreference = 'Stop'

      # OpenSSH Server provides SSH and SCP (through the SFTP subsystem).
      $sshCapability = Get-WindowsCapability -Online |
          Where-Object { $_.Name -like 'OpenSSH.Server*' } |
          Select-Object -First 1

      if (-not $sshCapability -or $sshCapability.State -ne 'Installed') {
          Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' |
              Out-Null
      }

      $sshdConfig = Join-Path $env:ProgramData 'ssh\sshd_config'

      if (-not (Test-Path -Path $sshdConfig)) {
          throw "OpenSSH configuration not found at $sshdConfig."
      }

      $config = Get-Content -Path $sshdConfig

      if ($config -match '^\s*#?\s*PasswordAuthentication\s+') {
          $config = $config -replace '^\s*#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication yes'
      }
      else {
          $config += 'PasswordAuthentication yes'
      }

      if (-not ($config -match '^\s*Subsystem\s+sftp\s+')) {
          $config += 'Subsystem sftp sftp-server.exe'
      }

      Set-Content -Path $sshdConfig -Value $config -Encoding ascii

      Set-Service -Name sshd -StartupType Automatic
      Start-Service -Name sshd
      Restart-Service -Name sshd

      foreach ($rule in @(
          @{ Name = 'Allow-SSH-From-Azure'; Port = 22 },
          @{ Name = 'Allow-WinRM-HTTP-From-Azure'; Port = 5985 }
      )) {
          if (-not (Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue)) {
              New-NetFirewallRule `
                  -Name $rule.Name `
                  -DisplayName $rule.Name `
                  -Enabled True `
                  -Direction Inbound `
                  -Protocol TCP `
                  -Action Allow `
                  -LocalPort $rule.Port `
                  -Profile Any |
                  Out-Null
          }
      }

      # Configure PowerShell Remoting over WinRM HTTP (TCP 5985).
      Enable-PSRemoting -SkipNetworkProfileCheck -Force
      Set-Service -Name WinRM -StartupType Automatic
      Start-Service -Name WinRM

      # Workgroup VMs need this to allow local administrators to authenticate
      # remotely without UAC filtering their token.
      $systemPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
      New-ItemProperty `
          -Path $systemPolicy `
          -Name 'LocalAccountTokenFilterPolicy' `
          -PropertyType DWord `
          -Value 1 `
          -Force |
          Out-Null
    EOT
  }
}

resource "azurerm_virtual_machine_run_command" "install_hyperv" {
  name               = "install-hyperv"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on = [
    time_sleep.wait_for_vm_agent,
    azurerm_virtual_machine_run_command.enable_remote_management,
  ]

  timeouts {
    create = "30m"
    update = "30m"
  }

  source {
    script = <<-EOT
      $ErrorActionPreference = 'Stop'

      $result = Install-WindowsFeature -Name Hyper-V, Hyper-V-PowerShell -Restart

      if (-not $result.Success) {
          throw 'Hyper-V installation failed.'
      }
    EOT
  }
}

resource "terraform_data" "wait_for_reboot" {
  depends_on = [azurerm_virtual_machine_run_command.install_hyperv]

  triggers_replace = [
    azurerm_virtual_machine_run_command.install_hyperv.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    environment = {
      TARGET_IP = azurerm_public_ip.pip.ip_address
    }

    command = <<-EOT
      set -euo pipefail

      if ! command -v nc >/dev/null 2>&1; then
          echo 'nc (netcat) is required to verify the VM reboot.' >&2
          exit 1
      fi

      echo "Waiting 60 seconds for the VM to reboot..."
      sleep 60

      for attempt in $(seq 1 30); do
          if nc -z -w 5 "$TARGET_IP" 3389; then
              echo "RDP on $TARGET_IP:3389 is reachable after $attempt attempt(s)."
              exit 0
          fi

          echo "Attempt $attempt/30: RDP not reachable yet; retrying in 15 seconds."
          sleep 15
      done

      echo "Timed out waiting for RDP on $TARGET_IP:3389." >&2
      exit 1
    EOT
  }
}

# -------------------------------
# VM Run Command - Install Podman
# -------------------------------
resource "azurerm_virtual_machine_run_command" "install_podman" {
  name               = "install-podman"
  location           = azurerm_resource_group.rg.location
  virtual_machine_id = azurerm_windows_virtual_machine.vm.id
  depends_on         = [terraform_data.wait_for_reboot]

  timeouts {
    create = "30m"
  }

  # Protected: for a local MSI the URL carries a SAS token.
  protected_parameter {
    name  = "PodmanMsiUrl"
    value = local.podman_msi_url
  }

  # Local MSI only: the script checks the download against it, and a new
  # file re-runs this command.
  dynamic "parameter" {
    for_each = local.use_local_podman_msi ? [filesha256(var.podman_msi_path)] : []

    content {
      name  = "PodmanMsiSha256"
      value = parameter.value
    }
  }

  parameter {
    name  = "AccountName"
    value = azurerm_windows_virtual_machine.vm.admin_username
  }

  source {
    script = <<-EOT
      param(
          [Parameter(Mandatory)]
          [string]$PodmanMsiUrl,
          [string]$PodmanMsiSha256,
          [Parameter(Mandatory)]
          [string]$AccountName
      )

      $ErrorActionPreference = 'Stop'

      # A fixed name: a SAS URL has a query string after the file name.
      $installer = Join-Path $env:TEMP 'podman-setup.msi'
      $log = Join-Path $env:TEMP 'podman-msi.log'

      Invoke-WebRequest -Uri $PodmanMsiUrl -OutFile $installer -UseBasicParsing

      if ($PodmanMsiSha256) {
          $actual = (Get-FileHash -Path $installer -Algorithm SHA256).Hash
          if ($actual -ne $PodmanMsiSha256) {
              throw "Podman MSI SHA-256 $actual does not match the expected $PodmanMsiSha256."
          }
      }

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

      # Workaround for podman-container-tools/podman#30266: add the admin to
      # Hyper-V Administrators here, as SYSTEM. The run_as_user logon in
      # prepare-podman-hyperv then carries the group in its token, so
      # `podman system hyperv-prep` skips the user.Current() call that fails
      # when the user's profile is not loaded.
      $accountName = $AccountName
      ${local.add_user_to_hyperv_admins}

      # prepare-podman-hyperv is the first run_as_user command, and run-as
      # needs Secondary Logon.
      Set-Service -Name seclogon -StartupType Automatic
      Start-Service -Name seclogon
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

  timeouts {
    create = "15m"
    update = "15m"
  }

  source {
    script = <<-EOT
      $ErrorActionPreference = 'Stop'

      $podman = Join-Path $env:ProgramFiles 'Podman\podman.exe'

      if (-not (Test-Path -Path $podman)) {
          throw 'Podman executable not found.'
      }

      # Pre-create the HKLM VSock entries so the runner account can create
      # and manage Hyper-V machines without an elevated token. install-podman
      # already added this account to Hyper-V Administrators (see #30266).
      # Run-as output is not always returned to Azure, so keep a log too.
      $log = Join-Path $env:ProgramData 'podman-hyperv-prep.log'
      $ErrorActionPreference = 'Continue'
      # --mounts 3: podman 6.3 `machine init` defaults to three volumes (home,
      # C:\, and %APPDATA%\containers), but hyperv-prep only creates two
      # Fileserver entries by default. With too few, a non-admin init fails with
      # "the first time Podman initializes a Hyper-V machine, it requires admin
      # rights".
      & $podman system hyperv-prep --mounts 3 2>&1 | Tee-Object -FilePath $log
      $prepExit = $LASTEXITCODE
      & $podman system hyperv-prep --status 2>&1 | Tee-Object -FilePath $log -Append
      $ErrorActionPreference = 'Stop'

      if ($prepExit -ne 0) {
          throw "podman system hyperv-prep failed with exit code $prepExit. See $log"
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

  timeouts {
    create = "60m"
    update = "60m"
  }

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

      ${local.add_user_to_hyperv_admins}

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

      # Add the runner account to 'OpenSSH Users' so Windows sshd allows login.
      $sshGroupName = 'OpenSSH Users'
      if (-not (Get-LocalGroup -Name $sshGroupName -ErrorAction SilentlyContinue)) {
          New-LocalGroup -Name $sshGroupName | Out-Null
      }

      $userSid = ([Security.Principal.NTAccount]$accountName).Translate(
          [Security.Principal.SecurityIdentifier]
      ).Value

      $isGroupMember = Get-LocalGroupMember -Group $sshGroupName -ErrorAction SilentlyContinue |
          Where-Object { $_.SID.Value -eq $userSid }

      if (-not $isGroupMember) {
          Add-LocalGroupMember -Group $sshGroupName -Member $RunnerUser
      }
    EOT
  }
}

# -----------------------------------------------------------------------
# Configure Podman Machine via SSH
# (run_as_user hits Resize-VHD "Incorrect function" with no console;
#  SSH provides a user session that has console access.)
# -----------------------------------------------------------------------
resource "terraform_data" "configure_podman_machine" {
  depends_on = [azurerm_virtual_machine_run_command.create_runner_user]

  triggers_replace = [
    var.runner_user,
    var.podman_machine_name,
    var.podman_cpus,
    var.podman_memory_mb,
    var.podman_disk_gb,
    azurerm_virtual_machine_run_command.create_runner_user.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      TARGET_IP    = azurerm_public_ip.pip.ip_address
      RUNNER_USER  = var.runner_user
      SSH_PASSWORD = random_password.runner_password.result
      MACHINE_NAME = var.podman_machine_name
      CPUS         = tostring(var.podman_cpus)
      MEMORY_MB    = tostring(var.podman_memory_mb)
      DISK_GB      = tostring(var.podman_disk_gb)
    }
    command = <<-EOT
      set -euo pipefail

      ASKPASS=$(mktemp)
      chmod 700 "$ASKPASS"
      printf '#!/bin/sh\nprintf "%%s\\n" "$SSH_PASSWORD"\n' > "$ASKPASS"
      trap 'rm -f "$ASKPASS"' EXIT

      export SSH_ASKPASS="$ASKPASS"
      export SSH_ASKPASS_REQUIRE=force

      SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

      echo "Waiting for SSH on $TARGET_IP:22 as $RUNNER_USER..."
      for attempt in $(seq 1 30); do
          if ssh $SSH_OPTS "$RUNNER_USER@$TARGET_IP" "exit 0" </dev/null 2>/dev/null; then
              echo "SSH ready after $attempt attempt(s)."
              break
          fi
          [ "$attempt" -eq 30 ] && { echo "Timed out waiting for SSH." >&2; exit 1; }
          echo "Attempt $attempt/30: not ready; retrying in 20s."
          sleep 20
      done

      REMOTE="powershell -NonInteractive -File - -MachineName $MACHINE_NAME -Cpus $CPUS -MemoryMB $MEMORY_MB -DiskGB $DISK_GB"
      timeout 3600 ssh $SSH_OPTS "$RUNNER_USER@$TARGET_IP" "$REMOTE" \
          < "${path.module}/Configure-PodmanMachine.ps1"
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
  depends_on         = [terraform_data.configure_podman_machine]

  timeouts {
    create = "15m"
    update = "15m"
  }

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

      # Trigger the task immediately so the machine starts under the Task
      # Scheduler service context. gvproxy launched by that task is NOT inside
      # the SSH session's Job Object and therefore persists after SSH disconnects.
      Start-ScheduledTask -TaskName 'Start-Podman-Machine'

      $deadline = (Get-Date).AddMinutes(5)
      do {
          Start-Sleep -Seconds 5
          $gv = Get-Process -Name 'gvproxy' -ErrorAction SilentlyContinue
          if ($gv) {
              Write-Host "gvproxy started (PID $($gv.Id))."
              break
          }
      } while ((Get-Date) -lt $deadline)

      if (-not $gv) {
          throw 'gvproxy did not start within timeout.'
      }
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