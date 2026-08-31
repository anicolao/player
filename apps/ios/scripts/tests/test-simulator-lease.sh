#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_scripts="$(cd "${script_dir}/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/player-simulator-lease.XXXXXX")"
trap 'rm -rf "${temporary_root}"' EXIT

fail() {
  echo "Simulator lease test failed: $*" >&2
  exit 1
}

fake_bin="${temporary_root}/fake-bin"
fake_state="${temporary_root}/fake-state"
lease_root="${temporary_root}/leases"
mkdir -p "${fake_bin}" "${fake_state}" "${lease_root}"
: > "${fake_state}/devices"
: > "${fake_state}/ids"
: > "${fake_state}/simctl.log"
: > "${fake_state}/delete-failures"

cat > "${fake_bin}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == simctl ]] || exit 2
shift
action="${1:-}"
shift
printf '%s\t%s\n' "${action}" "$*" >> "${PLAYER_TEST_SIMCTL_LOG}"
case "${action}" in
  create)
    simulator_id="$(sed -n '1p' "${PLAYER_TEST_SIMCTL_IDS}")"
    [[ -n "${simulator_id}" ]] || exit 1
    sed '1d' "${PLAYER_TEST_SIMCTL_IDS}" > "${PLAYER_TEST_SIMCTL_IDS}.next"
    mv "${PLAYER_TEST_SIMCTL_IDS}.next" "${PLAYER_TEST_SIMCTL_IDS}"
    printf '%s\n' "${simulator_id}" >> "${PLAYER_TEST_SIMCTL_DEVICES}"
    printf '%s\n' "${simulator_id}"
    ;;
  shutdown)
    ;;
  delete)
    simulator_id="${1:-}"
    [[ "${simulator_id}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
      || exit 9
    if grep -qxF "${simulator_id}" "${PLAYER_TEST_SIMCTL_DELETE_FAILURES}"; then
      exit 7
    fi
    grep -vxF "${simulator_id}" "${PLAYER_TEST_SIMCTL_DEVICES}" \
      > "${PLAYER_TEST_SIMCTL_DEVICES}.next" || true
    mv "${PLAYER_TEST_SIMCTL_DEVICES}.next" "${PLAYER_TEST_SIMCTL_DEVICES}"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "${fake_bin}/xcrun"

lease_environment=(
  "PATH=${fake_bin}:${PATH}"
  "PLAYER_TEST_SIMCTL_LOG=${fake_state}/simctl.log"
  "PLAYER_TEST_SIMCTL_IDS=${fake_state}/ids"
  "PLAYER_TEST_SIMCTL_DEVICES=${fake_state}/devices"
  "PLAYER_TEST_SIMCTL_DELETE_FAILURES=${fake_state}/delete-failures"
)
lease_tool="${ios_scripts}/simulator-lease.sh"

run_lease_tool() {
  env "${lease_environment[@]}" "${lease_tool}" "$@"
}

write_stale_lease() {
  local lease_file="$1"
  local simulator_id="$2"
  jq -n \
    --argjson formatVersion 1 \
    --arg udid "${simulator_id}" \
    --arg displayName 'Stale Player Simulator' \
    --arg deviceType 'test-device' \
    --arg runtime 'test-runtime' \
    --argjson ownerPID 99999999 \
    --arg ownerStartedAt 'stale-owner' \
    '{formatVersion: $formatVersion, udid: $udid, displayName: $displayName,
      deviceType: $deviceType, runtime: $runtime,
      owner: {pid: $ownerPID, startedAt: $ownerStartedAt}}' > "${lease_file}"
}

run_lease_tool reconcile "${lease_root}"
[[ ! -s "${fake_state}/simctl.log" ]] \
  || fail "empty reconciliation changed simulator state"

first_id='11111111-1111-1111-1111-111111111111'
second_id='55555555-5555-5555-5555-555555555555'
printf '%s\n%s\n' "${first_id}" "${second_id}" > "${fake_state}/ids"
first_lease="${lease_root}/first.json"
acquired="$(run_lease_tool acquire "${first_lease}" 'Player Lease Test' \
  test-device test-runtime "$$")"
[[ "${acquired}" == "${first_id}" ]] || fail "acquire returned the wrong UDID"
[[ "$(jq -r '.udid' "${first_lease}")" == "${first_id}" ]] \
  || fail "acquire did not persist the exact UDID"

run_lease_tool reconcile "${lease_root}"
[[ -e "${first_lease}" ]] || fail "reconciliation removed a live owner's lease"
rg -qxF "${first_id}" "${fake_state}/devices" \
  || fail "reconciliation removed a live owner's simulator"

second_lease="${lease_root}/second.json"
second_acquired="$(run_lease_tool acquire "${second_lease}" 'Concurrent Player Lease Test' \
  test-device test-runtime "$$")"
[[ "${second_acquired}" == "${second_id}" ]] \
  || fail "concurrent acquire returned the wrong UDID"
[[ -e "${first_lease}" && -e "${second_lease}" ]] \
  || fail "concurrent acquire did not preserve both live leases"
rg -qxF "${first_id}" "${fake_state}/devices" \
  || fail "concurrent acquire removed the first simulator"
rg -qxF "${second_id}" "${fake_state}/devices" \
  || fail "concurrent acquire did not create the second simulator"

run_lease_tool release "${second_lease}" "$$"
[[ ! -e "${second_lease}" ]] || fail "second release retained its completed lease"
[[ -e "${first_lease}" ]] || fail "second release removed the first lease"
rg -qxF "${first_id}" "${fake_state}/devices" \
  || fail "second release removed the first simulator"
if rg -q $'^delete\t'"${first_id}"'$' "${fake_state}/simctl.log"; then
  fail "second release issued a delete for the first simulator"
fi
run_lease_tool release "${first_lease}" "$$"
[[ ! -e "${first_lease}" ]] || fail "first release retained its completed lease"
rg -q $'^shutdown\t'"${first_id}"'$' "${fake_state}/simctl.log" \
  || fail "release did not shut down the exact leased UDID"
rg -q $'^delete\t'"${first_id}"'$' "${fake_state}/simctl.log" \
  || fail "release did not delete the exact leased UDID"
rg -q $'^delete\t'"${second_id}"'$' "${fake_state}/simctl.log" \
  || fail "second release did not delete its exact leased UDID"

delete_failure_id='66666666-6666-6666-6666-666666666666'
delete_failure_lease="${lease_root}/delete-failure.json"
delete_failure_harness="${temporary_root}/delete-failure-harness.sh"
printf '%s\n' "${delete_failure_id}" > "${fake_state}/ids"
printf '%s\n' "${delete_failure_id}" > "${fake_state}/delete-failures"
cat > "${delete_failure_harness}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
lease_tool="$1"
lease_file="$2"
"${lease_tool}" acquire "${lease_file}" 'Delete Failure Lease Test' \
  test-device test-runtime "$$" >/dev/null
if "${lease_tool}" release "${lease_file}" "$$" >/dev/null 2>&1; then
  exit 9
fi
[[ -f "${lease_file}" && ! -L "${lease_file}" ]]
EOF
chmod +x "${delete_failure_harness}"
env "${lease_environment[@]}" \
  "${delete_failure_harness}" "${lease_tool}" "${delete_failure_lease}"
[[ -e "${delete_failure_lease}" ]] \
  || fail "delete failure discarded the valid ownership lease"
[[ "$(jq -r '.udid' "${delete_failure_lease}")" == "${delete_failure_id}" ]] \
  || fail "delete failure corrupted the retained ownership lease"
rg -qxF "${delete_failure_id}" "${fake_state}/devices" \
  || fail "delete failure lost track of the leased simulator"
: > "${fake_state}/delete-failures"
run_lease_tool reconcile "${lease_root}"
[[ ! -e "${delete_failure_lease}" ]] \
  || fail "later reconciliation retained the dead owner's lease"
if rg -qxF "${delete_failure_id}" "${fake_state}/devices"; then
  fail "later reconciliation retained the dead owner's simulator"
fi

stale_id='22222222-2222-2222-2222-222222222222'
unrelated_id='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA'
printf '%s\n%s\n' "${stale_id}" "${unrelated_id}" > "${fake_state}/devices"
stale_lease="${lease_root}/stale.json"
write_stale_lease "${stale_lease}" "${stale_id}"
run_lease_tool reconcile "${lease_root}"
[[ ! -e "${stale_lease}" ]] || fail "stale-owner reconciliation retained its lease"
rg -qxF "${unrelated_id}" "${fake_state}/devices" \
  || fail "reconciliation removed an unrelated simulator"
if rg -q "${unrelated_id}" "${fake_state}/simctl.log"; then
  fail "reconciliation issued a command for an unrelated simulator"
fi

malformed_id='33333333-3333-3333-3333-333333333333'
printf '%s\n%s\n' "${malformed_id}" "${unrelated_id}" > "${fake_state}/devices"
write_stale_lease "${lease_root}/valid-stale.json" "${malformed_id}"
printf '{"udid":"not-a-uuid"}\n' > "${lease_root}/malformed.json"
: > "${fake_state}/simctl.log"
if run_lease_tool reconcile "${lease_root}" >/dev/null 2>&1; then
  fail "malformed lease was accepted"
fi
[[ ! -s "${fake_state}/simctl.log" ]] \
  || fail "malformed reconciliation changed simulator state"
[[ -e "${lease_root}/valid-stale.json" ]] \
  || fail "malformed reconciliation partially released a valid lease"
if run_lease_tool release "${lease_root}/malformed.json" "$$" >/dev/null 2>&1; then
  fail "malformed lease was released"
fi
[[ ! -s "${fake_state}/simctl.log" ]] \
  || fail "malformed release changed simulator state"
rm -f "${lease_root}/valid-stale.json" "${lease_root}/malformed.json"

signal_id='44444444-4444-4444-4444-444444444444'
signal_lease="${lease_root}/signal.json"
signal_ready="${temporary_root}/signal-ready"
signal_harness="${temporary_root}/signal-harness.sh"
printf '%s\n' "${signal_id}" > "${fake_state}/ids"
cat > "${signal_harness}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
lease_tool="$1"
lease_file="$2"
ready_file="$3"
cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  "${lease_tool}" release "${lease_file}" "$$"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${lease_tool}" acquire "${lease_file}" 'Signal Lease Test' \
  test-device test-runtime "$$" >/dev/null
: > "${ready_file}"
while :; do :; done
EOF
chmod +x "${signal_harness}"
env "${lease_environment[@]}" \
  "${signal_harness}" "${lease_tool}" "${signal_lease}" "${signal_ready}" &
signal_process=$!
deadline=$((SECONDS + 2))
while [[ ! -e "${signal_ready}" ]]; do
  kill -0 "${signal_process}" >/dev/null 2>&1 \
    || fail "signal harness exited before acquiring its lease"
  (( SECONDS < deadline )) || fail "signal harness did not become ready within two seconds"
done
kill -TERM "${signal_process}"
if wait "${signal_process}"; then
  fail "signal harness unexpectedly exited successfully"
else
  signal_status=$?
fi
[[ "${signal_status}" -eq 143 ]] || fail "TERM was not preserved as exit status 143"
[[ ! -e "${signal_lease}" ]] || fail "TERM cleanup retained the simulator lease"
rg -q $'^delete\t'"${signal_id}"'$' "${fake_state}/simctl.log" \
  || fail "TERM cleanup did not delete the exact leased simulator"

for owning_caller in \
  "${ios_scripts}/run-e2e.sh" \
  "${ios_scripts}/run-e2e-shard.sh" \
  "${ios_scripts}/qualification/run-matrix-lane.sh"; do
  rg -q -F "trap 'exit 130' INT" "${owning_caller}" \
    || fail "$(basename "${owning_caller}") does not trap INT"
  rg -q -F "trap 'exit 143' TERM" "${owning_caller}" \
    || fail "$(basename "${owning_caller}") does not trap TERM"
done

echo "Simulator lease ownership, reconciliation, and signal cleanup tests passed."
