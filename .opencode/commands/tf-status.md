---
description: Show VM power/provisioning state, public IP, and run-command status
---

Report the current state of the deployment without changing anything.

1. Run `make status` for VM power and provisioning state.
2. Run `make ip` for the public IP.
3. Run `make run-commands` for each Azure VM run command's execution state and
   output.

Then summarize:

- a table of run command -> state, and the first error line for any failure;
- whether `enable-remote-management` ran at all (it is conditional on
  `var.enable_remote_management`);
- whether `verify-runner` reported success;
- the VM public IP and the current client IP (`curl -s
  https://api.ipify.org?format=text`), so I can tell whether the NSG source
  still matches.

Do not apply, destroy, restart the VM, or invoke a run command.

$ARGUMENTS
