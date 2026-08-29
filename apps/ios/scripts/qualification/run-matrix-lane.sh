#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/qualification-support.sh"
base_ios_dir="$(cd "${script_dir}/../.." && pwd)"
repository_root="$(cd "${base_ios_dir}/../.." && pwd)"
manifest="${repository_root}/tests/e2e/manifest.json"
lane=""
expected_sha=""
matrix_count=5
output_root="${base_ios_dir}/DerivedData/R0Qualification/Matrices"
run_core=0
stories=()
active_worktree=""
core_simulator_id=""
core_simulator_lease=""
simulator_lease_root="${base_ios_dir}/DerivedData/SimulatorLeases"

usage() {
  echo "usage: run-matrix-lane.sh --lane <lane-1..5> --sha <commit> [--matrices 5] [--core] --story <id>..." >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane) lane="$2"; shift 2 ;;
    --sha) expected_sha="$2"; shift 2 ;;
    --matrices) matrix_count="$2"; shift 2 ;;
    --output-root) output_root="$2"; shift 2 ;;
    --core) run_core=1; shift ;;
    --story) stories+=("$2"); shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "${lane}" =~ ^lane-[1-5]$ ]] || { usage; exit 2; }
[[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "A full lowercase commit SHA is required." >&2; exit 2; }
[[ "${matrix_count}" =~ ^[1-9][0-9]*$ ]] || { echo "Matrix count must be positive." >&2; exit 2; }
[[ ${#stories[@]} -gt 0 ]] || { echo "At least one --story is required." >&2; exit 2; }

assert_source() {
  local root="$1"
  [[ "$(git -C "${root}" rev-parse HEAD)" == "${expected_sha}" ]] \
    && git -C "${root}" diff --quiet \
    && git -C "${root}" diff --cached --quiet
}

has_build() {
  find "$1/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit \
    2>/dev/null | grep -q .
}

capture_build_manifest() {
  (cd "$1" && find Build/Products -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) > "$2"
}

cleanup() {
  local status="$?"
  trap - EXIT INT TERM
  set +e
  if [[ -f "${core_simulator_lease}" && ! -L "${core_simulator_lease}" ]]; then
    if ! "${base_ios_dir}/scripts/simulator-lease.sh" release \
      "${core_simulator_lease}" "$$" >/dev/null 2>&1; then
      status=1
    fi
  fi
  if [[ -n "${active_worktree}" ]]; then
    git -C "${repository_root}" worktree remove --force "${active_worktree}" >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_core_gate() {
  local worktree="$1" matrix_root="$2" matrix_index="$3"
  local worktree_ios="${worktree}/apps/ios"
  local fixture_status=0 fixture_log_status=0 failed_fixture=""
  local test_ran=false test_status=0 test_log_status=0 cleanup_status=0
  local result_summary_status=0
  local fixture_start core_start fixture_duration=0 core_duration=0
  local core_signature=none
  mkdir -p "${matrix_root}/Core/Logs" "${matrix_root}/Core/Results"
  core_simulator_lease="${simulator_lease_root}/core-matrix-${lane}-${matrix_index}-$$.json"
  core_simulator_id="$("${base_ios_dir}/scripts/simulator-lease.sh" acquire \
    "${core_simulator_lease}" "Player R0 Core ${lane} ${matrix_index} $$" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17 \
    com.apple.CoreSimulator.SimRuntime.iOS-26-5 "$$")"
  xcrun simctl boot "${core_simulator_id}"
  xcrun simctl bootstatus "${core_simulator_id}" -b
  export PLAYER_CORE_SIMULATOR_ID="${core_simulator_id}"
  fixture_start="${SECONDS}"
  set +e
  qualification_run_logged_commands "${matrix_root}/Core/Logs/fixtures.log" \
    "${worktree_ios}/scripts/prepare-core-web-runtime.sh" \
    "${worktree_ios}/scripts/fixtures/verify-generated-fixtures.sh" \
    "${worktree_ios}/scripts/fixtures/verify-messy-multifile-fixture.sh" \
    "${worktree_ios}/scripts/fixtures/verify-zip-fixtures.sh" \
    "${worktree_ios}/scripts/fixtures/verify-import-channel-fixtures.sh" \
    "${worktree_ios}/scripts/fixtures/verify-metadata-repair-fixture.sh" \
    "${worktree_ios}/scripts/fixtures/verify-populated-library-fixture.sh"
  fixture_status="${QUALIFICATION_COMMAND_EXIT_CODE:-0}"
  fixture_log_status="${QUALIFICATION_LOG_EXIT_CODE:-0}"
  failed_fixture="${QUALIFICATION_FAILED_COMMAND:-}"
  set -e
  fixture_duration=$((SECONDS - fixture_start))

  if [[ "${fixture_status}" -eq 0 && "${fixture_log_status}" -eq 0 ]]; then
    core_start="${SECONDS}"
    local -a core_pipeline_statuses
    test_ran=true
    set +e
    xcodebuild -quiet \
      -project "${worktree_ios}/Player.xcodeproj" -scheme Player -configuration E2E \
      -destination "platform=iOS Simulator,id=${core_simulator_id}" \
      -derivedDataPath "${shared_build}" -parallel-testing-enabled NO \
      -only-testing:PlayerTests \
      -resultBundlePath "${matrix_root}/Core/Results/Core.xcresult" \
      test-without-building CODE_SIGNING_ALLOWED=NO \
      2>&1 | tee "${matrix_root}/Core/Logs/tests.log"
    core_pipeline_statuses=("${PIPESTATUS[@]}")
    set -e
    test_status="${core_pipeline_statuses[0]}"
    test_log_status="${core_pipeline_statuses[1]}"
    set +e
    xcrun xcresulttool get test-results summary \
      --path "${matrix_root}/Core/Results/Core.xcresult" --format json \
      > "${matrix_root}/Core/Results/CoreTestSummary.json"
    result_summary_status="$?"
    set -e
    if [[ "${result_summary_status}" -ne 0 ]]; then
      rm -f "${matrix_root}/Core/Results/CoreTestSummary.json"
    fi
    core_duration=$((SECONDS - core_start))
    if "${base_ios_dir}/scripts/simulator-lease.sh" release \
      "${core_simulator_lease}" "$$"; then
      core_simulator_id=""
      core_simulator_lease=""
      unset PLAYER_CORE_SIMULATOR_ID
    else
      cleanup_status="$?"
    fi
  fi
  if [[ "${fixture_status}" -ne 0 || "${fixture_log_status}" -ne 0 \
    || "${test_ran}" != true || "${test_status}" -ne 0 \
    || "${test_log_status}" -ne 0 || "${result_summary_status}" -ne 0 \
    || "${cleanup_status}" -ne 0 ]]; then
    core_signature="$(qualification_core_failure_signature \
      "${matrix_root}/Core" "${fixture_status}" "${test_status}" \
      "${failed_fixture}" "${fixture_log_status}" "${test_log_status}" \
      "${cleanup_status}" "${result_summary_status}")"
  fi
  local test_exit_json=null
  if [[ "${test_ran}" == true ]]; then test_exit_json="${test_status}"; fi
  jq -n --argjson required true --argjson fixtureExit "${fixture_status}" \
    --argjson fixtureLogExit "${fixture_log_status}" \
    --arg failedFixture "${failed_fixture}" \
    --argjson testRan "${test_ran}" --argjson testExit "${test_exit_json}" \
    --argjson testLogExit "${test_log_status}" \
    --argjson resultSummaryExit "${result_summary_status}" \
    --argjson cleanupExit "${cleanup_status}" \
    --argjson fixtureDurationSeconds "${fixture_duration}" \
    --argjson testDurationSeconds "${core_duration}" \
    --arg artifact "Matrices/$(basename "${matrix_root}")/Core" \
    --arg signature "${core_signature}" \
    --arg status "$([[ "${fixture_status}" -eq 0 && "${fixture_log_status}" -eq 0 \
      && "${test_ran}" == true && "${test_status}" -eq 0 \
      && "${test_log_status}" -eq 0 && "${result_summary_status}" -eq 0 \
      && "${cleanup_status}" -eq 0 ]] \
      && echo passed || echo failed)" \
    '{required: $required, fixtureExitCode: $fixtureExit,
      fixtureLogExitCode: $fixtureLogExit,
      failedFixture: (if $failedFixture == "" then null else $failedFixture end),
      testRan: $testRan, testExitCode: $testExit,
      testLogExitCode: $testLogExit,
      resultSummaryExitCode: $resultSummaryExit,
      cleanupExitCode: $cleanupExit,
      fixtureDurationSeconds: $fixtureDurationSeconds,
      testDurationSeconds: $testDurationSeconds, status: $status,
      signature: $signature, artifact: $artifact}' > "${matrix_root}/Core/CoreSummary.json"
  qualification_write_integrity_manifest "${matrix_root}/Core"
  [[ "${fixture_status}" -eq 0 && "${fixture_log_status}" -eq 0 \
    && "${test_ran}" == true && "${test_status}" -eq 0 \
    && "${test_log_status}" -eq 0 && "${result_summary_status}" -eq 0 \
    && "${cleanup_status}" -eq 0 ]]
}

requested="$(printf '%s\n' "${stories[@]}" | sort)"
[[ "$(printf '%s\n' "${stories[@]}" | sort -u)" == "${requested}" ]] \
  || { echo "A story may appear only once in a lane." >&2; exit 2; }
while IFS= read -r story; do
  jq -e --arg story "${story}" 'any(.[]; .story == $story)' "${manifest}" >/dev/null \
    || { echo "Unknown canonical story: ${story}" >&2; exit 2; }
done <<< "${requested}"
assert_source "${repository_root}" || { echo "Qualification source is not exact and clean." >&2; exit 2; }

lane_root="${output_root}/${lane}"
shared_build=""
rm -rf "${lane_root}"
mkdir -p "${lane_root}/Matrices"
overall_status=0
infrastructure_invalid=0
build_unchanged=true

for ((matrix_index = 1; matrix_index <= matrix_count; matrix_index += 1)); do
  matrix_wall_start="${SECONDS}"
  assert_source "${repository_root}" || { infrastructure_invalid=1; overall_status=1; break; }
  matrix_name="$(printf 'matrix-%02d' "${matrix_index}")"
  matrix_root="${lane_root}/Matrices/${matrix_name}"
  shared_build="${lane_root}/Build/${matrix_name}"
  build_manifest_ready=0
  mkdir -p "${matrix_root}/Stories"
  : > "${matrix_root}/stories.jsonl"
  active_worktree="$(mktemp -d "${RUNNER_TEMP:-/tmp}/player-r0-${lane}-${matrix_name}.XXXXXX")"
  rmdir "${active_worktree}"
  git -C "${repository_root}" worktree add --detach "${active_worktree}" "${expected_sha}" >/dev/null
  assert_source "${active_worktree}" || { infrastructure_invalid=1; overall_status=1; break; }
  worktree_ios="${active_worktree}/apps/ios"
  for story in "${stories[@]}"; do
    retained="${matrix_root}/Stories/${story}"
    story_start="${SECONDS}"
    story_status=0
    skip_build=1
    if [[ "${build_manifest_ready}" -eq 0 ]]; then skip_build=0; fi
    PLAYER_E2E_PARALLEL_WORKERS=1 \
      PLAYER_E2E_BUILD_DATA="${shared_build}" \
      PLAYER_E2E_OUTPUT="${retained}" \
      PLAYER_SIMULATOR_LEASE_ROOT="${simulator_lease_root}" \
      PLAYER_SKIP_E2E_BUILD="${skip_build}" \
      PLAYER_SKIP_E2E_ENVIRONMENT_VERIFICATION=1 \
    PLAYER_SKIP_PROJECT_GENERATION=1 \
      "${worktree_ios}/scripts/run-e2e.sh" --story "${story}" || story_status=$?
    if [[ ! -d "${retained}" ]]; then mkdir -p "${retained}"; fi
    evidence_valid=true
    if ! qualification_validate_evidence_manifest \
      "${retained}" "${active_worktree}/tests/e2e/${story}" "${story}"; then
      evidence_valid=false
      infrastructure_invalid=1
      story_status=1
    fi
    test_phase_entered=false
    if qualification_phase_was_recorded "${retained}/PhaseTimings.tsv" test; then test_phase_entered=true; fi
    if ! jq -e --arg sha "${expected_sha}" \
      '.commit == $sha and (.status == "passed" or .status == "failed")' \
      "${retained}/Run.json" >/dev/null 2>&1; then
      story_status=1
    elif [[ "${story_status}" -eq 0 ]] \
      && [[ "$(jq -r '.status' "${retained}/Run.json")" != passed ]]; then
      story_status=1
    fi

    if [[ "${build_manifest_ready}" -eq 0 ]]; then
      if has_build "${shared_build}"; then
        capture_build_manifest "${shared_build}" \
          "${matrix_root}/BuildManifest.before.sha256"
        build_manifest_ready=1
      else
        infrastructure_invalid=1
      fi
    fi
    result=passed signature=none
    if [[ "${story_status}" -ne 0 ]]; then
      result=failed
      signature="$(qualification_failure_signature "${retained}" "${story_status}")"
      overall_status=1
      if [[ "${test_phase_entered}" == false ]]; then infrastructure_invalid=1; fi
    fi
    jq -n -c --arg story "${story}" --arg commit "${expected_sha}" \
      --arg status "${result}" --arg signature "${signature}" \
      --argjson exitCode "${story_status}" --argjson durationSeconds "$((SECONDS - story_start))" \
      --argjson testPhaseEntered "${test_phase_entered}" \
      --argjson evidenceValid "${evidence_valid}" \
      --arg artifact "Matrices/${matrix_name}/Stories/${story}" \
      '{story: $story, commit: $commit, status: $status, signature: $signature,
        exitCode: $exitCode, durationSeconds: $durationSeconds,
        testPhaseEntered: $testPhaseEntered, evidenceValid: $evidenceValid,
        artifact: $artifact}' >> "${matrix_root}/stories.jsonl"
    if [[ "${infrastructure_invalid}" -eq 1 ]]; then overall_status=1; break; fi
  done

  core_summary='{"required":false,"status":"not-required"}'
  if [[ "${infrastructure_invalid}" -eq 0 && "${run_core}" -eq 1 ]]; then
    if ! run_core_gate "${active_worktree}" "${matrix_root}" "${matrix_index}"; then overall_status=1; fi
    core_summary="$(cat "${matrix_root}/Core/CoreSummary.json")"
  fi
  renderer_summary='{"required":false,"status":"not-required"}'
  if [[ "${infrastructure_invalid}" -eq 0 ]] \
    && printf '%s\n' "${stories[@]}" | grep -qx '013-app-store-listing'; then
    renderer_root="${matrix_root}/AppStoreListing"
    mkdir -p "${renderer_root}/screenshots"
    renderer_start="${SECONDS}"
    renderer_status=0
    renderer_pipeline_statuses=()
    set +e
    swift "${active_worktree}/scripts/render-app-store-listing.swift" \
      "${active_worktree}/app-store/listing.json" \
      "${matrix_root}/Stories/013-app-store-listing/ActualWalkthrough/screenshots/ios" \
      "${renderer_root}/screenshots" \
      2>&1 | tee "${renderer_root}/renderer.log"
    renderer_pipeline_statuses=("${PIPESTATUS[@]}")
    set -e
    if [[ "${renderer_pipeline_statuses[0]}" -ne 0 ]]; then
      renderer_status="${renderer_pipeline_statuses[0]}"
    elif [[ "${renderer_pipeline_statuses[1]}" -ne 0 ]]; then
      renderer_status="${renderer_pipeline_statuses[1]}"
    fi
    expected_assets="$(jq '.slides | length' "${active_worktree}/app-store/listing.json")"
    rendered_assets="$(find "${renderer_root}/screenshots" -type f -name '*.png' | wc -l | tr -d ' ')"
    if [[ "${rendered_assets}" -ne "${expected_assets}" ]]; then renderer_status=1; fi
    jq -n --argjson required true --argjson exitCode "${renderer_status}" \
      --argjson durationSeconds "$((SECONDS - renderer_start))" \
      --argjson renderedAssetCount "${rendered_assets}" --argjson expectedAssetCount "${expected_assets}" \
      --arg artifact "Matrices/${matrix_name}/AppStoreListing" \
      --arg status "$([[ "${renderer_status}" -eq 0 ]] && echo passed || echo failed)" \
      '{required: $required, status: $status, exitCode: $exitCode,
        durationSeconds: $durationSeconds, renderedAssetCount: $renderedAssetCount,
        expectedAssetCount: $expectedAssetCount, artifact: $artifact}' \
      > "${renderer_root}/AppStoreRendererSummary.json"
    qualification_write_integrity_manifest "${renderer_root}"
    renderer_summary="$(cat "${renderer_root}/AppStoreRendererSummary.json")"
    if [[ "${renderer_status}" -ne 0 ]]; then overall_status=1; fi
  fi
  if [[ "${build_manifest_ready}" -eq 1 ]]; then
    capture_build_manifest "${shared_build}" \
      "${matrix_root}/BuildManifest.after.sha256"
    if ! cmp "${matrix_root}/BuildManifest.before.sha256" \
      "${matrix_root}/BuildManifest.after.sha256"; then
      build_unchanged=false
      infrastructure_invalid=1
      overall_status=1
    fi
  else
    build_unchanged=false
    infrastructure_invalid=1
    overall_status=1
  fi
  assert_source "${active_worktree}" || { infrastructure_invalid=1; overall_status=1; }
  git -C "${repository_root}" worktree remove --force "${active_worktree}"
  active_worktree=""

  matrix_status=passed
  if [[ "${infrastructure_invalid}" -eq 1 ]] \
    || jq -s -e 'any(.[]; .status != "passed")' "${matrix_root}/stories.jsonl" >/dev/null \
    || [[ "$(jq -r '.status' <<< "${core_summary}")" == failed ]] \
    || [[ "$(jq -r '.status' <<< "${renderer_summary}")" == failed ]]; then
    matrix_status=failed
  fi
  jq -s --arg lane "${lane}" --arg commit "${expected_sha}" \
    --argjson matrixAttempt "${matrix_index}" --arg status "${matrix_status}" \
    --argjson core "${core_summary}" \
    --argjson appStoreRenderer "${renderer_summary}" \
    --argjson durationSeconds "$((SECONDS - matrix_wall_start))" \
    '{lane: $lane, commit: $commit, matrixAttempt: $matrixAttempt,
      status: $status, durationSeconds: $durationSeconds,
      stories: ., core: $core, appStoreRenderer: $appStoreRenderer}' \
    "${matrix_root}/stories.jsonl" > "${matrix_root}/MatrixSummary.json"

  if [[ "${infrastructure_invalid}" -eq 1 ]]; then break; fi
done

assert_source "${repository_root}" || { infrastructure_invalid=1; overall_status=1; }

matrix_summaries=()
while IFS= read -r summary; do matrix_summaries+=("${summary}"); done \
  < <(find "${lane_root}/Matrices" -name MatrixSummary.json -type f | sort)
if [[ ${#matrix_summaries[@]} -gt 0 ]]; then
  jq -s --arg stage matrix --arg lane "${lane}" --arg commit "${expected_sha}" \
    --argjson requestedMatrices "${matrix_count}" --argjson buildUnchanged "${build_unchanged}" \
    --argjson infrastructureInvalid "${infrastructure_invalid}" \
    --arg status "$([[ "${overall_status}" -eq 0 ]] && echo passed || echo failed)" \
    '{stage: $stage, lane: $lane, commit: $commit,
      requestedMatrices: $requestedMatrices, matrixCount: length,
      buildUnchanged: $buildUnchanged,
      infrastructureInvalid: ($infrastructureInvalid == 1),
      status: $status, matrices: .}' "${matrix_summaries[@]}" \
    > "${lane_root}/MatrixLaneSummary.json"
else
  jq -n --arg lane "${lane}" --arg commit "${expected_sha}" \
    '{stage: "matrix", lane: $lane, commit: $commit, status: "failed",
      buildUnchanged: false, infrastructureInvalid: true, matrices: []}' \
    > "${lane_root}/MatrixLaneSummary.json"
  overall_status=1
fi

exit "${overall_status}"
