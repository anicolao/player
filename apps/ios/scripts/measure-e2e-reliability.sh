#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
story=""
attempt_count=10
qualification_root="${ios_dir}/DerivedData/E2EQualification"

usage() {
  cat >&2 <<'EOF'
usage: measure-e2e-reliability.sh --story <story-id> [--attempts <count>] [--output-root <directory>]

Runs every attempt from a fresh story simulator, retains every pass and failure,
and exits unsuccessfully when any attempt fails. It never retries an attempt.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --story)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      story="$2"
      shift 2
      ;;
    --attempts)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      attempt_count="$2"
      shift 2
      ;;
    --output-root)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      qualification_root="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ "${story}" =~ ^[0-9]{3}-[a-z0-9][a-z0-9-]*$ ]] || {
  echo "A valid --story is required." >&2
  exit 2
}
[[ "${attempt_count}" =~ ^[1-9][0-9]*$ ]] || {
  echo "--attempts must be a positive integer." >&2
  exit 2
}
jq -e --arg story "${story}" 'any(.[]; .story == $story)' \
  "${repository_root}/tests/e2e/manifest.json" >/dev/null || {
    echo "Unknown canonical story: ${story}" >&2
    exit 2
  }

source_is_clean() {
  [[ -z "$(git -C "${repository_root}" status --porcelain --untracked-files=normal)" ]]
}

if ! source_is_clean; then
  echo "Reliability measurements require a clean worktree." >&2
  exit 2
fi

measurement_commit="$(git -C "${repository_root}" rev-parse HEAD)"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')-${measurement_commit:0:12}-${story}"
run_root="${qualification_root}/${run_id}"
shared_build_data="${run_root}/Build"
mkdir -p "${run_root}"
: > "${run_root}/attempts.jsonl"
: > "${run_root}/attempts.tsv"
printf 'attempt\tresult\tduration_seconds\texit_code\tsignature\n' \
  >> "${run_root}/attempts.tsv"

"${script_dir}/verify-e2e-environment.sh"
"${script_dir}/generate-project.sh"

pass_count=0
failure_count=0
for ((attempt = 1; attempt <= attempt_count; attempt += 1)); do
  if [[ "$(git -C "${repository_root}" rev-parse HEAD)" != "${measurement_commit}" ]] \
    || ! source_is_clean; then
    echo "The source changed during reliability measurement." >&2
    exit 2
  fi

  attempt_name="$(printf 'attempt-%02d' "${attempt}")"
  attempt_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  attempt_start_seconds="${SECONDS}"
  attempt_status=0
  skip_build=0
  if find "${shared_build_data}/Build/Products" -maxdepth 1 \
    -name '*.xctestrun' -print -quit 2>/dev/null | grep -q .; then
    skip_build=1
  fi
  PLAYER_E2E_PARALLEL_WORKERS=1 \
    PLAYER_E2E_BUILD_DATA="${shared_build_data}" \
    PLAYER_SKIP_E2E_BUILD="${skip_build}" \
    PLAYER_SKIP_E2E_ENVIRONMENT_VERIFICATION=1 \
    PLAYER_SKIP_PROJECT_GENERATION=1 \
    "${script_dir}/run-e2e.sh" "${story}" || attempt_status=$?
  attempt_duration=$((SECONDS - attempt_start_seconds))
  attempt_output="${ios_dir}/DerivedData/E2E/${story}"
  retained_output="${run_root}/${attempt_name}"
  if [[ -d "${attempt_output}" ]]; then
    mv "${attempt_output}" "${retained_output}"
  else
    mkdir -p "${retained_output}"
  fi

  result="passed"
  signature="none"
  if [[ "${attempt_status}" -eq 0 ]]; then
    pass_count=$((pass_count + 1))
  else
    result="failed"
    failure_count=$((failure_count + 1))
    if [[ -f "${retained_output}/Diagnostics/ScreenshotComparison/summary.json" ]] \
      && [[ "$(jq -r '.failureCount // 0' \
        "${retained_output}/Diagnostics/ScreenshotComparison/summary.json")" -gt 0 ]]; then
      signature="screenshot-comparison"
    elif [[ -f "${retained_output}/Logs/test.log" ]]; then
      signature="$(rg -m 1 -o '[A-Za-z0-9_]+UITests\.test[A-Za-z0-9_]+' \
        "${retained_output}/Logs/test.log" || true)"
      if [[ -z "${signature}" ]]; then signature="test-exit-${attempt_status}"; fi
    else
      signature="harness-exit-${attempt_status}"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${attempt}" "${result}" "${attempt_duration}" "${attempt_status}" "${signature}" \
    >> "${run_root}/attempts.tsv"
  jq -n -c \
    --argjson attempt "${attempt}" \
    --arg startedAt "${attempt_started}" \
    --arg result "${result}" \
    --argjson durationSeconds "${attempt_duration}" \
    --argjson exitCode "${attempt_status}" \
    --arg signature "${signature}" \
    --arg artifact "${attempt_name}" \
    '{attempt: $attempt, startedAt: $startedAt, result: $result,
      durationSeconds: $durationSeconds, exitCode: $exitCode,
      signature: $signature, artifact: $artifact}' \
    >> "${run_root}/attempts.jsonl"
  printf 'Attempt %d/%d: %s (%ss, %s)\n' \
    "${attempt}" "${attempt_count}" "${result}" "${attempt_duration}" "${signature}"
done

jq -s \
  --arg story "${story}" \
  --arg commit "${measurement_commit}" \
  --arg runID "${run_id}" \
  --argjson requestedAttempts "${attempt_count}" \
  --argjson passCount "${pass_count}" \
  --argjson failureCount "${failure_count}" \
  '{story: $story, commit: $commit, runID: $runID, sharedBuild: true,
    requestedAttempts: $requestedAttempts, passCount: $passCount,
    failureCount: $failureCount, attempts: .}' \
  "${run_root}/attempts.jsonl" > "${run_root}/Summary.json"

echo "Reliability measurement: ${pass_count}/${attempt_count} passed; artifacts: ${run_root}"
if [[ "${failure_count}" -ne 0 ]]; then exit 1; fi
