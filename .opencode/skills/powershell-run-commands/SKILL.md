---
name: powershell-run-commands
description: Write, review, or debug PowerShell used in Azure VM run commands and the runner install scripts. Use for post-install.tf scripts, parameter passing, run_as_user, reboot handling, or PSScriptAnalyzer failures.
---

# PowerShell Run Commands

## Use this skill when

- Editing a `script = <<-EOT` block in `post-install.tf`.
- Editing `New-WindowsPodmanActionRunner.ps1` or
  `Setup-WindowsPodmanActionRunner.ps1`.
- Adding or renaming a run-command `parameter` or `protected_parameter`.
- Debugging a failed run command or a `run_as_user` script.

## Hard constraints

1. Azure VM run commands invoke a generated `script.ps1` and pass parameters as
   `-Name value`. Parameter names must match the Terraform `parameter` blocks.
2. Parameter values arrive as strings. Use `tostring()` for numbers in
   Terraform and explicit casts such as `[int]` in PowerShell.
3. Use `protected_parameter` for passwords and tokens so they are not logged.
4. `run_as_user` requires the Secondary Logon (`seclogon`) service. The
   `create-runner-user` command configures it before later commands use it.
5. A reboot ends the run command. Do not schedule a reboot and then continue
   with work that depends on the rebooted state.
6. The VM uses Windows PowerShell 5.1 semantics for run commands. Avoid
   PowerShell 7-only syntax.
7. Start scripts with `$ErrorActionPreference = 'Stop'` and throw on failure so
   the run command exits non-zero.
8. Make scripts idempotent. Run commands can be retried during an apply.

## Parameter passing

Terraform:

```hcl
parameter {
  name  = "MachineName"
  value = var.podman_machine_name
}

protected_parameter {
  name  = "RunnerPassword"
  value = random_password.runner_password.result
}
```

PowerShell:

```powershell
param(
    [Parameter(Mandatory)]
    [string]$MachineName,

    [Parameter(Mandatory)]
    [string]$RunnerPassword
)
```

Keep the parameter order aligned with the Terraform blocks. Do not rename one
side without the other.

## Quoting and special characters

- Passwords for `random_password.runner_password` use only `_+` as special
  characters to reduce command-line parsing risk.
- For paths, use `Join-Path` and quote variables:
  `Join-Path $env:ProgramFiles 'Podman'`.
- Avoid `$()` and `${}` inside Terraform heredocs when possible. Terraform
  interpolates `${...}`; use `$${...}` if PowerShell needs it literally.
- Prefer argument arrays over a single concatenated command string.

## Reboots

The Hyper-V install uses `Install-WindowsFeature -Restart`. The reboot is
handled outside the run command by `terraform_data.wait_for_reboot`, which
sleeps 60 seconds and probes TCP 3389 with `nc`. Do not add a fixed six-minute
`time_sleep` back in.

If you add another reboot, add an equivalent local TCP or Azure readiness check
and make the dependency explicit.

## `run_as_user`

- The account must have a real Windows profile before Podman state is created.
  `create-runner-user` uses the native `CreateProfile` API via P/Invoke.
- Run commands that use `run_as_user` may inherit SYSTEM's environment block.
  Set `USERPROFILE`, `APPDATA`, `LOCALAPPDATA`, `TEMP`, `TMP`, `HOME`,
  `HOMEDRIVE`, and `HOMEPATH` explicitly for the runner user.
- The user must be in Hyper-V Administrators (`S-1-5-32-578`) to manage the
  Hyper-V Podman machine.

## Validation

Run:

```bash
make ps-lint
```

`scripts/Test-PowerShell.ps1` analyzes both `.ps1` files and every `<<-EOT`
heredoc in the Terraform files. Fix errors and warnings before planning.

## Common pitfalls

- `Register-ScheduledTask` cannot combine `-Principal` with `-User`/`-Password`.
  Build the task with `New-ScheduledTask` and register it with `-InputObject`.
- PowerShell 5.1 does not support
  `Set-Service -StartupType AutomaticDelayedStart`; use
  `sc.exe config <service> start= delayed-auto`.
- `Get-Content` returns an array. Use `-match`/`-replace` carefully or add
  `-Raw` when a single string is required.
- When editing `sshd_config`, preserve the `Subsystem sftp` line or SCP breaks.
- `Enable-PSRemoting` needs `-SkipNetworkProfileCheck` on an Azure public
  network profile.
