#!/usr/bin/env bash
set -euo pipefail

simulator_id="${PLAYER_CORE_SIMULATOR_ID:-}"
if [[ ! "${simulator_id}" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "PLAYER_CORE_SIMULATOR_ID must identify the isolated core-test simulator." >&2
  exit 2
fi

# The receiver test owns the two-second browser-to-app transition, not cold
# startup of Apple's out-of-process WebContent/WebPrivacy services. Ask Safari
# to start those services once on a deliberately closed loopback port, then let
# repository fixture verification do useful work while they initialize. There
# is no polling, retry, fixed delay, external network access, or success waiver:
# the real WebKit document event remains the authoritative test gate.
xcrun simctl openurl \
  "${simulator_id}" \
  "http://127.0.0.1:9/bookshelf-webkit-readiness"
