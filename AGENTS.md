# AGENTS.md

## Project

Terraform deploys a Windows Server 2025 Azure VM that hosts a Hyper-V-backed
Podman machine and a self-hosted GitHub Actions runner for
`kothar-hq/host-container-capabilities`.

| File | Purpose |
| --- | --- |
| `main.tf` | Terraform/provider configuration and all variables. |
| `vm.tf` | Resource group, network, NSG, public IP, NIC, VM, and base outputs. |
| `post-install.tf` | Release lookups, reboot readiness, and all Azure VM run commands. |
| `New-WindowsPodmanActionRunner.ps1` | Self-contained runner install/registration script invoked by a run command. |
| `Setup-WindowsPodmanActionRunner.ps1` | Final verification script invoked by a run command. |
| `terraform-with-secrets.sh` | Wrapper that injects `TF_VAR_github_token` from `gh auth token`. |
| `Makefile` | Validation, plan, status, and output shortcuts. |
| `.opencode/skills/` | Project skills. Load `azure-tf-vm` before changing infrastructure. |
| `.opencode/agents/` | `infra-reviewer` (read-only review) and `apply-debugger` (read-only triage). |
| `.opencode/commands/` | `/tf-validate`, `/tf-plan`, `/tf-status`, `/tf-run-commands`, `/tf-password`. |
| `.opencode/plugins/infra-tools/index.ts` | OpenCode tools: `infra_validate`, `infra_plan`, `infra_status`, `infra_run_commands`. |
| `.claude/` | Claude Code equivalents: skills and commands are symlinks into `.opencode/`; `agents/` mirrors the OpenCode agents with Claude frontmatter; `hooks/guard-readonly-shell.sh` enforces `apply-debugger`'s read-only shell; `settings.json` asks before apply/destroy/password. |
| `CLAUDE.md` | Imports this file for Claude Code. |

## Safety rules

- Never run `terraform apply`, `terraform destroy`, `make apply`, or
  `make destroy` without explicit user confirmation.
- Never commit `*.tfstate`, `*.tfstate.*`, `*.tfvars`, or secrets. Treat
  `vm_admin_password` and `runner_password` as sensitive.
- Use `./terraform-with-secrets.sh` or the Makefile for Terraform commands.
  Do not hard-code a GitHub token.
- Do not print full passwords or tokens in chat or logs unless the user
  explicitly asks for a specific secret.
- Keep RDP, SSH/SCP, and WinRM restricted to `local.my_ip_cidr`. Do not widen
  the source prefix to `*` or a broad range.
- `enable_remote_management` controls the SSH/SCP and WinRM NSG rules and the
  in-guest enablement. RDP remains available for bootstrap and readiness checks.
- Run commands are ordered. Do not remove the boot readiness check without
  replacing it with an equivalent TCP probe.
- The VM's Azure run commands use Windows PowerShell 5.1 semantics. Avoid
  PowerShell 7-only syntax in embedded scripts.

## Standard workflow

```bash
make validate     # fmt, validate, shellcheck, PSScriptAnalyzer, tflint, tfsec
make plan         # wrapper-based Terraform plan; never applies
make status       # Azure VM power/provisioning state
make run-commands # status and output of each Azure VM run command
make password     # sensitive VM admin password
make ip           # public IP
```

Apply only after the user confirms:

```bash
make apply CONFIRM=apply
```

## Cost-saving deallocation workflow

`patch_mode = "Manual"` on the VM prevents Windows Update from running
automatically, keeping the OS state stable between sessions.

```bash
make stop   # az vm deallocate — stops compute billing; disk, Podman machine,
            # and runner registration are all retained; Public IP stays the same
make start  # az vm start — VM resumes from where it stopped
make apply  # re-apply after start if scripts changed; only changed run commands re-run
```

For Podman-only iterations (new MSI only), change `podman_msi_path` and apply:
only `install_podman` re-runs (~10 min) because `configure_podman_machine`
triggers only when its own variables or the `create_runner_user` ID changes.

## OpenCode assets

- Skills: `azure-tf-vm` (infrastructure) and `powershell-run-commands`
  (run-command PowerShell). Load the relevant one before editing.
- Subagents: `infra-reviewer` for read-only review and `apply-debugger` for
  read-only triage of a failed apply or run command. Neither can edit files.
- Commands: `/tf-validate`, `/tf-plan`, `/tf-status`, `/tf-run-commands`, and
  `/tf-password` (explicit secret request only).
- Tools: `infra_validate`, `infra_plan`, `infra_status`,
  `infra_run_commands`. They wrap the Makefile targets and never apply or
  destroy.
- Validation dedents `<<-EOT` bodies before PSScriptAnalyzer runs, so lint
  matches what the VM receives. Local-exec `command` heredocs are bash and are
  skipped.

## Requirements

- Azure CLI authenticated with access to the target subscription.
- GitHub CLI authenticated with `repo` scope, or `TF_VAR_github_token` set.
- `nc` (netcat) available locally for the post-reboot TCP probe.
