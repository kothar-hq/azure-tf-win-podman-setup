# Architecture

## Resource graph

```text
data.http.my_ip ──► local.my_ip_cidr ──► NSG rules
resource group
  ├── VNet 10.0.0.0/16
  │     └── subnet 10.0.1.0/24
  ├── NSG (RDP always; SSH/WinRM when enable_remote_management)
  ├── public IP (Dynamic)
  ├── NIC ──► NSG association
  └── Windows Server 2025 VM
        ├── time_sleep.wait_for_vm_agent (2m)
        ├── enable-remote-management (optional)
        ├── install-hyperv (reboots)
        ├── terraform_data.wait_for_reboot (local nc probe on 3389)
        ├── install-podman
        ├── prepare-podman-hyperv
        ├── create-runner-user
        ├── configure-podman-machine
        ├── create-podman-startup-task
        ├── install-github-runner
        └── verify-runner
```

## NSG rules

| Priority | Name | Port | Source | Condition |
| --- | --- | --- | --- | --- |
| 100 | `Allow-RDP-From-MyIP` | 3389 | `local.my_ip_cidr` | Always |
| 110 | `Allow-SSH-From-MyIP` | 22 | `local.my_ip_cidr` | `enable_remote_management` |
| 120 | `Allow-WinRM-From-MyIP` | 5985 | `local.my_ip_cidr` | `enable_remote_management` |

`local.my_ip_cidr` is derived from `https://api.ipify.org?format=text` and is
refreshed on the next plan/apply. If your public IP changes, RDP/SSH/WinRM will
stop working until the NSG is refreshed.

## Remote access services

- **RDP**: Windows Remote Desktop, port 3389. Used by the reboot readiness probe.
- **SSH/SCP**: OpenSSH Server capability, `sshd` automatic, SFTP subsystem
  enabled, `PasswordAuthentication yes`, port 22.
- **PowerShell Remoting**: WinRM HTTP listener on port 5985 via
  `Enable-PSRemoting -SkipNetworkProfileCheck -Force`.
- **Workgroup auth**: `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\LocalAccountTokenFilterPolicy=1`.

## Credentials

- `random_password.vm_admin_password` — VM administrator, exposed as the
  sensitive `vm_admin_password` output.
- `random_password.runner_password` — local `podmanrunner` account, exposed as
  the sensitive `runner_password` output.
- `var.github_token` — used only to request a runner registration token. It is
  passed as an Azure run-command protected parameter.

## Provider notes

- AzureRM `~> 3.100`; the lock file currently resolves `3.117.1`.
- `azurerm_virtual_machine_run_command` uses the managed Run Command API.
- `hashicorp/http` resolves the latest Podman MSI and runner ZIP.
- `hashicorp/time` is used only for the short VM-agent settle delay.
- `terraform_data` (built-in) replaces the old six-minute reboot sleep with a
  local TCP probe.
