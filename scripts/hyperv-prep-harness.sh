#!/usr/bin/env bash
# Test harness for podman-container-tools/podman#30266.
#
# Copies suffixed podman builds (podman-<suffix>.exe) to the VM over scp and
# runs `podman system hyperv-prep` with each one through an Azure VM Run
# Command using run_as_user. Every test uses a brand-new local administrator
# that has never logged on, is not in Hyper-V Administrators, and starts with
# no Podman vsock registry entries.
#
# Usage: scripts/hyperv-prep-harness.sh <bin-dir> [suffix ...]
#   <bin-dir>  directory containing podman-<suffix>.exe files
#   suffix     test only these builds (default: every podman-*.exe in bin-dir)
#
# Needs a deployed VM with enable_remote_management=true. Never applies.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ps_dir="$repo/scripts/hyperv-prep-harness"
# Keep the key off the workspace mount: it may force 0777, which ssh rejects.
state_dir="${HARNESS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hyperv-prep-harness}"
tf="$repo/terraform-with-secrets.sh"

bin_dir=${1:?usage: $0 <bin-dir> [suffix ...]}
shift
if [ "$#" -gt 0 ]; then
  suffixes=("$@")
else
  mapfile -t suffixes < <(find "$bin_dir" -maxdepth 1 -name 'podman-*.exe' -printf '%f\n' |
    sed -e 's/^podman-//' -e 's/\.exe$//' | sort)
fi
[ "${#suffixes[@]}" -gt 0 ] || { echo "no podman-*.exe in $bin_dir" >&2; exit 1; }

cd "$repo"
rg=$("$tf" output -raw resource_group_name)
vm=$("$tf" output -raw vm_name)
ip=$("$tf" output -raw vm_public_ip)
admin=$(terraform output -json 2>/dev/null | jq -r '.vm_admin_username.value // "azureuser"')
remote_dir='C:/podman-test'

mkdir -p "$state_dir/results"
chmod 700 "$state_dir"
key="$state_dir/id_ed25519"
[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C hyperv-prep-harness -f "$key"
ssh_opts=(-i "$key" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$state_dir/known_hosts" -o ConnectTimeout=15)

# run_cmd <name> <script-file> [--run-as-user U --run-as-password P] -- [k=v ...]
# Creates/updates a managed run command, waits for it, prints its output, and
# returns 0 only when it succeeded. A unique header line forces Azure to
# re-execute even when the script and parameters are unchanged.
run_cmd() {
  # The VM keeps each name's last sequence number after the run command is
  # deleted, and silently skips a re-created one (it times out as Pending),
  # so every harness run uses fresh names.
  local name="$1-$run_id" script=$2; shift 2
  local extra=() params=() protected=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do extra+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  for kv in "$@"; do
    case $kv in
      secret:*) protected+=("${kv#secret:}") ;;
      *) params+=("$kv") ;;
    esac
  done
  local args=(--resource-group "$rg" --vm-name "$vm" --name "$name"
    --script "$(printf "# harness run %s\n" "$(date +%s%N)"; cat "$script")" --timeout-in-seconds 600 --only-show-errors -o none)
  [ "${#params[@]}" -gt 0 ] && args+=(--parameters "${params[@]}")
  [ "${#protected[@]}" -gt 0 ] && args+=(--protected-parameters "${protected[@]}")
  local err="$state_dir/results/$name.az.err"
  # A failing script also makes `create` exit non-zero, so only treat
  # non-extension errors (quota, auth, bad request) as harness failures.
  if ! az vm run-command create "${args[@]}" "${extra[@]}" >/dev/null 2>"$err" &&
    ! grep -q VMExtensionProvisioningError "$err"; then
    echo "az vm run-command create $name failed:" >&2
    cat "$err" >&2
    exit 1
  fi
  az vm run-command show --resource-group "$rg" --vm-name "$vm" --name "$name" --instance-view \
    --query '{state:instanceView.executionState,exit:instanceView.exitCode,output:instanceView.output,error:instanceView.error}' \
    -o json >"$state_dir/results/$name.json"
  # Azure allows 25 managed run commands per VM; the results are saved above.
  az vm run-command delete --resource-group "$rg" --vm-name "$vm" --name "$name" \
    --yes --only-show-errors >/dev/null || true
  jq -r '"[\(.state) exit=\(.exit)]", (.output // "<no output>"), (if (.error // "") != "" then "stderr: " + .error else empty end)' \
    "$state_dir/results/$name.json"
  [ "$(jq -r .state "$state_dir/results/$name.json")" = Succeeded ]
}

run_id=$(date +%y%m%d%H%M%S)
# HARNESS_INVOKE picks the run_as_user test script: "debug" (default) logs
# podman's output; "issue" runs the unchanged script from podman#30266.
case "${HARNESS_INVOKE:-debug}" in
  debug) invoke_script="$ps_dir/Invoke-HypervPrepTest.ps1" ;;
  issue) invoke_script="$ps_dir/Invoke-IssueScript.ps1" ;;
  *) echo "HARNESS_INVOKE must be debug or issue" >&2; exit 1 ;;
esac

echo "== removing leftover harness run commands"
for leftover in $(az vm run-command list --resource-group "$rg" --vm-name "$vm" \
  --query "[?starts_with(name, 'hvp-')].name" -o tsv); do
  az vm run-command delete --resource-group "$rg" --vm-name "$vm" --name "$leftover" \
    --yes --only-show-errors >/dev/null
done

echo "== installing harness SSH key on $vm ($ip)"
run_cmd hvp-install-key "$ps_dir/Install-HarnessSshKey.ps1" -- "PublicKey=$(cat "$key.pub")"

for sfx in "${suffixes[@]}"; do
  echo "== copying podman-$sfx.exe"
  scp -q "${ssh_opts[@]}" "$bin_dir/podman-$sfx.exe" "$admin@$ip:$remote_dir/podman-$sfx.exe"
done

summary=()
for sfx in "${suffixes[@]}"; do
  user="hvp-$sfx"
  user=${user:0:20}
  password="Hv1!$(openssl rand -base64 18 | tr -d '/+=')"
  log="$remote_dir/logs/$sfx.log"
  exe="$remote_dir/podman-$sfx.exe"

  echo
  echo "################ $sfx (run_as_user=$user)"
  run_cmd "hvp-setup-$sfx" "$ps_dir/Initialize-HypervPrepTest.ps1" -- \
    "TestUser=$user" "secret:TestPassword=$password"

  if run_cmd "hvp-test-$sfx" "$invoke_script" \
    --run-as-user "$user" --run-as-password "$password" -- \
    "PodmanExe=$exe" "LogPath=$log"; then
    azure=pass
  else
    azure=FAIL
  fi

  echo "-- on-VM log and state (SYSTEM)"
  run_cmd "hvp-result-$sfx" "$ps_dir/Get-HypervPrepTestResult.ps1" -- \
    "TestUser=$user" "LogPath=$log" | tee "$state_dir/results/$sfx.log"
  state=$(grep -o "RESULT.*" "$state_dir/results/$sfx.log" | tail -1 || true)
  prep=$(grep -o "hyperv-prep-exit=[0-9-]*" "$state_dir/results/$sfx.log" | tail -1 || true)
  summary+=("$(printf '%-12s run-command=%-4s %-20s %s' "$sfx" "$azure" "${prep:-hyperv-prep-exit=?}" "${state#RESULT }")")
done

echo
echo "================ summary"
printf '%s\n' "${summary[@]}" | tee "$state_dir/results/summary.txt"
