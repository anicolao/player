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
  '[{"exportedFileName":"issue.txt","suggestedHumanReadableName":"Complete Issue Description.txt"},{"exportedFileName":"newer-empty.mp4","suggestedHumanReadableName":"Screen Recording empty.mp4","timestamp":200}]'

missing_screenshot_status=0
swift "${extractor}" --failure-screenshot-only "${valid}/Attachments" \
  "${valid}/Diagnostics/missing-screenshot.png" \
  "${valid}/Diagnostics/missing-screenshot-source.json" \
  || missing_screenshot_status="$?"
[[ "${missing_screenshot_status}" == "2" ]]
[[ ! -e "${valid}/Diagnostics/missing-screenshot.png" ]]
[[ ! -e "${valid}/Diagnostics/missing-screenshot-source.json" ]]

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
# The extractor fires SIGKILL at exactly two seconds; this wall measurement also
# includes the host scheduler delivering the signal and reaping the process.
if (( capture_milliseconds < 1900 || capture_milliseconds > 2750 )); then
  echo "Live screenshot deadline or process-reap allowance escaped its bound (${capture_milliseconds}ms)." >&2
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

direct="${test_root}/direct-screenshot"
mkdir -p "${direct}/Attachments" "${direct}/Diagnostics"
cp "${valid}/Diagnostics/failure-screen.png" "${direct}/Attachments/failure.png"
cp "${valid}/Diagnostics/failure-screen.png" "${direct}/Attachments/later-passing.png"
cp "${valid}/Attachments/older.mp4" "${direct}/Attachments/older.mp4"
cp "${valid}/Attachments/older.mp4" "${direct}/Attachments/later-passing.mp4"
jq -n '[{testIdentifier: "PlayerUITests/Failure/testExample()",
  attachments: [
    {exportedFileName: "issue.txt",
      suggestedHumanReadableName: "Complete Issue Description.txt",
      isAssociatedWithFailure: true},
    {exportedFileName: "older.mp4",
      suggestedHumanReadableName: "Screen Recording fixture.mp4", timestamp: 300},
    {exportedFileName: "failure.png",
      suggestedHumanReadableName: "xctest-failure-screen_0_66A67D4C-8F3E-4D49-96B7-BBF13DCF045F.png", timestamp: 200}
  ]},
  {testIdentifier: "PlayerUITests/Passing/testLater()",
   attachments: [
    {exportedFileName: "later-passing.mp4",
      suggestedHumanReadableName: "Screen Recording later.mp4", timestamp: 500,
      isAssociatedWithFailure: false},
    {exportedFileName: "later-passing.png",
      suggestedHumanReadableName: "xctest-failure-screen_0_77777777-7777-7777-7777-777777777777.png",
      timestamp: 400, isAssociatedWithFailure: false}
  ]}]' > "${direct}/Attachments/manifest.json"
swift "${extractor}" "${direct}/Attachments" \
  "${direct}/Diagnostics/failure-screen.png" \
  "${direct}/Diagnostics/failure-screen-source.json"
swift "${fixture}" verify-blue "${direct}/Diagnostics/failure-screen.png"
jq -e '
  .schemaVersion == 1
  and .artifact == "Diagnostics/failure-screen.png"
  and .source == "xctest-failure-screenshot"
  and .attachment == "Attachments/failure.png"
  and .testIdentifier == "PlayerUITests/Failure/testExample()"
  and .attachmentTimestamp == 200
  and .pixelWidth == 16 and .pixelHeight == 16
' "${direct}/Diagnostics/failure-screen-source.json" >/dev/null

recording_only="${test_root}/recording-only"
mkdir -p "${recording_only}/Diagnostics"
swift "${extractor}" --recording-only "${direct}/Attachments" \
  "${recording_only}/Diagnostics/failure-screen.png" \
  "${recording_only}/Diagnostics/failure-screen-source.json"
jq -e '
  .source == "xctest-screen-recording"
  and .attachment == "Attachments/older.mp4"
' "${recording_only}/Diagnostics/failure-screen-source.json" >/dev/null

near_miss="${test_root}/near-miss-screenshot"
mkdir -p "${near_miss}/Attachments" "${near_miss}/Diagnostics"
cp "${valid}/Diagnostics/failure-screen.png" "${near_miss}/Attachments/near-miss.png"
jq -n '[{testIdentifier: "PlayerUITests/Failure/testExample()",
  attachments: [{exportedFileName: "near-miss.png",
    suggestedHumanReadableName: "xctest-failure-screen_unrelated.png", timestamp: 200}]}]' \
  > "${near_miss}/Attachments/manifest.json"
near_miss_status=0
swift "${extractor}" --failure-screenshot-only "${near_miss}/Attachments" \
  "${near_miss}/Diagnostics/failure-screen.png" \
  "${near_miss}/Diagnostics/failure-screen-source.json" \
  || near_miss_status="$?"
[[ "${near_miss_status}" == "2" ]]

wrong_format="${test_root}/wrong-format-screenshot"
mkdir -p "${wrong_format}/Attachments" "${wrong_format}/Diagnostics"
sips -s format jpeg "${valid}/Diagnostics/failure-screen.png" \
  --out "${wrong_format}/Attachments/failure.png" >/dev/null 2>&1
jq -n '[{testIdentifier: "PlayerUITests/Failure/testExample()",
  attachments: [{exportedFileName: "failure.png",
    suggestedHumanReadableName: "xctest-failure-screen_0_33333333-3333-3333-3333-333333333333.png",
    timestamp: 200}]}]' > "${wrong_format}/Attachments/manifest.json"
wrong_format_status=0
swift "${extractor}" --failure-screenshot-only "${wrong_format}/Attachments" \
  "${wrong_format}/Diagnostics/failure-screen.png" \
  "${wrong_format}/Diagnostics/failure-screen-source.json" \
  || wrong_format_status="$?"
[[ "${wrong_format_status}" == "1" ]]
[[ ! -e "${wrong_format}/Diagnostics/failure-screen.png" ]]
[[ ! -e "${wrong_format}/Diagnostics/failure-screen-source.json" ]]

jpeg_export="${test_root}/jpeg-exported-screenshot"
mkdir -p "${jpeg_export}/Attachments" "${jpeg_export}/Diagnostics"
cp "${valid}/Attachments/older.mp4" "${jpeg_export}/Attachments/older.mp4"
jpeg_name="33333333-4444-5555-6666-777777777777.jpeg"
sips -s format jpeg "${valid}/Diagnostics/failure-screen.png" \
  --out "${jpeg_export}/Attachments/${jpeg_name}" >/dev/null 2>&1
jq -n --arg jpeg "${jpeg_name}" '[{testIdentifier: "PlayerUITests/Failure/testExample()",
  attachments: [
    {exportedFileName: "older.mp4",
      suggestedHumanReadableName: "Screen Recording fixture.mp4", timestamp: 300},
    {exportedFileName: $jpeg,
      suggestedHumanReadableName: "xctest-failure-screen_0_33333333-3333-3333-3333-333333333333.png",
      timestamp: 200}
  ]}]' > "${jpeg_export}/Attachments/manifest.json"
jpeg_export_status=0
swift "${extractor}" --failure-screenshot-only "${jpeg_export}/Attachments" \
  "${jpeg_export}/Diagnostics/failure-screen.png" \
  "${jpeg_export}/Diagnostics/failure-screen-source.json" \
  || jpeg_export_status="$?"
[[ "${jpeg_export_status}" == "1" ]]
[[ ! -e "${jpeg_export}/Diagnostics/failure-screen.png" ]]
[[ ! -e "${jpeg_export}/Diagnostics/failure-screen-source.json" ]]
swift "${extractor}" --recording-only "${jpeg_export}/Attachments" \
  "${jpeg_export}/Diagnostics/recording-fallback.png" \
  "${jpeg_export}/Diagnostics/recording-fallback-source.json"
swift "${fixture}" verify-blue "${jpeg_export}/Diagnostics/recording-fallback.png"
jq -e '
  .source == "xctest-screen-recording"
  and .attachment == "Attachments/older.mp4"
' "${jpeg_export}/Diagnostics/recording-fallback-source.json" >/dev/null

ambiguous_direct="${test_root}/ambiguous-direct-screenshot"
mkdir -p "${ambiguous_direct}/Attachments" "${ambiguous_direct}/Diagnostics"
cp "${valid}/Diagnostics/failure-screen.png" "${ambiguous_direct}/Attachments/first.png"
cp "${valid}/Diagnostics/failure-screen.png" "${ambiguous_direct}/Attachments/second.png"
jq -n '[{testIdentifier: "PlayerUITests/Failure/testExample()",
  attachments: [
    {exportedFileName: "first.png",
      suggestedHumanReadableName: "xctest-failure-screen_0_11111111-1111-1111-1111-111111111111.png",
      timestamp: 200},
    {exportedFileName: "second.png",
      suggestedHumanReadableName: "xctest-failure-screen_0_22222222-2222-2222-2222-222222222222.png",
      timestamp: 200}
  ]}]' > "${ambiguous_direct}/Attachments/manifest.json"
if swift "${extractor}" "${ambiguous_direct}/Attachments" \
  "${ambiguous_direct}/Diagnostics/failure-screen.png" \
  "${ambiguous_direct}/Diagnostics/failure-screen-source.json"; then
  echo "Ambiguous newest XCTest failure screenshots must fail closed." >&2
  exit 1
fi
[[ ! -e "${ambiguous_direct}/Diagnostics/failure-screen.png" ]]
[[ ! -e "${ambiguous_direct}/Diagnostics/failure-screen-source.json" ]]

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

missing_timestamp="${test_root}/missing-timestamp"
mkdir -p "${missing_timestamp}/Attachments" "${missing_timestamp}/Diagnostics"
cp "${valid}/Attachments/older.mp4" "${missing_timestamp}/Attachments/older.mp4"
jq -n '[{testIdentifier: "PlayerUITests/Failure/testExample()",
  attachments: [{exportedFileName: "older.mp4",
    suggestedHumanReadableName: "Screen Recording fixture.mp4"}]}]' \
  > "${missing_timestamp}/Attachments/manifest.json"
if swift "${extractor}" "${missing_timestamp}/Attachments" \
  "${missing_timestamp}/Diagnostics/failure-screen.png" \
  "${missing_timestamp}/Diagnostics/failure-screen-source.json"; then
  echo "A screen recording without a provenance timestamp must fail closed." >&2
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
