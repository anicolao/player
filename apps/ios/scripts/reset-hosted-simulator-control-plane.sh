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

# Ask launchd to terminate the stale service asynchronously. The immediately
# following exact simulator lease acquisition is the readiness event: it cannot
# return a simulator ID until launchd has served the create request. Do not add
# a second blocking restart/inventory phase, sleep, retry, or product prelaunch.
run_with_two_second_deadline launchctl kill SIGKILL "${service_target}"
