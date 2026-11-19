---
description: Run full local validation (fmt, validate, shellcheck, PSScriptAnalyzer, tflint, tfsec)
---

Run `make validate` in the repository root and report the result.

Rules:

- Never run `terraform apply`, `make apply`, `terraform destroy`, or
  `make destroy`.
- Do not edit files to make checks pass unless I ask. Report the failures first.
- If a tool is missing (`pwsh`, `shellcheck`, `nc`, `tflint`, `tfsec`), name the
  missing tool and the devcontainer feature that provides it. Do not install
  system packages ad hoc.
- `git diff --check` is part of the target. If the repo is not a Git repository
  the target will fail; report that instead of working around it.

Report a short table of check -> pass/fail, then for each failure the file,
line, and the smallest fix.

$ARGUMENTS
