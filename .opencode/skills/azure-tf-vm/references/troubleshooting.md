# Troubleshooting

## `wait_for_reboot` fails with `nc: command not found`

The local machine running Terraform needs netcat. The devcontainer installs
`netcat-openbsd`. Rebuild or reopen the devcontainer, or install `nc` on the
host that runs Terraform.

## `wait_for_reboot` times out

1. Confirm the VM is running:
   ```bash
   make status
   ```
2. Confirm the current public IP is in the NSG:
   ```bash
   terraform output -raw vm_public_ip
   curl -s https://api.ipify.org?format=text
   az network nsg rule list -g tf-demo-rg --nsg-name tf-demo-rdp-nsg -o table
   ```
3. Probe manually:
   ```bash
   nc -z -v -w 5 "$(./terraform-with-secrets.sh output -raw vm_public_ip)" 3389
   ```
4. Check boot diagnostics and the VM agent:
   ```bash
   az vm get-instance-view -g tf-demo-rg -n w-pdm-hpv-vm \
     --query 'instanceView.statuses[].{code:code,display:displayStatus}' -o table
   ```

If your public IP changed, re-run `make plan` / `make apply` so the NSG picks up
the new `local.my_ip_cidr`.

## SSH or SCP fails

- Confirm `enable_remote_management = true`.
- Confirm the `enable-remote-management` run command succeeded.
- Confirm `sshd` is running:
  ```powershell
  Get-Service sshd
  ```
- Verify the NSG source IP matches your current public IP.
- SCP uses the SSH port and the SFTP subsystem; ensure `Subsystem sftp` remains
  in `C:\ProgramData\ssh\sshd_config`.

## PowerShell Remoting fails

- Confirm the `enable-remote-management` run command succeeded.
- Confirm WinRM is running and listening:
  ```powershell
  Get-Service WinRM
  winrm enumerate winrm/config/listener
  ```
- From the client, test:
  ```powershell
  Test-WSMan -ComputerName <ip>
  ```
- For a workgroup VM, `LocalAccountTokenFilterPolicy=1` must be set.
- Use `-Authentication Negotiate` when connecting with a local administrator.

## `install-hyperv` fails or reports a reboot

`Install-WindowsFeature -Restart` reboots the VM, so the run command can report
a non-zero exit even though installation succeeded. Confirm the feature and
give the reboot probe time to complete:

```powershell
Get-WindowsFeature Hyper-V, Hyper-V-PowerShell
```

Do not remove the `terraform_data.wait_for_reboot` dependency.

## Podman machine fails to start

- The VM must support nested virtualization (`Standard_D4s_v3` or larger).
- The `prepare-podman-hyperv` run command must run as the VM administrator and
  complete `podman system hyperv-prep`.
- The runner user must be a member of Hyper-V Administrators.
- Inspect the `configure-podman-machine` run-command output for the exact
  `podman machine init` or `podman info` error.

## GitHub runner does not register

- `var.github_token` needs `repo` scope and admin access to
  `kothar-hq/host-container-capabilities`.
- Use `./terraform-with-secrets.sh plan` so `TF_VAR_github_token` is populated.
- Inspect the `install-github-runner` run-command output.
- Confirm the runner service exists and is running:
  ```powershell
  Get-Service actions.runner*
  ```
