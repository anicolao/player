#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
derived_data="${ios_dir}/DerivedData"
result_bundle="${derived_data}/Launch.xcresult"
attachments="${derived_data}/LaunchAttachments"
actual_story="${derived_data}/ActualWalkthrough"
baseline_story="${repository_root}/tests/e2e/001-ios-launch"
simulator_name="Player E2E"
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
simulator_id=""

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cleanup() {
  if [[ -n "${simulator_id}" ]]; then
    xcrun simctl shutdown "${simulator_id}" >/dev/null 2>&1 || true
    xcrun simctl delete "${simulator_id}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

existing_ids="$(
  xcrun simctl list devices --json \
    | jq -r --arg name "${simulator_name}" '.devices[][] | select(.name == $name) | .udid'
)"
while IFS= read -r existing_id; do
  if [[ -n "${existing_id}" ]]; then
    xcrun simctl delete "${existing_id}"
  fi
done <<< "${existing_ids}"

simulator_id="$(xcrun simctl create "${simulator_name}" "${device_type}" "${runtime}")"
xcrun simctl boot "${simulator_id}"
xcrun simctl bootstatus "${simulator_id}" -b
xcrun simctl ui "${simulator_id}" appearance light
xcrun simctl status_bar "${simulator_id}" override \
  --time '9:41' \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4

"${script_dir}/generate-project.sh"

rm -rf "${derived_data}"
mkdir -p "${derived_data}"

xcodebuild build-for-testing \
  -quiet \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -derivedDataPath "${derived_data}" \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test-without-building \
  -quiet \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -derivedDataPath "${derived_data}" \
  -only-testing:PlayerUITests/LaunchUITests/testLaunchesIntoEmptyLibrary \
  -resultBundlePath "${result_bundle}" \
  CODE_SIGNING_ALLOWED=NO

mkdir -p "${attachments}"
xcrun xcresulttool export attachments \
  --path "${result_bundle}" \
  --output-path "${attachments}"

"${script_dir}/export-walkthrough.sh" "${attachments}" "${actual_story}"

if [[ "${PLAYER_RECORD_SCREENSHOTS:-0}" == "1" ]]; then
  rm -rf "${baseline_story}/screenshots/ios"
  mkdir -p "${baseline_story}/screenshots/ios"
  cp \
    "${actual_story}/screenshots/ios/000-empty-library.png" \
    "${baseline_story}/screenshots/ios/000-empty-library.png"
  cp "${actual_story}/README.md" "${baseline_story}/README.md"
  echo "Recorded reviewed baseline in ${baseline_story}"
else
  swift "${script_dir}/compare-walkthrough.swift" \
    "${baseline_story}/screenshots/ios" \
    "${actual_story}/screenshots/ios"
fi
