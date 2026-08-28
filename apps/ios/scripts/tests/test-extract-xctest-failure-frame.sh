#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
extractor="${script_dir}/../extract-xctest-failure-frame.swift"
fixture="${script_dir}/failure-screen-test-fixture.swift"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/player-failure-screen-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
extractor_binary="${test_root}/extract-xctest-failure-frame"
xcrun swiftc "${extractor}" -o "${extractor_binary}"

make_manifest() {
  local directory="$1"
  local selected_name="$2"
  local selected_timestamp="$3"
  local extra_json="${4:-}"
  mkdir -p "${directory}"
  jq -n \
    --arg name "${selected_name}" \
    --argjson timestamp "${selected_timestamp}" \
    --argjson extra "${extra_json:-[]}" \
    '[{testIdentifier: "PlayerUITests/Failure/testExample()",
       attachments: ([{exportedFileName: $name,
         suggestedHumanReadableName: "Screen Recording fixture.mp4",
         timestamp: $timestamp}] + $extra)}]' > "${directory}/manifest.json"
}

valid="${test_root}/valid"
mkdir -p "${valid}/Attachments" "${valid}/Diagnostics"
swift "${fixture}" generate "${valid}/Attachments/older.mp4"
: > "${valid}/Attachments/newer-empty.mp4"
make_manifest "${valid}/Attachments" older.mp4 100 \
  '[{"exportedFileName":"newer-empty.mp4","suggestedHumanReadableName":"Screen Recording empty.mp4","timestamp":200}]'

hung_xcrun="${test_root}/hung-xcrun"
printf '%s\n' '#!/bin/sh' 'trap "" TERM' 'while :; do :; done' > "${hung_xcrun}"
chmod +x "${hung_xcrun}"
capture_started_ns="$(python3 -c 'import time; print(time.time_ns())')"
if PLAYER_FAILURE_SCREEN_XCRUN="${hung_xcrun}" "${extractor_binary}" \
  --capture-live 11111111-2222-3333-4444-555555555555 \
  "${valid}/Diagnostics/live-attempt.png"; then
  echo "A non-returning live simulator screenshot was accepted." >&2
  exit 1
fi
capture_ended_ns="$(python3 -c 'import time; print(time.time_ns())')"
capture_milliseconds="$(( (capture_ended_ns - capture_started_ns) / 1000000 ))"
if (( capture_milliseconds < 1900 || capture_milliseconds > 2300 )); then
  echo "Live screenshot deadline escaped its two-second bound (${capture_milliseconds}ms)." >&2
  exit 1
fi
[[ ! -e "${valid}/Diagnostics/live-attempt.png" ]]

env -u DEVELOPER_DIR swift "${extractor}" "${valid}/Attachments" \
  "${valid}/Diagnostics/failure-screen.png" \
  "${valid}/Diagnostics/failure-screen-source.json"
swift "${fixture}" verify-blue "${valid}/Diagnostics/failure-screen.png"
jq -e '
  .schemaVersion == 1
  and .artifact == "Diagnostics/failure-screen.png"
  and .source == "xctest-screen-recording"
  and .attachment == "Attachments/older.mp4"
  and .testIdentifier == "PlayerUITests/Failure/testExample()"
  and .attachmentTimestamp == 100
  and .requestedTimeSeconds > 0
  and .actualTimeSeconds >= 0
  and .actualTimeSeconds <= .requestedTimeSeconds
  and .pixelWidth == 16 and .pixelHeight == 16
' "${valid}/Diagnostics/failure-screen-source.json" >/dev/null

corrupt="${test_root}/corrupt"
mkdir -p "${corrupt}/Attachments" "${corrupt}/Diagnostics"
cp "${valid}/Attachments/older.mp4" "${corrupt}/Attachments/older.mp4"
printf '%s\n' 'not a movie' > "${corrupt}/Attachments/newer.mp4"
make_manifest "${corrupt}/Attachments" older.mp4 100 \
  '[{"exportedFileName":"newer.mp4","suggestedHumanReadableName":"Screen Recording corrupt.mp4","timestamp":300}]'
if swift "${extractor}" "${corrupt}/Attachments" \
  "${corrupt}/Diagnostics/failure-screen.png" \
  "${corrupt}/Diagnostics/failure-screen-source.json"; then
  echo "Newest nonempty corrupt recordings must fail closed." >&2
  exit 1
fi
[[ ! -e "${corrupt}/Diagnostics/failure-screen.png" ]]
[[ ! -e "${corrupt}/Diagnostics/failure-screen-source.json" ]]

unsafe="${test_root}/unsafe"
mkdir -p "${unsafe}/Attachments" "${unsafe}/Diagnostics"
cp "${valid}/Attachments/older.mp4" "${unsafe}/Attachments/older.mp4"
make_manifest "${unsafe}/Attachments" ../older.mp4 400
if swift "${extractor}" "${unsafe}/Attachments" \
  "${unsafe}/Diagnostics/failure-screen.png" \
  "${unsafe}/Diagnostics/failure-screen-source.json"; then
  echo "Unsafe attachment paths must fail closed." >&2
  exit 1
fi

no_recording="${test_root}/none"
mkdir -p "${no_recording}/Attachments" "${no_recording}/Diagnostics"
printf '%s\n' '[]' > "${no_recording}/Attachments/manifest.json"
if swift "${extractor}" "${no_recording}/Attachments" \
  "${no_recording}/Diagnostics/failure-screen.png" \
  "${no_recording}/Diagnostics/failure-screen-source.json"; then
  echo "A missing recording must fail closed." >&2
  exit 1
fi

echo "XCTest failure-frame extraction tests passed."
