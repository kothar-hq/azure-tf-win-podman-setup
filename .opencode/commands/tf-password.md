---
description: Print the sensitive VM admin password (explicit request only)
---

I am explicitly asking for the sensitive VM administrator password.

Run `make password` and show the value. Then:

- label it clearly as **sensitive**;
- remind me that it is stored in Terraform state and should not be committed,
  pasted into tickets, or shared in logs;
- offer the username from `terraform output -raw` only if I ask (default is
  `var.vm_admin_username`).

Do not run this for the runner account, and do not print `runner_password`,
`github_token`, or any state file contents.

$ARGUMENTS
