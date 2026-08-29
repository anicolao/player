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
      && rg -Fq 'via Xcode: Timed out while launching application via Xcode.' "${test_log}"; then
      echo "infrastructure:xcode-application-launch-timeout:${failed_tests:-unidentified}:exit-$(jq -r '.testExitCode' "${failure_evidence}")"
    else
      echo "ui-test:${failed_tests:-unidentified}:exit-$(jq -r '.testExitCode' "${failure_evidence}")"
    fi
  elif [[ -f "${retained}/Diagnostics/ScreenshotComparison/summary.json" ]] \
    && [[ "$(jq -r '.failureCount // 0' \
      "${retained}/Diagnostics/ScreenshotComparison/summary.json")" -gt 0 ]]; then
    jq -r '[.images[] | select(.result != "exact")][0]
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
