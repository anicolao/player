#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/qualification-support.sh"
ios_dir="$(cd "${script_dir}/../.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
manifest="${repository_root}/tests/e2e/manifest.json"
lane=""
expected_sha=""
attempt_count=10
attempt_start=1
output_root="${ios_dir}/DerivedData/R0Qualification/Stories"
prebuilt_build=""
simulator_lease_root="${ios_dir}/DerivedData/SimulatorLeases"
stories=()

usage() {
  cat >&2 <<'EOF'
usage: run-story-lane.sh --lane <id> --sha <commit> [--attempts 10]
                         [--attempt-start 1] [--prebuilt-build <directory>]
                         [--output-root <directory>] --story <id>...

Runs every named canonical story for exactly the requested number of measured
attempts. Test failures are retained and do not stop later attempts. A build or
source-integrity failure invalidates the lane and is never retried.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane) lane="$2"; shift 2 ;;
    --sha) expected_sha="$2"; shift 2 ;;
    --attempts) attempt_count="$2"; shift 2 ;;
    --attempt-start) attempt_start="$2"; shift 2 ;;
    --prebuilt-build) prebuilt_build="$2"; shift 2 ;;
    --output-root) output_root="$2"; shift 2 ;;
    --story) stories+=("$2"); shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "${lane}" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || { echo "A lowercase story-lane identifier is required." >&2; exit 2; }
[[ "${expected_sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "A full lowercase commit SHA is required." >&2; exit 2; }
[[ "${attempt_count}" =~ ^[1-9][0-9]*$ ]] || { echo "Attempt count must be positive." >&2; exit 2; }
[[ "${attempt_start}" =~ ^[1-9][0-9]*$ ]] || { echo "Attempt start must be positive." >&2; exit 2; }
if [[ -n "${prebuilt_build}" && "${prebuilt_build}" != /* ]]; then
  echo "The prebuilt build path must be absolute." >&2
  exit 2
fi
[[ ${#stories[@]} -gt 0 ]] || { echo "At least one --story is required." >&2; exit 2; }

assert_source() {
  [[ "$(git -C "${repository_root}" rev-parse HEAD)" == "${expected_sha}" ]] \
    || { echo "Qualification source SHA changed." >&2; return 1; }
  git -C "${repository_root}" diff --quiet \
    && git -C "${repository_root}" diff --cached --quiet \
    || { echo "Qualification tracked source is dirty." >&2; return 1; }
}

has_build() {
  find "$1/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit \
    2>/dev/null | grep -q .
}

capture_build_manifest() {
  local build_root="$1"
  local destination="$2"
  (
    cd "${build_root}"
    find Build/Products -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 shasum -a 256
  ) > "${destination}"
}

requested="$(printf '%s\n' "${stories[@]}" | sort)"
[[ "$(printf '%s\n' "${stories[@]}" | sort -u)" == "${requested}" ]] \
  || { echo "A story may appear only once in a lane." >&2; exit 2; }
while IFS= read -r story; do
  jq -e --arg story "${story}" 'any(.[]; .story == $story)' "${manifest}" >/dev/null \
    || { echo "Unknown canonical story: ${story}" >&2; exit 2; }
done <<< "${requested}"
assert_source

lane_root="${output_root}/${lane}"
shared_build="${prebuilt_build:-${lane_root}/Build}"
rm -rf "${lane_root}"
mkdir -p "${lane_root}/Stories"
lane_started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
overall_status=0
infrastructure_invalid=0
build_manifest_ready=0
if [[ -n "${prebuilt_build}" ]]; then
  if has_build "${shared_build}"; then
    capture_build_manifest "${shared_build}" "${lane_root}/BuildManifest.before.sha256"
    build_manifest_ready=1
  else
    echo "The provenance-bound prebuilt E2E product is unavailable." >&2
    infrastructure_invalid=1
    overall_status=1
  fi
fi

if [[ "${infrastructure_invalid}" -eq 1 ]]; then
  jq -n --arg lane "${lane}" --arg commit "${expected_sha}" \
    '{stage: "story", lane: $lane, commit: $commit, status: "failed",
      buildUnchanged: false, infrastructureInvalid: true, stories: []}' \
    > "${lane_root}/StoryLaneSummary.json"
  exit 1
fi

for story in "${stories[@]}"; do
  story_root="${lane_root}/Stories/${story}"
  mkdir -p "${story_root}"
  : > "${story_root}/attempts.jsonl"
  printf 'attempt\tresult\tduration_seconds\texit_code\ttest_phase_entered\tsignature\n' \
    > "${story_root}/attempts.tsv"

  attempt_end=$((attempt_start + attempt_count - 1))
  for ((attempt = attempt_start; attempt <= attempt_end; attempt += 1)); do
    assert_source || { infrastructure_invalid=1; overall_status=1; break; }
    attempt_name="$(printf 'attempt-%02d' "${attempt}")"
    retained="${story_root}/${attempt_name}"
    started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    attempt_wall_start="${SECONDS}"
    attempt_status=0
    skip_build=1
    if [[ "${build_manifest_ready}" -eq 0 ]]; then skip_build=0; fi

    PLAYER_E2E_PARALLEL_WORKERS=1 \
      PLAYER_E2E_BUILD_DATA="${shared_build}" \
      PLAYER_E2E_OUTPUT="${retained}" \
      PLAYER_SIMULATOR_LEASE_ROOT="${simulator_lease_root}" \
      PLAYER_SKIP_E2E_BUILD="${skip_build}" \
      PLAYER_SKIP_E2E_ENVIRONMENT_VERIFICATION=1 \
      PLAYER_SKIP_PROJECT_GENERATION=1 \
      "${ios_dir}/scripts/run-e2e.sh" --story "${story}" || attempt_status=$?

    if [[ ! -d "${retained}" ]]; then
      mkdir -p "${retained}"
    fi
    duration=$((SECONDS - attempt_wall_start))
    evidence_valid=true
    if ! qualification_validate_evidence_manifest \
      "${retained}" "${repository_root}/tests/e2e/${story}" "${story}"; then
      evidence_valid=false
      infrastructure_invalid=1
      attempt_status=1
    fi
    test_phase_entered=false
    if qualification_phase_was_recorded "${retained}/PhaseTimings.tsv" test; then
      test_phase_entered=true
    fi
    if ! jq -e --arg sha "${expected_sha}" \
      '.commit == $sha and (.status == "passed" or .status == "failed")' \
      "${retained}/Run.json" >/dev/null 2>&1; then
      attempt_status=1
    elif [[ "${attempt_status}" -eq 0 ]] \
      && [[ "$(jq -r '.status' "${retained}/Run.json")" != passed ]]; then
      attempt_status=1
    fi

    if [[ "${build_manifest_ready}" -eq 0 ]]; then
      if has_build "${shared_build}"; then
        capture_build_manifest "${shared_build}" "${lane_root}/BuildManifest.before.sha256"
        build_manifest_ready=1
      else
        infrastructure_invalid=1
        overall_status=1
      fi
    fi

    result=passed
    signature=none
    if [[ "${attempt_status}" -ne 0 ]]; then
      result=failed
      signature="$(qualification_failure_signature "${retained}" "${attempt_status}")"
      overall_status=1
      if [[ "${test_phase_entered}" == false ]]; then infrastructure_invalid=1; fi
    fi

    jq -n -c \
      --argjson attempt "${attempt}" \
      --arg startedAt "${started_at}" \
      --arg result "${result}" \
      --argjson durationSeconds "${duration}" \
      --argjson exitCode "${attempt_status}" \
      --argjson testPhaseEntered "${test_phase_entered}" \
      --argjson evidenceValid "${evidence_valid}" \
      --arg signature "${signature}" \
      --arg artifact "Stories/${story}/${attempt_name}" \
      '{attempt: $attempt, startedAt: $startedAt, result: $result,
        durationSeconds: $durationSeconds, exitCode: $exitCode,
        testPhaseEntered: $testPhaseEntered, evidenceValid: $evidenceValid,
        signature: $signature,
        artifact: $artifact}' >> "${story_root}/attempts.jsonl"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${attempt}" "${result}" "${duration}" "${attempt_status}" \
      "${test_phase_entered}" "${signature}" >> "${story_root}/attempts.tsv"

    if [[ "${infrastructure_invalid}" -eq 1 ]]; then break; fi
  done

  jq -s \
    --arg story "${story}" \
    --arg commit "${expected_sha}" \
    --argjson requestedAttempts "${attempt_count}" \
    '{story: $story, commit: $commit, requestedAttempts: $requestedAttempts,
      attemptCount: length, passCount: (map(select(.result == "passed")) | length),
      failureCount: (map(select(.result == "failed")) | length), attempts: .}' \
    "${story_root}/attempts.jsonl" > "${story_root}/StorySummary.json"

  if [[ "${infrastructure_invalid}" -eq 1 ]]; then break; fi
done

build_unchanged=false
if [[ "${build_manifest_ready}" -eq 1 ]]; then
  capture_build_manifest "${shared_build}" "${lane_root}/BuildManifest.after.sha256"
  if cmp "${lane_root}/BuildManifest.before.sha256" \
    "${lane_root}/BuildManifest.after.sha256"; then
    build_unchanged=true
  else
    overall_status=1
  fi
fi
assert_source || { infrastructure_invalid=1; overall_status=1; }

story_summaries=()
while IFS= read -r summary; do story_summaries+=("${summary}"); done \
  < <(find "${lane_root}/Stories" -name StorySummary.json -type f | sort)
if [[ ${#story_summaries[@]} -gt 0 ]]; then
  jq -s \
    --arg stage story \
    --arg lane "${lane}" \
    --arg commit "${expected_sha}" \
    --arg startedAt "${lane_started}" \
    --arg completedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson requestedAttempts "${attempt_count}" \
    --argjson buildUnchanged "${build_unchanged}" \
    --argjson infrastructureInvalid "${infrastructure_invalid}" \
    --arg status "$([[ "${overall_status}" -eq 0 ]] && echo passed || echo failed)" \
    '{stage: $stage, lane: $lane, commit: $commit, startedAt: $startedAt,
      completedAt: $completedAt, requestedAttempts: $requestedAttempts,
      buildUnchanged: $buildUnchanged,
      infrastructureInvalid: ($infrastructureInvalid == 1),
      status: $status, stories: .}' \
    "${story_summaries[@]}" > "${lane_root}/StoryLaneSummary.json"
else
  jq -n \
    --arg lane "${lane}" --arg commit "${expected_sha}" \
    '{stage: "story", lane: $lane, commit: $commit, status: "failed",
      buildUnchanged: false, infrastructureInvalid: true, stories: []}' \
    > "${lane_root}/StoryLaneSummary.json"
  overall_status=1
fi

exit "${overall_status}"
