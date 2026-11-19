---
description: Show the output of every Azure VM run command, including enable-remote-management
---

Run `make run-commands` and walk the output in execution order:

`enable-remote-management`, `install-hyperv`, `install-podman`,
`prepare-podman-hyperv`, `create-runner-user`, `configure-podman-machine`,
`create-podman-startup-task`, `install-github-runner`, `verify-runner`.

For each command report:

- the execution state;
- whether the output shows success;
- the exact error text for a failure, with the surrounding 5 lines.

Then state the first failing command in the chain, because later failures are
usually downstream effects. Do not invoke, retry, or delete any run command.

$ARGUMENTS
