#!/usr/bin/env bash

qualification_support_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

qualification_write_evidence_manifest() {
  local retained="$1" story_root="$2" story="$3"
  python3 "${qualification_support_dir}/evidence_manifest.py" \
    write "${retained}" "${story_root}" --story "${story}"
}

qualification_validate_evidence_manifest() {
  local retained="$1" story_root="$2" story="$3"
  python3 "${qualification_support_dir}/evidence_manifest.py" \
    validate "${retained}" "${story_root}" --story "${story}"
}

qualification_phase_was_recorded() {
  local timings="$1" requested_phase="$2"
  [[ -f "${timings}" ]] || return 1
  awk -F '\t' -v requested="${requested_phase}" '
    $1 == requested {
      count += 1
      if (NF != 4 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $3 < $2 || $4 == "") invalid = 1
    }
    END { exit !(count == 1 && invalid == 0) }
  ' "${timings}"
}

qualification_run_logged_commands() {
  local log_file="$1"
  shift
  [[ "$#" -gt 0 ]] || return 2
  QUALIFICATION_FAILED_COMMAND=""
  QUALIFICATION_COMMAND_EXIT_CODE=0
  QUALIFICATION_LOG_EXIT_CODE=0
  if ! : > "${log_file}"; then
    QUALIFICATION_LOG_EXIT_CODE=1
    return 1
  fi
  local command command_status log_status
  local -a pipeline_statuses
  for command in "$@"; do
    "${command}" 2>&1 | tee -a "${log_file}"
    pipeline_statuses=("${PIPESTATUS[@]}")
    command_status="${pipeline_statuses[0]}"
    log_status="${pipeline_statuses[1]}"
    if [[ "${command_status}" -ne 0 || "${log_status}" -ne 0 ]]; then
      if [[ "${command_status}" -ne 0 ]]; then
        QUALIFICATION_FAILED_COMMAND="$(basename "${command}")"
      fi
      QUALIFICATION_COMMAND_EXIT_CODE="${command_status}"
      QUALIFICATION_LOG_EXIT_CODE="${log_status}"
      if [[ "${command_status}" -ne 0 ]]; then return "${command_status}"; fi
      return "${log_status}"
    fi
  done
  return 0
}

qualification_write_integrity_manifest() {
  local root="$1"
  local temporary="${root}/.EvidenceManifest.sha256.$$"
  (
    cd "${root}"
    find . -type f ! -name 'EvidenceManifest.sha256' \
      ! -name '.EvidenceManifest.sha256.*' -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' path; do shasum -a 256 "${path}"; done \
      | sed 's#  \./#  #'
  ) > "${temporary}"
  mv "${temporary}" "${root}/EvidenceManifest.sha256"
}

qualification_failed_ui_tests_from_xcresult() {
  local result_bundle="$1"
  local tests_json
  [[ -d "${result_bundle}" ]] || return 1
  tests_json="$(xcrun xcresulttool get test-results tests \
    --path "${result_bundle}" --format json 2>/dev/null)" || return 1
  jq -r '
    def is_failure:
      ((.testStatus? // .status? // .result? // "") | tostring | ascii_downcase)
        as $outcome
      | $outcome == "failure" or $outcome == "failed";
    .. | objects | select(is_failure)
    | [.identifier?, .name?, .testName?][] | strings
    | capture("(?<class>[A-Za-z0-9_]+UITests)[./ ](?<method>test[A-Za-z0-9_]+)")?
    | select(. != null)
    | "\(.class).\(.method)"
  ' <<< "${tests_json}" | LC_ALL=C sort -u
}

qualification_failed_ui_tests_from_log() {
  local test_log="$1"
  [[ -f "${test_log}" ]] || return 1
  sed -nE \
    "s/^[[:space:]]*Test Case '-\\[[^ ]*\\.([A-Za-z0-9_]+UITests) (test[A-Za-z0-9_]+)\\]' failed.*$/\\1.\\2/p" \
    "${test_log}" | LC_ALL=C sort -u
}

qualification_failed_ui_tests() {
  local retained="$1"
  local failed_tests
  failed_tests="$(qualification_failed_ui_tests_from_xcresult \
    "${retained}/Results/Story.xcresult" || true)"
  if [[ -z "${failed_tests}" ]]; then
    failed_tests="$(qualification_failed_ui_tests_from_log \
      "${retained}/Logs/test.log" || true)"
  fi
  printf '%s\n' "${failed_tests}"
}

qualification_failure_signature() {
  local retained="$1" exit_code="$2"
  local failure_evidence="${retained}/Diagnostics/FailureEvidence.json"
  local test_log="${retained}/Logs/test.log"
  if [[ -f "${failure_evidence}" ]] \
    && [[ "$(jq -r '.testExitCode // 0' "${failure_evidence}")" -ne 0 ]]; then
    local failed_tests
    failed_tests="$(qualification_failed_ui_tests "${retained}" | sed '/^$/d' | paste -sd+ -)"
    if [[ -f "${test_log}" ]] \
      && grep -Fq 'via Xcode: Timed out while launching application via Xcode.' "${test_log}"; then
      echo "infrastructure:xcode-application-launch-timeout:${failed_tests:-unidentified}:exit-$(jq -r '.testExitCode' "${failure_evidence}")"
    else
      echo "ui-test:${failed_tests:-unidentified}:exit-$(jq -r '.testExitCode' "${failure_evidence}")"
    fi
  elif [[ -f "${retained}/Diagnostics/ScreenshotComparison/summary.json" ]] \
    && [[ "$(jq -r '.failureCount // 0' \
      "${retained}/Diagnostics/ScreenshotComparison/summary.json")" -gt 0 ]]; then
    jq -r '[.images[] | select(.result != "exact" and .result != "canonical")][0]
      | "screenshot:\(.result):\(.name)"' \
      "${retained}/Diagnostics/ScreenshotComparison/summary.json"
  elif [[ -f "${retained}/PhaseTimings.tsv" ]]; then
    local failed_phase
    failed_phase="$(awk -F '\t' '$4 != "0" { print "phase:" $1 ":exit-" $4; exit }' \
      "${retained}/PhaseTimings.tsv")"
    echo "${failed_phase:-infrastructure:exit-${exit_code}}"
  else
    echo "infrastructure:no-phase-evidence:exit-${exit_code}"
  fi
}

qualification_failed_core_tests_from_xcresult() {
  local result_bundle="$1"
  local tests_json failed_tests
  [[ -d "${result_bundle}" ]] || return 1
  tests_json="$(xcrun xcresulttool get test-results tests \
    --path "${result_bundle}" --format json 2>/dev/null)" || return 1
  failed_tests="$(jq -r '
    def is_failure:
      ((.testStatus? // .status? // .result? // "") | tostring | ascii_downcase)
        as $outcome
      | $outcome == "failure" or $outcome == "failed";
    .. | objects | select(is_failure)
    | [.identifier?, .name?, .testName?][] | strings
    | capture("(?<class>[A-Za-z0-9_]+Tests)[./ ](?<method>test[A-Za-z0-9_]+)")?
    | select(. != null)
    | "\(.class).\(.method)"
  ' <<< "${tests_json}")" || return 1
  printf '%s\n' "${failed_tests}" | sed '/^$/d' | LC_ALL=C sort -u
}

qualification_failed_core_tests_from_log() {
  local test_log="$1"
  [[ -f "${test_log}" ]] || return 1
  sed -nE \
    -e "s/^[[:space:]]*Test Case '-\\[[^ ]*\\.([A-Za-z0-9_]+Tests) (test[A-Za-z0-9_]+)\\]' failed.*$/\\1.\\2/p" \
    -e 's/^[[:space:]]*([A-Za-z0-9_]+Tests)\.(test[A-Za-z0-9_]+)\(\)[[:space:]]*$/\1.\2/p' \
    "${test_log}" | LC_ALL=C sort -u
}

qualification_failed_core_tests() {
  local core_root="$1"
  local failed_tests
  failed_tests="$(qualification_failed_core_tests_from_xcresult \
    "${core_root}/Results/Core.xcresult" || true)"
  if [[ -z "${failed_tests}" ]]; then
    failed_tests="$(qualification_failed_core_tests_from_log \
      "${core_root}/Logs/tests.log" || true)"
  fi
  printf '%s\n' "${failed_tests}"
}

qualification_core_failure_signature() {
  local core_root="$1" fixture_exit="$2" test_exit="$3"
  local failed_fixture="${4:-}" fixture_log_exit="${5:-0}"
  local test_log_exit="${6:-0}" cleanup_exit="${7:-0}"
  local result_summary_exit="${8:-0}"
  if [[ "${fixture_exit}" -ne 0 ]]; then
    if [[ -n "${failed_fixture}" ]]; then
      echo "core-fixture:${failed_fixture}:exit-${fixture_exit}"
    else
      echo "core-fixtures:exit-${fixture_exit}"
    fi
    return
  fi
  if [[ "${fixture_log_exit}" -ne 0 ]]; then
    echo "infrastructure:core-fixture-log:exit-${fixture_log_exit}"
    return
  fi
  local failed_tests
  if [[ "${test_exit}" -ne 0 ]]; then
    failed_tests="$(qualification_failed_core_tests "${core_root}" \
      | sed '/^$/d' | paste -sd+ -)"
    echo "core-test:${failed_tests:-unidentified}:exit-${test_exit}"
  elif [[ "${test_log_exit}" -ne 0 ]]; then
    echo "infrastructure:core-test-log:exit-${test_log_exit}"
  elif [[ "${result_summary_exit}" -ne 0 ]]; then
    echo "infrastructure:core-result-summary:exit-${result_summary_exit}"
  elif [[ "${cleanup_exit}" -ne 0 ]]; then
    echo "infrastructure:core-simulator-cleanup:exit-${cleanup_exit}"
  else
    echo "infrastructure:core-unidentified"
  fi
}
