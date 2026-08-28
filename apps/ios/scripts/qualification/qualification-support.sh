#!/usr/bin/env bash

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

qualification_failure_signature() {
  local retained="$1" exit_code="$2"
  local failure_evidence="${retained}/Diagnostics/FailureEvidence.json"
  local test_log="${retained}/Logs/test.log"
  if [[ -f "${failure_evidence}" ]] \
    && [[ "$(jq -r '.testExitCode // 0' "${failure_evidence}")" -ne 0 ]]; then
    local failed_tests
    failed_tests="$( { rg -o '[A-Za-z0-9_]+UITests\.test[A-Za-z0-9_]+' \
      "${test_log}" 2>/dev/null || true; } | LC_ALL=C sort -u | paste -sd+ -)"
    echo "ui-test:${failed_tests:-unidentified}:exit-$(jq -r '.testExitCode' "${failure_evidence}")"
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
