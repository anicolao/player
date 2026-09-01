#!/usr/bin/env bash
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
  echo "Simulator control-plane reset is restricted to isolated GitHub Actions jobs." >&2
  exit 2
fi

service_target="user/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService"

run_with_two_second_deadline() {
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' 2 "$@"
}

# Ask launchd to terminate the stale service asynchronously. A missing service
# is already the requested terminal state; launchctl reports that state as 113.
# Reject every other failure, then require one real CoreSimulator RPC to prove
# launchd re-registration has completed before the following lease creation.
# Do not add a sleep, retry, inventory loop, or product prelaunch.
set +e
run_with_two_second_deadline launchctl kill SIGKILL "${service_target}"
reset_status=$?
set -e
case "${reset_status}" in
  0|113)
    ;;
  *)
    exit "${reset_status}"
    ;;
esac
run_with_two_second_deadline xcrun simctl list runtimes --json >/dev/null
