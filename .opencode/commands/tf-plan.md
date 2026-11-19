---
description: Run a Terraform plan through the secret-loading wrapper (never applies)
---

Run `./terraform-with-secrets.sh plan -no-color` from the repository root.

This target is plan-only. You must not run `apply`, `make apply`,
`terraform destroy`, or any command that changes Azure.

Before running:

1. Confirm `az account show` works and note the subscription.
2. Confirm the GitHub token path: the wrapper uses `TF_VAR_github_token` if it
   is already set, otherwise `gh auth token`. Never print the token.
3. Note that `data.http.my_ip` refreshes `local.my_ip_cidr`; the plan may show
   NSG changes if my public IP changed.

After running, summarize:

- resources to add, change, and destroy, by name;
- anything sensitive that would be replaced;
- every change to NSG rules, the `enable-remote-management` run command, or
  `terraform_data.wait_for_reboot`;
- any warning or error printed by Terraform.

End with an explicit statement: **no apply was performed**. Do not apply unless
I follow up with an explicit confirmation.

$ARGUMENTS
