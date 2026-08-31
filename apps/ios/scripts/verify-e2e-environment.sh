#!/usr/bin/env bash
set -euo pipefail

expected_xcode_version="Xcode 26.6"
expected_xcode_build="Build version 17F113"
expected_architecture="arm64"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

for command in jq rg swift xcodebuild xcrun; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required E2E command is unavailable: ${command}" >&2
    exit 1
  fi
done

if [[ "$(uname -m)" != "${expected_architecture}" ]]; then
  echo "E2E architecture mismatch: expected ${expected_architecture}, received $(uname -m)" >&2
  exit 1
fi

xcode_version="$(xcodebuild -version)"
if [[ "${xcode_version}" != "${expected_xcode_version}"$'\n'"${expected_xcode_build}" ]]; then
  echo "E2E Xcode mismatch. Expected:" >&2
  printf '%s\n%s\n' "${expected_xcode_version}" "${expected_xcode_build}" >&2
  echo "Received:" >&2
  printf '%s\n' "${xcode_version}" >&2
  exit 1
fi

if ! xcrun simctl list runtimes --json \
  | jq -e --arg identifier "${runtime}" --arg architecture "${expected_architecture}" '
      any(
        .runtimes[];
        .identifier == $identifier
          and .isAvailable == true
          and (.supportedArchitectures | index($architecture) != null)
      )
    ' >/dev/null
then
  echo "Required simulator runtime is unavailable: ${runtime}" >&2
  exit 1
fi

if ! xcrun simctl list devicetypes --json \
  | jq -e --arg identifier "${device_type}" '
      any(.devicetypes[]; .identifier == $identifier)
    ' >/dev/null
then
  echo "Required simulator device type is unavailable: ${device_type}" >&2
  exit 1
fi

printf 'Pinned E2E environment verified: Xcode 26.6 (17F113), iOS 26.5, iPhone 17, arm64.\n'
