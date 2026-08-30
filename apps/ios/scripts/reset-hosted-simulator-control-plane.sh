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

run_with_two_second_deadline launchctl kickstart -k "${service_target}"
# The successful inventory response is the readiness event for the restarted
# service. Do not sleep, retry, or launch the product to warm the simulator.
run_with_two_second_deadline xcrun simctl list devices --json >/dev/null
