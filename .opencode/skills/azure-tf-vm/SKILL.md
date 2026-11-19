---
name: Azure Terraform VM
description: Work on the Terraform Azure Windows VM that hosts the Hyper-V Podman machine and GitHub Actions runner. Use for plan/apply, remote access, run-command debugging, or changes to vm.tf and post-install.tf.
---

# Azure Terraform VM

## Use this skill when

- Changing the Azure VM, networking, NSG, remote access, or outputs.
- Changing any Azure VM run command or the PowerShell scripts it invokes.
- Planning or validating this repository before an apply.
- Diagnosing a failed apply, a failed run command, or an unreachable VM.

## Architecture at a glance

- `main.tf` owns providers and variables only.
- `vm.tf` owns the resource group, VNet/subnet, NSG, public IP, NIC, VM, and
  base outputs.
- `post-install.tf` owns release discovery, reboot readiness, and the ordered
  run commands that install Hyper-V, Podman, the runner account, the Podman
  machine, the startup task, and the GitHub Actions runner.
- `terraform-with-secrets.sh` injects `TF_VAR_github_token` from
  `gh auth token` unless the variable is already set.
- The VM is Windows Server 2025 Datacenter with nested virtualization. The
  default size is `Standard_D4s_v3`.

See `references/architecture.md` for the resource graph and remote-access
details.

## Non-negotiable safety

1. Never apply or destroy without explicit user confirmation.
2. Use `./terraform-with-secrets.sh` or `make`; never put a token in a command
   line or file.
3. Never print `vm_admin_password` or `runner_password` in full unless the user
   asks for that specific secret.
4. Keep management access scoped to `local.my_ip_cidr`. Do not use `*` or a
   broad CIDR for RDP, SSH/SCP, or WinRM.
5. Preserve the post-reboot TCP readiness probe. A fixed sleep alone is not
   sufficient.

## Standard workflow

```bash
make validate
make plan
```

`make validate` runs `terraform init -backend=false`, `terraform fmt -check`,
`terraform validate`, `shellcheck`, PSScriptAnalyzer on `.ps1` files and
Terraform heredocs, `tflint`, `tfsec`, and `git diff --check`.

After the user confirms the plan:

```bash
make apply CONFIRM=apply
```

Useful inspection commands:

```bash
make status
make run-commands
make ip
make password   # sensitive
```

## OpenCode assets

- `/tf-validate` — run `make validate` and report failures.
- `/tf-plan` — run the wrapper plan and summarize changes; never applies.
- `/tf-status` — VM state, IP, and run-command status.
- `/tf-run-commands` — per-command output and the first failure.
- `/tf-password` — explicit secret request only.
- Subagents: `infra-reviewer` (read-only review) and `apply-debugger`
  (read-only triage with a narrow Azure/Terraform shell allowlist).
- Plugin tools: `infra_validate`, `infra_plan`, `infra_status`,
  `infra_run_commands` from `.opencode/plugins/infra-tools`.

`make validate` dedents `<<-EOT` bodies before PSScriptAnalyzer runs, and skips
the bash local-exec `command` heredoc. Keep embedded PowerShell indented
consistently with the surrounding heredoc so the dedented script stays valid.

## Remote access

- RDP (`3389`) is always available from the current public IP and is used by
  the post-reboot readiness probe.
- `var.enable_remote_management` (default `true`) controls:
  - NSG rules for SSH/SCP (`22`) and WinRM HTTP (`5985`) from the same IP.
  - The `enable-remote-management` run command, which installs OpenSSH Server,
    enables `sshd`, ensures the SFTP subsystem, enables PS Remoting, starts
    WinRM, and creates the Windows firewall rules.
- The VM is a workgroup machine. `LocalAccountTokenFilterPolicy=1` is set so
  local administrators can authenticate remotely.
- SCP uses the SSH port and SFTP subsystem; there is no separate SCP port.
- WinRM HTTPS (`5986`) is not configured because no certificate is provisioned.

## Reboot readiness

`terraform_data.wait_for_reboot` runs a local `bash` command after Hyper-V
installation. It:

1. Verifies `nc` is installed.
2. Sleeps 60 seconds.
3. Probes `TARGET_IP:3389` with `nc -z -w 5` up to 30 times, 15 seconds apart.

If you change the readiness logic, keep a real TCP check and make failures
explicit. Do not replace it with a longer fixed sleep.

## Debugging order

1. `make status` — is the VM running and provisioned?
2. `make run-commands` — which run command failed, and what did it print?
3. `az vm get-instance-view` — boot diagnostics and VM agent status.
4. `az network nsg rule list` — confirm the current public IP is allowed.
5. `nc -z -w 5 <ip> 3389` — verify the readiness path from the devcontainer.
6. For runner/Podman failures, inspect the `install-github-runner` and
   `configure-podman-machine` run-command output.

See `references/troubleshooting.md` for common failure signatures.

## PowerShell

Embedded run-command scripts and standalone `.ps1` files are linted by
`make validate`. Read the `powershell-run-commands` skill before changing
parameter names, quoting, or `run_as_user` behavior.
