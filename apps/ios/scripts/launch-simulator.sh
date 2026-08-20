#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
simulator_name="Player Development"
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
bundle_identifier="com.spnss.player"
derived_data="${ios_dir}/DerivedData/Development"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

"${script_dir}/verify-e2e-environment.sh"
"${script_dir}/generate-project.sh"

simulator_id="$({
  xcrun simctl list devices --json \
    | jq -r --arg runtime "${runtime}" --arg name "${simulator_name}" '
        (.devices[$runtime] // [])
        | map(select(.name == $name and .isAvailable == true))
        | first
        | .udid // empty
      '
})"

if [[ -z "${simulator_id}" ]]; then
  echo "Creating ${simulator_name} simulator..."
  simulator_id="$(xcrun simctl create "${simulator_name}" "${device_type}" "${runtime}")"
fi

simulator_state="$({
  xcrun simctl list devices --json \
    | jq -r --arg runtime "${runtime}" --arg id "${simulator_id}" '
        (.devices[$runtime] // [])
        | map(select(.udid == $id))
        | first
        | .state // empty
      '
})"

if [[ "${simulator_state}" != "Booted" ]]; then
  echo "Booting ${simulator_name}..."
  xcrun simctl boot "${simulator_id}"
fi

open -a Simulator --args -CurrentDeviceUDID "${simulator_id}"
xcrun simctl bootstatus "${simulator_id}" -b

echo "Building Player..."
xcodebuild build \
  -quiet \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -derivedDataPath "${derived_data}" \
  CODE_SIGNING_ALLOWED=NO

app_path="${derived_data}/Build/Products/Debug-iphonesimulator/Player.app"
if [[ ! -d "${app_path}" ]]; then
  echo "Built application is missing: ${app_path}" >&2
  exit 1
fi

xcrun simctl terminate "${simulator_id}" "${bundle_identifier}" >/dev/null 2>&1 || true
xcrun simctl install "${simulator_id}" "${app_path}"
xcrun simctl launch "${simulator_id}" "${bundle_identifier}"

echo "Player is running in ${simulator_name}. Simulator data will be reused next time."
