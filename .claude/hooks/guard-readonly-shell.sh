#!/usr/bin/env bash
# PreToolUse hook for the apply-debugger subagent. Mirrors the hard-stop
# deny rules in .opencode/agents/apply-debugger.md. Exit 2 blocks the call.
set -euo pipefail

cmd=$(jq -r '.tool_input.command // empty')
# Allow discarding output; any other redirect is treated as a write.
cmd=${cmd//[0-9]>\/dev\/null/}
cmd=${cmd//>\/dev\/null/}
cmd=${cmd//> \/dev\/null/}

deny_patterns=(
  'terraform[[:space:]]+(apply|destroy)'
  'terraform-with-secrets\.sh[[:space:]]+(apply|destroy)'
  'output[[:space:]]+(-json|-raw[[:space:]]+(vm_admin_password|runner_password))'
  'make[[:space:]]+(apply|destroy|password)'
  'az[[:space:]]+vm[[:space:]]+(run-command[[:space:]]+(invoke|create|update|delete)|restart|stop|start|deallocate|delete|redeploy|reimage)'
  '(^|[;&|[:space:]])rm[[:space:]]'
  'git[[:space:]]+(push|commit|reset|checkout|restore|clean)'
  '(^|[;&|[:space:]])(sed[[:space:]]+-i|tee|mv|cp)[[:space:]]'
  '>[^&]'
  'gh[[:space:]]+auth[[:space:]]+token'
)

for p in "${deny_patterns[@]}"; do
  if [[ $cmd =~ $p ]]; then
    echo "apply-debugger is read-only: blocked command matching /$p/. Describe the fix and ask the human instead." >&2
    exit 2
  fi
done
exit 0
