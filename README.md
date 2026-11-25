# azure-tf-win-podman-setup

[![Validate](https://github.com/kothar-hq/azure-tf-win-podman-setup/actions/workflows/validate.yml/badge.svg)](https://github.com/kothar-hq/azure-tf-win-podman-setup/actions/workflows/validate.yml)

Terraform that builds a Windows Server 2025 VM in Azure with Hyper-V, a
Hyper-V-backed Podman machine, and a self-hosted GitHub Actions runner that
can use it.

## Why this exists

It was built to test
[`kothar-hq/host-container-capabilities`](https://github.com/kothar-hq/host-container-capabilities)
on a real Windows host running Podman on Hyper-V. GitHub's hosted Windows
runners can't do that, so this repo creates a VM that registers itself as a
runner for that repository.

While automating the Podman setup it found a Podman bug and became the test
bed for it:
[podman-container-tools/podman#30266](https://github.com/podman-container-tools/podman/issues/30266).
`podman system hyperv-prep` fails when it runs through an Azure run command
with `run_as_user`. The account has an elevated token but no loaded profile,
so Go's `user.Current()` fails and `hyperv-prep` exits with 125 after creating
the registry entries. Azure only reports `Incorrect function`.

The `test/hyperv-prep-30266` branch has a harness that reproduces the bug on
the VM and compares Podman builds. A build of
[`zippy1981/podman` `fix/hyperv-prep-token-sid`](https://github.com/zippy1981/podman/tree/fix/hyperv-prep-token-sid),
which reads the user from the process token instead, fixes it. The results are
in [this comment on the issue](https://github.com/podman-container-tools/podman/issues/30266#issuecomment-7052005983).

## What it deploys

All resources go into one resource group (`tf-demo-rg` by default):

- A VNet, subnet, NSG, public IP and NIC. RDP, SSH and WinRM are only open
  to the public IP of the machine running Terraform.
- A `Standard_D4s_v3` Windows Server 2025 VM with nested virtualization.
- Azure VM run commands, run in this order:

| Run command | What it does |
| --- | --- |
| `enable-remote-management` | Installs OpenSSH Server and enables WinRM (when `enable_remote_management = true`). |
| `install-hyperv` | Installs Hyper-V and reboots. Terraform waits for RDP to come back before going on. |
| `install-podman` | Installs the latest Podman MSI from GitHub with the Hyper-V provider. |
| `prepare-podman-hyperv` | Runs `podman system hyperv-prep` so a non-admin account can manage Hyper-V machines. |
| `create-runner-user` | Creates the local runner account (`podmanrunner`). |
| `configure-podman-machine` | Runs `podman machine init` and starts the machine as the runner account. |
| `create-podman-startup-task` | Adds a scheduled task that starts the Podman machine at boot. |
| `install-github-runner` | Downloads, registers and starts the Actions runner as a service. |
| `verify-runner` | Checks the Podman machine and the runner service. |

> [!WARNING]
> A full apply creates billable Azure resources, and the VM keeps costing money
> while it runs. Destroy it when you're done.

## Prerequisites

The easiest way is to open the repo in the included devcontainer
(`.devcontainer/`). It installs the Azure CLI, Terraform, tflint, tfsec,
PowerShell with PSScriptAnalyzer, shellcheck and netcat.

Without the devcontainer you need:

- Terraform 1.5 or later
- The Azure CLI, signed in to the target subscription (`az login`)
- The GitHub CLI with `repo` scope (`gh auth login`), or `TF_VAR_github_token`
  set. The token is used to get a runner registration token.
- `nc` (netcat), used to wait for the VM after the Hyper-V reboot
- For `make validate`: tflint, tfsec, shellcheck and `pwsh` with PSScriptAnalyzer

## Usage

```bash
az login
gh auth login

make validate                 # static checks, no Azure access
make plan                     # terraform plan through the secret-loading wrapper
make apply CONFIRM=apply      # create everything
```

Run Terraform through `./terraform-with-secrets.sh` or `make`, not plain
`terraform`. The wrapper sets `TF_VAR_github_token` from `gh auth token`, so
the token never ends up in a file or on a command line.

When the apply finishes:

```bash
make ip             # VM public IP
make status         # VM power and provisioning state
make run-commands   # status and output of every run command
make password       # VM admin password (sensitive)
```

To tear it down:

```bash
make destroy CONFIRM=destroy
```

`make help` lists every target. `apply` and `destroy` refuse to run without
the `CONFIRM` value.

## Configuration

Set variables in a `terraform.tfvars` file. `*.tfvars` is gitignored, so it
stays local. The main ones are:

| Variable | Default | Notes |
| --- | --- | --- |
| `resource_group_name` | `tf-demo-rg` | |
| `location` | `East US` | |
| `vm_name` | `w-pdm-hpv-vm` | |
| `vm_size` | `Standard_D4s_v3` | Must support nested virtualization. |
| `vm_admin_username` | `azureuser` | The password is generated. |
| `github_repository` | `kothar-hq/host-container-capabilities` | Repository the runner registers with. |
| `runner_labels` | `self-hosted,Windows,WindowsServer2025,podman,windows-podman` | |
| `runner_group` | `Default` | |
| `runner_user` | `podmanrunner` | Local account the runner and Podman machine run as. |
| `podman_machine_name` | `podman-machine-default` | |
| `podman_cpus` / `podman_memory_mb` / `podman_disk_gb` | `4` / `8192` / `80` | Podman machine size. |
| `enable_remote_management` | `true` | Opens SSH/SCP (22) and WinRM (5985) to your IP. |

See `main.tf` for the full list and descriptions.

## Branches

| Branch | Contents |
| --- | --- |
| `main` | The base environment described above. |
| `test/hyperv-prep-30266` | `scripts/hyperv-prep-harness.sh`, which copies Podman builds to the VM and runs `hyperv-prep` through `run_as_user` as a fresh, never-logged-on admin. It also has run-command fixes found while debugging #30266. |
| `feature/local-podman-msi` | Builds on the test branch. Adds `podman_msi_path` to install a local Podman MSI through a private storage account, and `podman_version` / `runner_version` to pin releases. |

On `feature/local-podman-msi`, installing a fixed Podman build gets past
`hyperv-prep`. `configure-podman-machine` then still fails when `Resize-VHD`
runs without a console under `run_as_user`. That part is not solved yet.

## Validation and CI

`make validate` runs:

- `terraform fmt -check` and `terraform validate`
- tflint and tfsec
- shellcheck
- PSScriptAnalyzer on the `.ps1` files and on the PowerShell in the Terraform
  heredocs. The heredocs are dedented first, so the lint sees what the VM runs.
- `git diff --check`

The [Validate](.github/workflows/validate.yml) workflow runs the same checks
on every pull request and every push to `main`. It never contacts Azure and
needs no secrets.

## AI agent support

`AGENTS.md` (imported by `CLAUDE.md`) has the safety rules and workflow for
coding agents. `.opencode/` and `.claude/` have matching skills, commands and
read-only review and debugging subagents.
