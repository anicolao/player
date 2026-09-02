#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/qualification/qualification-support.sh"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
story_id="001-ios-launch"
canonical_manifest="${repository_root}/tests/e2e/manifest.json"
test_selectors=()
record_story=""
story_was_set=0
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
simulator_id=""
simulator_lease=""
target_application=""
hidden_target_application=""
simulator_lease_root="${PLAYER_SIMULATOR_LEASE_ROOT:-${ios_dir}/DerivedData/SimulatorLeases}"
recording_stage=""
parallel_workers="${PLAYER_E2E_PARALLEL_WORKERS:-2}"
skip_project_generation="${PLAYER_SKIP_PROJECT_GENERATION:-0}"
skip_e2e_build="${PLAYER_SKIP_E2E_BUILD:-0}"
skip_environment_verification="${PLAYER_SKIP_E2E_ENVIRONMENT_VERIFICATION:-0}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

usage() {
  cat >&2 <<'EOF'
usage: run-e2e.sh [<story-id> [<test-selector> ...]]
       run-e2e.sh [--story <story-id>] [--test <test-selector>]... [--record <story-id>]

With no arguments, runs every canonical Story 001 selector. Test selectors use
Xcode's Bundle[/Class[/Method]] form. Recording requires the story's exact ID,
the complete canonical selector set, and is rejected in CI.
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

if [[ ! "${parallel_workers}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid E2E parallel worker count: ${parallel_workers}." >&2
  exit 2
fi

if [[ "${skip_project_generation}" != "0" && "${skip_project_generation}" != "1" ]]; then
  echo "PLAYER_SKIP_PROJECT_GENERATION must be 0 or 1." >&2
  exit 2
fi

if [[ "${skip_e2e_build}" != "0" && "${skip_e2e_build}" != "1" ]]; then
  echo "PLAYER_SKIP_E2E_BUILD must be 0 or 1." >&2
  exit 2
fi

if [[ "${skip_environment_verification}" != "0" && "${skip_environment_verification}" != "1" ]]; then
  echo "PLAYER_SKIP_E2E_ENVIRONMENT_VERIFICATION must be 0 or 1." >&2
  exit 2
fi

if [[ -n "${PLAYER_RECORD_STORY:-}" ]]; then
  echo "PLAYER_RECORD_STORY is no longer accepted; use --record <story-id>." >&2
  exit 2
fi

if [[ ${#test_selectors[@]} -eq 0 ]]; then
  while IFS= read -r selector; do
    test_selectors+=("${selector}")
  done < <(jq -r --arg story "${story_id}" '.[] | select(.story == $story) | .tests[]' \
    "${canonical_manifest}")
  if [[ ${#test_selectors[@]} -eq 0 ]]; then
    echo "The canonical manifest has no selectors for ${story_id}." >&2
    exit 2
  fi
fi

if [[ -n "${record_story}" && "${record_story}" != "${story_id}" ]]; then
  echo "Recording target ${record_story} does not match requested story ${story_id}." >&2
  exit 2
fi

if [[ -n "${record_story}" && ( -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ) ]]; then
  echo "E2E baselines may never be recorded in CI." >&2
  exit 1
fi

if [[ -n "${record_story}" ]]; then
  if ! cmp \
    <(printf '%s\n' "${test_selectors[@]}" | sort) \
    <(jq -r --arg story "${story_id}" '.[] | select(.story == $story) | .tests[]' \
      "${canonical_manifest}" | sort); then
    echo "Recording requires the complete canonical selector set for ${story_id}." >&2
    exit 2
  fi
fi

if [[ "${PLAYER_RECORD_SCREENSHOTS:-0}" == "1" ]]; then
  echo "PLAYER_RECORD_SCREENSHOTS is no longer accepted; use --record <story-id>." >&2
  exit 2
fi

story_output="$("${script_dir}/prepare-e2e-output.sh" \
  "${ios_dir}" "${story_id}" "${PLAYER_E2E_OUTPUT:-}")"
build_data="${PLAYER_E2E_BUILD_DATA:-${story_output}/Build}"
result_bundle="${story_output}/Results/Story.xcresult"
attachments="${story_output}/Attachments"
actual_story="${story_output}/ActualWalkthrough"
baseline_story="${repository_root}/tests/e2e/${story_id}"
simulator_name="Player E2E ${story_id} $$"
failure_screen="${story_output}/Diagnostics/failure-screen.png"
failure_screen_source="${story_output}/Diagnostics/failure-screen-source.json"
reset_hosted_simulator_control_plane="${PLAYER_RESET_HOSTED_SIMULATOR_CONTROL_PLANE:-0}"

if [[ "${reset_hosted_simulator_control_plane}" != "0" \
  && "${reset_hosted_simulator_control_plane}" != "1" ]]; then
  echo "PLAYER_RESET_HOSTED_SIMULATOR_CONTROL_PLANE must be 0 or 1." >&2
  exit 2
fi

if [[ ! -d "${baseline_story}" ]]; then
  echo "Story directory is missing: ${baseline_story}" >&2
  exit 1
fi

mkdir -p "${story_output}/Results" "${story_output}/Logs" "${story_output}/Diagnostics"
echo "E2E output: ${story_output}"
run_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
# `log show --start` does not accept the ISO-8601 `T`/`Z` form retained in
# Run.json. Keep one instant, but render it in the command's accepted syntax so
# launch failures preserve the attempt-wide simulator and host evidence.
log_started_at="${run_started_at/T/ }"
log_started_at="${log_started_at%Z}"
run_commit="$(git -C "${repository_root}" rev-parse HEAD)"
jq -n \
  --arg story "${story_id}" \
  --arg commit "${run_commit}" \
  --arg startedAt "${run_started_at}" \
  --arg status "running" \
  '{story: $story, commit: $commit, startedAt: $startedAt, status: $status}' \
  > "${story_output}/Run.json"
: > "${story_output}/PhaseTimings.tsv"

run_logged_phase() {
  local phase="$1"
  shift
  local phase_start="${SECONDS}"
  local phase_status=0
  set +e
  "$@" 2>&1 | tee "${story_output}/Logs/${phase}.log"
  local pipeline_status=("${PIPESTATUS[@]}")
  set -e
  phase_status="${pipeline_status[0]}"
  printf '%s\t%s\t%s\t%s\n' \
    "${phase}" "${phase_start}" "${SECONDS}" "${phase_status}" \
    >> "${story_output}/PhaseTimings.tsv"
  return "${phase_status}"
}

install_e2e_targets() {
  local simulator="$1"
  local application="$2"
  local application_bundle_identifier="$3"
  local test_runner="$4"
  local test_runner_bundle_identifier="$5"

  xcrun simctl install "${simulator}" "${application}"
  xcrun simctl install "${simulator}" "${test_runner}"
  # Successful FrontBoard launches are the durable receipts that both
  # asynchronous LaunchServices registrations are visible. MobileInstallation
  # can report success while either bundle is still unknown or busy.
  local bundle_identifier
  for bundle_identifier in \
    "${application_bundle_identifier}" "${test_runner_bundle_identifier}"; do
    xcrun simctl launch --terminate-running-process \
      "${simulator}" "${bundle_identifier}"
    xcrun simctl terminate "${simulator}" "${bundle_identifier}" \
      2>/dev/null || true
  done
}

hide_preinstalled_target_from_xcode() {
  local application="$1"
  local hidden_application="$2"

  [[ -d "${application}" && ! -e "${hidden_application}" ]]
  # XCUIApplication(bundleIdentifier:) searches the built-products directory.
  # Leaving Player.app there lets Xcode reinstall it after the harness has
  # already obtained exact FrontBoard receipts, reopening an asynchronous
  # LaunchServices/RunningBoard race. The installed simulator copy is the test
  # target; keep the immutable source bytes beside the products under a name
  # that is not an application bundle until XCTest has finished.
  mv "${application}" "${hidden_application}"
}

restore_hidden_target_application() {
  if [[ -n "${hidden_target_application}" && -d "${hidden_target_application}" ]]; then
    if [[ -e "${target_application}" ]]; then
      echo "Cannot restore the hidden E2E target because its original path was recreated." >&2
      return 1
    fi
    mv "${hidden_target_application}" "${target_application}"
  fi
}

capture_failure_screen() {
  local temporary_screen="${story_output}/Diagnostics/.failure-screen-live.$$.png"
  local temporary_source="${story_output}/Diagnostics/.failure-screen-source.$$.json"
  local dimensions
  local pixel_width
  local pixel_height
  local retained_screenshot_status=0

  if [[ -s "${failure_screen}" && -s "${failure_screen_source}" ]]; then return 0; fi
  rm -f "${failure_screen}" "${failure_screen_source}" \
    "${temporary_screen}" "${temporary_source}"

  if [[ -s "${attachments}/manifest.json" ]]; then
    if swift "${script_dir}/extract-xctest-failure-frame.swift" \
      --failure-screenshot-only \
      "${attachments}" "${failure_screen}" "${failure_screen_source}"; then
      return 0
    else
      retained_screenshot_status="$?"
      if [[ "${retained_screenshot_status}" -eq 2 ]]; then retained_screenshot_status=0; fi
    fi
  fi
  rm -f "${failure_screen}" "${failure_screen_source}"

  if [[ -n "${simulator_id}" ]] \
    && swift "${script_dir}/extract-xctest-failure-frame.swift" \
      --capture-live "${simulator_id}" "${temporary_screen}" >/dev/null 2>&1; then
    dimensions="$(sips -g pixelWidth -g pixelHeight "${temporary_screen}" 2>/dev/null || true)"
    pixel_width="$(awk '/pixelWidth:/ {print $2}' <<<"${dimensions}")"
    pixel_height="$(awk '/pixelHeight:/ {print $2}' <<<"${dimensions}")"
    if [[ "${pixel_width}" =~ ^[1-9][0-9]*$ && "${pixel_height}" =~ ^[1-9][0-9]*$ ]]; then
      jq -n \
        --arg artifact "Diagnostics/failure-screen.png" \
        --arg source "live-simulator" \
        --arg simulatorId "${simulator_id}" \
        --argjson pixelWidth "${pixel_width}" \
        --argjson pixelHeight "${pixel_height}" \
        '{schemaVersion: 1, artifact: $artifact, source: $source,
          simulatorId: $simulatorId, pixelWidth: $pixelWidth, pixelHeight: $pixelHeight}' \
        > "${temporary_source}"
      mv "${temporary_source}" "${failure_screen_source}"
      if mv "${temporary_screen}" "${failure_screen}"; then
        return "${retained_screenshot_status}"
      fi
      rm -f "${failure_screen}" "${failure_screen_source}"
    fi
  fi
  rm -f "${temporary_screen}" "${temporary_source}"

  if [[ -s "${attachments}/manifest.json" ]] \
    && swift "${script_dir}/extract-xctest-failure-frame.swift" \
      --recording-only \
      "${attachments}" "${failure_screen}" "${failure_screen_source}"; then
    return "${retained_screenshot_status}"
  fi
  if [[ "${retained_screenshot_status}" -ne 0 ]]; then return "${retained_screenshot_status}"; fi
  return 1
}

capture_failure_diagnostics() {
  local semantic_evidence
  capture_failure_screen >/dev/null 2>&1 || true
  if [[ -n "${simulator_id}" ]]; then
    xcrun simctl spawn "${simulator_id}" log show \
      --start "${log_started_at}" --style compact --info --debug \
      --predicate 'process == "Player" OR process CONTAINS[c] "PlayerUITests" OR process CONTAINS[c] "ShareExtension"' \
      > "${story_output}/Diagnostics/player.log" 2>&1 || true
    xcrun simctl spawn "${simulator_id}" log show \
      --start "${log_started_at}" --style compact --info --debug \
      --predicate 'process == "SpringBoard" OR process == "backboardd" OR process == "runningboardd" OR process == "launchd_sim" OR subsystem BEGINSWITH "com.apple.FrontBoard" OR subsystem BEGINSWITH "com.apple.CoreSimulator"' \
      > "${story_output}/Diagnostics/simulator-system.log" 2>&1 || true
  else
    printf '%s\n' 'No owned simulator was available for app-process log collection.' \
      > "${story_output}/Diagnostics/player.log"
    printf '%s\n' 'No owned simulator was available for SpringBoard/CoreSimulator log collection.' \
      > "${story_output}/Diagnostics/simulator-system.log"
  fi
  /usr/bin/log show \
    --start "${log_started_at}" --style compact --info --debug \
    --predicate 'process == "CoreSimulatorService" OR process == "CoreSimulatorBridge" OR process == "SimulatorTrampoline"' \
    > "${story_output}/Diagnostics/coresimulator-host.log" 2>&1 || true
  xcrun simctl list devices --json > "${story_output}/Diagnostics/simulators.json" 2>&1 || true
  if [[ ! -s "${story_output}/Diagnostics/player.log" ]]; then
    printf '%s\n' 'The attempt-wide Player log query returned no records.' \
      > "${story_output}/Diagnostics/player.log"
  fi
  if [[ ! -s "${story_output}/Diagnostics/simulator-system.log" ]]; then
    printf '%s\n' 'The attempt-wide simulator system log query returned no records.' \
      > "${story_output}/Diagnostics/simulator-system.log"
  fi
  if [[ ! -s "${story_output}/Diagnostics/coresimulator-host.log" ]]; then
    printf '%s\n' 'The attempt-wide host CoreSimulator log query returned no records.' \
      > "${story_output}/Diagnostics/coresimulator-host.log"
  fi
  if [[ ! -s "${story_output}/Diagnostics/simulators.json" ]]; then
    printf '%s\n' '{"error":"The simulator inventory command returned no output."}' \
      > "${story_output}/Diagnostics/simulators.json"
  fi

  semantic_evidence="${story_output}/Diagnostics/semantic-probes.log"
  if [[ -f "${story_output}/Logs/test.log" ]]; then
    rg -n -i \
      'probe|semantic|readiness|geometry|navigation|active alert|latest=|actual=' \
      "${story_output}/Logs/test.log" > "${semantic_evidence}" || true
  fi
  if [[ ! -s "${semantic_evidence}" ]]; then
    printf '%s\n' \
      'No semantic probe lines were emitted; inspect the retained Story.xcresult diagnostics.' \
      > "${semantic_evidence}"
  fi

  if [[ -d "${result_bundle}" ]]; then
    xcrun xcresulttool export diagnostics \
      --path "${result_bundle}" \
      --output-path "${story_output}/Diagnostics/XCResultDiagnostics" \
      > "${story_output}/Diagnostics/xcresult-diagnostics-export.log" 2>&1 || true
    if [[ ! -s "${story_output}/Diagnostics/xcresult-diagnostics-export.log" ]]; then
      printf '%s\n' 'The xcresult diagnostics export command returned no log output.' \
        > "${story_output}/Diagnostics/xcresult-diagnostics-export.log"
    fi
  fi
}

cleanup() {
  local run_status="$?"
  local manifest_status=0
  trap - EXIT INT TERM
  set +e
  if [[ "${run_status}" -ne 0 ]]; then
    capture_failure_diagnostics
  fi
  if ! restore_hidden_target_application; then
    if [[ "${run_status}" -eq 0 ]]; then run_status=1; fi
  fi
  if [[ -f "${simulator_lease}" && ! -L "${simulator_lease}" ]]; then
    if ! "${script_dir}/simulator-lease.sh" release "${simulator_lease}" "$$"; then
      echo "Could not delete E2E simulator ${simulator_id}." >&2
      if [[ "${run_status}" -eq 0 ]]; then run_status=1; fi
    fi
  fi
  if [[ -n "${recording_stage}" && -d "${recording_stage}" ]]; then
    rm -rf "${recording_stage}"
  fi
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq \
    --arg completedAt "${completed_at}" \
    --arg status "$([[ "${run_status}" -eq 0 ]] && echo passed || echo failed)" \
    --argjson exitCode "${run_status}" \
    '. + {completedAt: $completedAt, status: $status, exitCode: $exitCode}' \
    "${story_output}/Run.json" > "${story_output}/Run.json.next" \
    && mv "${story_output}/Run.json.next" "${story_output}/Run.json"
  qualification_write_evidence_manifest \
    "${story_output}" "${baseline_story}" "${story_id}" || manifest_status=1
  qualification_validate_evidence_manifest \
    "${story_output}" "${baseline_story}" "${story_id}" || manifest_status=1
  if [[ "${manifest_status}" -ne 0 ]]; then
    if [[ "${run_status}" -eq 0 ]]; then
      run_status=1
      jq \
        --arg completedAt "${completed_at}" \
        --arg status failed \
        --argjson exitCode "${run_status}" \
        '. + {completedAt: $completedAt, status: $status, exitCode: $exitCode}' \
        "${story_output}/Run.json" > "${story_output}/Run.json.next" \
        && mv "${story_output}/Run.json.next" "${story_output}/Run.json"
      qualification_write_evidence_manifest \
        "${story_output}" "${baseline_story}" "${story_id}" >/dev/null 2>&1 || true
      qualification_validate_evidence_manifest \
        "${story_output}" "${baseline_story}" "${story_id}" >/dev/null 2>&1 || true
    fi
    echo "E2E evidence manifest is incomplete or corrupt: ${story_output}" >&2
  fi
  exit "${run_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "${skip_environment_verification}" == "1" ]]; then
  printf 'environment-reuse\t%s\t%s\t0\n' "${SECONDS}" "${SECONDS}" \
    >> "${story_output}/PhaseTimings.tsv"
else
  if ! run_logged_phase environment "${script_dir}/verify-e2e-environment.sh"; then
    exit 1
  fi
fi

simulator_phase_start="${SECONDS}"
if [[ "${reset_hosted_simulator_control_plane}" == "1" ]]; then
  if ! run_logged_phase simulator-control-plane-reset \
    "${script_dir}/reset-hosted-simulator-control-plane.sh"; then
    echo "Could not restart and observe the hosted CoreSimulator control plane." >&2
    exit 1
  fi
fi
simulator_lease="${simulator_lease_root}/story-${story_id}-$$.json"
simulator_id="$("${script_dir}/simulator-lease.sh" acquire \
  "${simulator_lease}" "${simulator_name}" "${device_type}" "${runtime}" "$$")"
xcrun simctl boot "${simulator_id}"
xcrun simctl bootstatus "${simulator_id}" -b
xcrun simctl ui "${simulator_id}" appearance light
expected_content_size="large"
expected_increase_contrast="disabled"
if [[ "${story_id}" == "009-accessible-core-journeys" ]]; then
  expected_content_size="accessibility-extra-extra-extra-large"
  expected_increase_contrast="enabled"
fi
xcrun simctl ui "${simulator_id}" content_size "${expected_content_size}"
xcrun simctl ui "${simulator_id}" increase_contrast "${expected_increase_contrast}"
# A newly created iOS 26 simulator reaches bootstatus while its one-time
# widget, Spotlight, accessibility-asset, and push-daemon work can still
# monopolize RunningBoard and SpringBoard. Neither scheduler is part of an E2E
# product contract: Bookshelf has no push-notification path, and the receiver
# uses its real local HTTP server. Disable both while this first boot is still
# authoritative, then let the simulator's real shutdown boundary terminate
# them. The disabled-state receipt proves that the next clean boot cannot race
# a kill/bootout operation by relaunching either service.
chronod_service="user/501/com.apple.chronod"
apsd_service="user/501/com.apple.apsd"
isolated_simulator_services=("${chronod_service}" "${apsd_service}")
for isolated_service in "${isolated_simulator_services[@]}"; do
  xcrun simctl spawn "${simulator_id}" launchctl disable "${isolated_service}"
done
disabled_services="$(xcrun simctl spawn "${simulator_id}" launchctl print-disabled user/501)"
rg -F '"com.apple.chronod" => disabled' <<<"${disabled_services}" >/dev/null
rg -F '"com.apple.apsd" => disabled' <<<"${disabled_services}" >/dev/null
# Complete the first-boot/configuration epoch, then acquire a distinct
# clean-boot receipt before installing either test target. This is a lifecycle
# boundary, not a launch retry or a time-based settling delay.
xcrun simctl shutdown "${simulator_id}"
xcrun simctl boot "${simulator_id}"
xcrun simctl bootstatus "${simulator_id}" -b
# The first-boot writes deliberately front-load Dynamic Type and accessibility
# service initialization before the clean lifecycle boundary. Reassert the
# exact values on the authoritative second boot so live UIKit traits receive
# their notifications in this boot epoch instead of relying on a persisted
# simctl-domain query alone.
xcrun simctl ui "${simulator_id}" appearance light
xcrun simctl ui "${simulator_id}" content_size "${expected_content_size}"
xcrun simctl ui "${simulator_id}" increase_contrast "${expected_increase_contrast}"
[[ "$(xcrun simctl ui "${simulator_id}" appearance)" == "light" ]]
[[ "$(xcrun simctl ui "${simulator_id}" content_size)" == "${expected_content_size}" ]]
[[ "$(xcrun simctl ui "${simulator_id}" increase_contrast)" == "${expected_increase_contrast}" ]]
# The clean boot must retain both halves of each causal receipt: both unrelated
# schedulers are disabled and neither job was loaded. This prevents post-boot
# widget enumeration and runaway APNS reconnect work without replacing the real
# URL, local-network, playback, or application-lifecycle paths under test.
disabled_services="$(xcrun simctl spawn "${simulator_id}" launchctl print-disabled user/501)"
rg -F '"com.apple.chronod" => disabled' <<<"${disabled_services}" >/dev/null
rg -F '"com.apple.apsd" => disabled' <<<"${disabled_services}" >/dev/null
for isolated_service in "${isolated_simulator_services[@]}"; do
  if xcrun simctl spawn "${simulator_id}" launchctl print "${isolated_service}" \
    >/dev/null 2>&1; then
    echo "Simulator service ${isolated_service} loaded despite its clean-boot disable receipt." >&2
    exit 1
  fi
done
xcrun simctl status_bar "${simulator_id}" override \
  --time '9:41' \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4
printf 'simulator\t%s\t%s\t0\n' "${simulator_phase_start}" "${SECONDS}" \
  >> "${story_output}/PhaseTimings.tsv"

if [[ "${skip_project_generation}" == "1" ]]; then
  if [[ ! -f "${ios_dir}/Player.xcodeproj/project.pbxproj" ]]; then
    echo "Generated Xcode project is unavailable while generation is disabled." >&2
    exit 1
  fi
else
  if ! run_logged_phase project-generation "${script_dir}/generate-project.sh"; then
    exit 1
  fi
fi

if [[ "${skip_e2e_build}" == "1" ]]; then
  if ! run_logged_phase build-provenance \
    "${script_dir}/e2e-build-provenance.sh" verify \
    "${build_data}" "${device_type}" "${runtime}"; then
    echo "The prebuilt E2E bundle cannot be safely reused; rebuild it." >&2
    exit 1
  fi
  printf 'build-reuse\t%s\t%s\t0\n' "${SECONDS}" "${SECONDS}" \
    >> "${story_output}/PhaseTimings.tsv"
else
  if ! run_logged_phase build xcodebuild build-for-testing \
    -project "${ios_dir}/Player.xcodeproj" \
    -scheme Player \
    -configuration E2E \
    -destination "platform=iOS Simulator,arch=arm64,id=${simulator_id}" \
    -derivedDataPath "${build_data}" \
    CODE_SIGNING_ALLOWED=NO; then
    echo "UI-test build failed; retained diagnostics in ${story_output}" >&2
    exit 1
  fi
  if ! run_logged_phase build-provenance \
    "${script_dir}/e2e-build-provenance.sh" write \
    "${build_data}" "${device_type}" "${runtime}"; then
    echo "Could not bind the E2E build to its source and toolchain." >&2
    exit 1
  fi
fi

target_application="${build_data}/Build/Products/E2E-iphonesimulator/Player.app"
hidden_target_application="${build_data}/Build/Products/E2E-iphonesimulator/.Player-e2e-preinstalled-$$"
target_bundle_identifier="com.spnss.player"
test_runner_application="${build_data}/Build/Products/E2E-iphonesimulator/PlayerUITests-Runner.app"
test_runner_bundle_identifier="com.spnss.player.uitests.xctrunner"
if [[ ! -d "${target_application}" ]]; then
  echo "The exact E2E target application is unavailable: ${target_application}" >&2
  exit 1
fi
if [[ ! -d "${test_runner_application}" ]]; then
  echo "The exact E2E test runner is unavailable: ${test_runner_application}" >&2
  exit 1
fi
if ! run_logged_phase target-install \
  install_e2e_targets "${simulator_id}" "${target_application}" \
    "${target_bundle_identifier}" "${test_runner_application}" \
    "${test_runner_bundle_identifier}"; then
  echo "Could not register the exact E2E application and test runner before XCTest launch." >&2
  exit 1
fi
if ! run_logged_phase target-source-hiding \
  hide_preinstalled_target_from_xcode \
    "${target_application}" "${hidden_target_application}"; then
  echo "Could not isolate the receipted E2E target from Xcode deployment." >&2
  exit 1
fi

only_testing_arguments=()
test_classes=()
for test_selector in "${test_selectors[@]}"; do
  only_testing_arguments+=("-only-testing:${test_selector}")
  selector_without_bundle="${test_selector#*/}"
  test_classes+=("${selector_without_bundle%%/*}")
done

unique_test_class_count="$(printf '%s\n' "${test_classes[@]}" | sort -u | wc -l | tr -d ' ')"
parallel_testing="NO"
if [[ "${parallel_workers}" -gt 1 && "${unique_test_class_count}" -gt 1 ]]; then
  parallel_testing="YES"
fi
echo "E2E execution: ${unique_test_class_count} test class(es), parallel testing ${parallel_testing}."

test_status=0
run_logged_phase test xcodebuild test-without-building \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration E2E \
  -destination "platform=iOS Simulator,arch=arm64,id=${simulator_id}" \
  -derivedDataPath "${build_data}" \
  -parallel-testing-enabled "${parallel_testing}" \
  -maximum-parallel-testing-workers "${parallel_workers}" \
  "${only_testing_arguments[@]}" \
  -resultBundlePath "${result_bundle}" \
  CODE_SIGNING_ALLOWED=NO || test_status=$?
if rg -Fq 'Installed app at path:' "${story_output}/Logs/test.log"; then
  echo "Xcode reinstalled an application during test-without-building." \
    | tee -a "${story_output}/Logs/test.log" >&2
  test_status=1
fi

export_status=0
if [[ -d "${result_bundle}" ]]; then
  mkdir -p "${attachments}"
  run_logged_phase attachment-export xcrun xcresulttool export attachments \
    --path "${result_bundle}" \
    --output-path "${attachments}" || export_status=$?
else
  echo "Result bundle was not produced: ${result_bundle}" >&2
  export_status=1
fi

materialize_status=0
if [[ ${export_status} -eq 0 ]]; then
  run_logged_phase walkthrough-materialization "${script_dir}/export-walkthrough.sh" \
    "${attachments}" \
    "${actual_story}" || materialize_status=$?
fi

if [[ ${test_status} -ne 0 ]]; then
  failure_comparison_status=0
  failure_screen_status=0
  failure_screen_json=null
  result_bundle_available=false
  if [[ -d "${result_bundle}" ]]; then result_bundle_available=true; fi
  run_logged_phase failure-screen-capture capture_failure_screen || failure_screen_status=$?
  if [[ -s "${failure_screen_source}" ]] \
    && jq -e 'type == "object"' "${failure_screen_source}" >/dev/null; then
    failure_screen_json="$(<"${failure_screen_source}")"
  fi
  mkdir -p "${actual_story}/screenshots/ios"
  run_logged_phase failure-screenshot-evidence \
    swift "${script_dir}/compare-walkthrough.swift" \
    "${baseline_story}/screenshots/ios" \
    "${actual_story}/screenshots/ios" \
    "${story_output}/Diagnostics/ScreenshotComparison" \
    --retain-all-evidence || failure_comparison_status=$?
  jq -n \
    --argjson testExitCode "${test_status}" \
    --argjson attachmentExportExitCode "${export_status}" \
    --argjson materializationExitCode "${materialize_status}" \
    --argjson screenshotEvidenceExitCode "${failure_comparison_status}" \
    --argjson failureScreenExitCode "${failure_screen_status}" \
    --argjson failureScreen "${failure_screen_json}" \
    --argjson resultBundleAvailable "${result_bundle_available}" \
    --arg resultBundle "Results/Story.xcresult" \
    '{testExitCode: $testExitCode,
      attachmentExportExitCode: $attachmentExportExitCode,
      materializationExitCode: $materializationExitCode,
      screenshotEvidenceExitCode: $screenshotEvidenceExitCode,
      failureScreenExitCode: $failureScreenExitCode,
      failureScreen: $failureScreen,
      resultBundleAvailable: $resultBundleAvailable,
      resultBundle: $resultBundle}' \
    > "${story_output}/Diagnostics/FailureEvidence.json"
  echo "UI tests failed; retained diagnostics in ${story_output}" >&2
  exit "${test_status}"
fi

if [[ ${export_status} -ne 0 || ${materialize_status} -ne 0 ]]; then
  echo "Could not materialize the walkthrough; retained diagnostics in ${story_output}" >&2
  exit 1
fi

if [[ -n "${record_story}" ]]; then
  if [[ -n "$(git -C "${repository_root}" status --porcelain -- "${baseline_story}")" ]]; then
    echo "Refusing to replace a baseline that already has uncommitted changes: ${story_id}" >&2
    exit 1
  fi
  baseline_parent="$(dirname "${baseline_story}")"
  recording_stage="$(mktemp -d "${baseline_parent}/.${story_id}.recording.XXXXXX")"
  cp -R "${baseline_story}/." "${recording_stage}/"
  find "${recording_stage}/screenshots/ios" -type f -name '*.png' -depth -delete
  cp "${actual_story}/screenshots/ios/"*.png "${recording_stage}/screenshots/ios/"
  cp "${actual_story}/README.md" "${recording_stage}/README.md"
  cp "${baseline_story}/story.json" "${recording_stage}/story.json"
  run_logged_phase screenshot-comparison swift "${script_dir}/compare-walkthrough.swift" \
    "${recording_stage}/screenshots/ios" \
    "${actual_story}/screenshots/ios" \
    "${story_output}/Diagnostics/ScreenshotComparison"

  previous_baseline="${baseline_parent}/.${story_id}.previous.$$"
  mv "${baseline_story}" "${previous_baseline}"
  if ! mv "${recording_stage}" "${baseline_story}"; then
    mv "${previous_baseline}" "${baseline_story}"
    echo "Could not atomically replace the reviewed baseline for ${story_id}." >&2
    exit 1
  fi
  recording_stage=""
  rm -rf "${previous_baseline}"
  echo "Recorded reviewed baseline in ${baseline_story}"
else
  comparison_status=0
  run_logged_phase screenshot-comparison swift "${script_dir}/compare-walkthrough.swift" \
    "${baseline_story}/screenshots/ios" \
    "${actual_story}/screenshots/ios" \
    "${story_output}/Diagnostics/ScreenshotComparison" || comparison_status=$?
  run_logged_phase readme-comparison bash "${script_dir}/compare-walkthrough-readme.sh" \
    "${baseline_story}/README.md" \
    "${actual_story}/README.md" \
    "${story_output}/Diagnostics/READMEComparison" || comparison_status=$?
  if [[ ${comparison_status} -ne 0 ]]; then
    exit "${comparison_status}"
  fi
fi
