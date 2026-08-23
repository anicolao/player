#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
story_id="001-ios-launch"
default_test_selector="PlayerUITests/LaunchUITests/testLaunchesIntoEmptyLibrary"
test_selectors=()
record_story="${PLAYER_RECORD_STORY:-}"
story_was_set=0
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
simulator_id=""

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

usage() {
  cat >&2 <<'EOF'
usage: run-e2e.sh [<story-id> [<test-selector> ...]]
       run-e2e.sh [--story <story-id>] [--test <test-selector>]... [--record <story-id>]

With no arguments, runs Story 001 and its launch UI test. Test selectors use
Xcode's Bundle[/Class[/Method]] form. Recording requires the story's exact ID
and is rejected in CI.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      story_id="$2"
      story_was_set=1
      shift 2
      ;;
    --test)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      test_selectors+=("$2")
      shift 2
      ;;
    --record)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      record_story="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ ${story_was_set} -eq 0 ]]; then
        story_id="$1"
        story_was_set=1
      else
        test_selectors+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ ! "${story_id}" =~ ^[0-9]{3}-[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Invalid story identifier: ${story_id}" >&2
  exit 2
fi

if [[ ${#test_selectors[@]} -eq 0 ]]; then
  if [[ "${story_id}" == "001-ios-launch" ]]; then
    test_selectors+=("${default_test_selector}")
  else
    echo "At least one test selector is required for ${story_id}." >&2
    exit 2
  fi
fi

if [[ -n "${record_story}" && "${record_story}" != "${story_id}" ]]; then
  echo "Recording target ${record_story} does not match requested story ${story_id}." >&2
  exit 2
fi

if [[ -n "${record_story}" && ( "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ) ]]; then
  echo "E2E baselines may never be recorded in CI." >&2
  exit 1
fi

if [[ "${PLAYER_RECORD_SCREENSHOTS:-0}" == "1" ]]; then
  echo "PLAYER_RECORD_SCREENSHOTS is no longer accepted; use --record <story-id>." >&2
  exit 2
fi

derived_data_root="${ios_dir}/DerivedData/E2E"
story_output="${derived_data_root}/${story_id}"
build_data="${story_output}/Build"
result_bundle="${story_output}/Results/Story.xcresult"
attachments="${story_output}/Attachments"
actual_story="${story_output}/ActualWalkthrough"
baseline_story="${repository_root}/tests/e2e/${story_id}"
simulator_name="Player E2E ${story_id}"

if [[ ! -d "${baseline_story}" ]]; then
  echo "Story directory is missing: ${baseline_story}" >&2
  exit 1
fi

"${script_dir}/verify-e2e-environment.sh"

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

rm -rf "${story_output}"
mkdir -p "${story_output}/Results"

xcodebuild build-for-testing \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -derivedDataPath "${build_data}" \
  CODE_SIGNING_ALLOWED=NO

only_testing_arguments=()
for test_selector in "${test_selectors[@]}"; do
  only_testing_arguments+=("-only-testing:${test_selector}")
done

test_status=0
xcodebuild test-without-building \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration E2E \
  -destination "platform=iOS Simulator,id=${simulator_id}" \
  -derivedDataPath "${build_data}" \
  "${only_testing_arguments[@]}" \
  -resultBundlePath "${result_bundle}" \
  CODE_SIGNING_ALLOWED=NO || test_status=$?

export_status=0
if [[ -d "${result_bundle}" ]]; then
  mkdir -p "${attachments}"
  xcrun xcresulttool export attachments \
    --path "${result_bundle}" \
    --output-path "${attachments}" || export_status=$?
else
  echo "Result bundle was not produced: ${result_bundle}" >&2
  export_status=1
fi

materialize_status=0
if [[ ${export_status} -eq 0 ]]; then
  "${script_dir}/export-walkthrough.sh" \
    "${attachments}" \
    "${actual_story}" || materialize_status=$?
fi

if [[ ${test_status} -ne 0 ]]; then
  echo "UI tests failed; retained diagnostics in ${story_output}" >&2
  exit "${test_status}"
fi

if [[ ${export_status} -ne 0 || ${materialize_status} -ne 0 ]]; then
  echo "Could not materialize the walkthrough; retained diagnostics in ${story_output}" >&2
  exit 1
fi

if [[ -n "${record_story}" ]]; then
  rm -rf "${baseline_story}/screenshots/ios"
  mkdir -p "${baseline_story}/screenshots/ios"
  cp "${actual_story}/screenshots/ios/"*.png "${baseline_story}/screenshots/ios/"
  cp "${actual_story}/README.md" "${baseline_story}/README.md"
  echo "Recorded reviewed baseline in ${baseline_story}"
else
  swift "${script_dir}/compare-walkthrough.swift" \
    "${baseline_story}/screenshots/ios" \
    "${actual_story}/screenshots/ios"
fi
