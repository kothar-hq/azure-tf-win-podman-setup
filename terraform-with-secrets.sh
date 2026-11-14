#!/usr/bin/env bash
#
# Run Terraform with secret variables populated from the local environment.
#
# Currently only TF_VAR_github_token is required. If it is not already set,
# the token is read from the authenticated GitHub CLI (`gh auth token`).
#
# Usage:
#   ./terraform-with-secrets.sh plan
#   ./terraform-with-secrets.sh apply
#   ./terraform-with-secrets.sh output -raw vm_admin_password
#
set -euo pipefail

if [[ -z "${TF_VAR_github_token:-}" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: TF_VAR_github_token is not set and the GitHub CLI (gh) is not installed." >&2
    echo "       Install gh, run 'gh auth login', or export TF_VAR_github_token manually." >&2
    exit 1
  fi

  if ! gh auth token >/dev/null 2>&1; then
    echo "error: TF_VAR_github_token is not set and gh is not authenticated." >&2
    echo "       Run 'gh auth login' with repo scope, or export TF_VAR_github_token manually." >&2
    exit 1
  fi

  TF_VAR_github_token="$(gh auth token)"
  export TF_VAR_github_token
fi

exec terraform "$@"
