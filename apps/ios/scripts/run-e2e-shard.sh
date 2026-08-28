#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
canonical_manifest="${repository_root}/tests/e2e/manifest.json"
run_core=0
shard_id=""
stories=()
core_simulator_id=""
core_simulator_lease=""
simulator_lease_root="${PLAYER_SIMULATOR_LEASE_ROOT:-${ios_dir}/DerivedData/SimulatorLeases}"
device_type="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-26-5"

usage() {
  cat >&2 <<'EOF'
usage: run-e2e-shard.sh --shard <shard-id> [--core] <story-id>...

Runs canonical stories sequentially with a clean simulator and independent
diagnostics for every story. The shard builds the test bundle once and safely
reuses only that immutable build output. --core also runs PlayerTests and the
committed-fixture checks once in the shard.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shard)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      shard_id="$2"
      shift 2
      ;;
    --core)
      run_core=1
      shift
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
      stories+=("$1")
      shift
      ;;
  esac
done

if [[ ! "${shard_id}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "A lowercase shard identifier is required." >&2
  exit 2
fi

if [[ ${#stories[@]} -eq 0 ]]; then
  echo "At least one story is required." >&2
  exit 2
fi

requested_stories="$(printf '%s\n' "${stories[@]}" | sort)"
if [[ "$(printf '%s\n' "${stories[@]}" | sort -u)" != "${requested_stories}" ]]; then
  echo "A story may appear only once within shard ${shard_id}." >&2
  exit 2
fi

while IFS= read -r story; do
  if ! jq -e --arg story "${story}" 'any(.story == $story)' \
    "${canonical_manifest}" >/dev/null; then
    echo "Unknown canonical E2E story: ${story}" >&2
    exit 2
  fi
done <<< "${requested_stories}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
shard_root="${ios_dir}/DerivedData/E2EShards/${shard_id}"
shared_build_data="${shard_root}/Build"
shard_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
shard_commit="$(git -C "${repository_root}" rev-parse HEAD)"
shard_start_seconds="${SECONDS}"
overall_status=0

rm -rf "${shard_root}"
mkdir -p "${shard_root}/Logs" "${shard_root}/Core"
mkdir -p "${ios_dir}/DerivedData/E2E"
: > "${shard_root}/StoryTimings.tsv"
jq -n \
  --arg shard "${shard_id}" \
  --arg commit "${shard_commit}" \
  --arg startedAt "${shard_started_at}" \
  --argjson includesCore "${run_core}" \
  --args \
  '{shard: $shard, commit: $commit, startedAt: $startedAt,
    includesCore: ($includesCore == 1), stories: $ARGS.positional,
    status: "running"}' \
  -- "${stories[@]}" \
  > "${shard_root}/Shard.json"

cleanup() {
  local run_status="$?"
  trap - EXIT INT TERM
  set +e
  if [[ -f "${core_simulator_lease}" && ! -L "${core_simulator_lease}" ]]; then
    if ! "${script_dir}/simulator-lease.sh" release "${core_simulator_lease}" "$$"; then
      echo "Could not delete core-test simulator ${core_simulator_id}." >&2
      if [[ "${run_status}" -eq 0 ]]; then run_status=1; fi
    fi
  fi
  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  jq \
    --arg completedAt "${completed_at}" \
    --arg status "$([[ "${run_status}" -eq 0 ]] && echo passed || echo failed)" \
    --argjson exitCode "${run_status}" \
    --argjson durationSeconds "$((SECONDS - shard_start_seconds))" \
    '. + {completedAt: $completedAt, status: $status,
          exitCode: $exitCode, durationSeconds: $durationSeconds}' \
    "${shard_root}/Shard.json" > "${shard_root}/Shard.json.next" \
    && mv "${shard_root}/Shard.json.next" "${shard_root}/Shard.json"
  exit "${run_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_core_tests() {
  local fixture_start="${SECONDS}"
  local fixture_status=0
  {
    "${script_dir}/fixtures/verify-generated-fixtures.sh"
    "${script_dir}/fixtures/verify-messy-multifile-fixture.sh"
    "${script_dir}/fixtures/verify-zip-fixtures.sh"
    "${script_dir}/fixtures/verify-import-channel-fixtures.sh"
    "${script_dir}/fixtures/verify-metadata-repair-fixture.sh"
    "${script_dir}/fixtures/verify-populated-library-fixture.sh"
  } 2>&1 | tee "${shard_root}/Logs/core-fixtures.log" || fixture_status="${PIPESTATUS[0]}"
  printf 'core-fixtures\t%s\t%s\t%s\n' \
    "${fixture_start}" "${SECONDS}" "${fixture_status}" \
    >> "${shard_root}/StoryTimings.tsv"
  if [[ "${fixture_status}" -ne 0 ]]; then return "${fixture_status}"; fi

  local core_start="${SECONDS}"
  local core_status=0
  core_simulator_lease="${simulator_lease_root}/core-shard-${shard_id}-$$.json"
  core_simulator_id="$("${script_dir}/simulator-lease.sh" acquire \
    "${core_simulator_lease}" "Player Core ${shard_id} $$" \
    "${device_type}" "${runtime}" "$$")"
  xcrun simctl boot "${core_simulator_id}"
  xcrun simctl bootstatus "${core_simulator_id}" -b
  xcodebuild -quiet \
    -project "${ios_dir}/Player.xcodeproj" \
    -scheme Player \
    -configuration E2E \
    -destination "platform=iOS Simulator,id=${core_simulator_id}" \
    -derivedDataPath "${shared_build_data}" \
    -parallel-testing-enabled NO \
    -only-testing:PlayerTests \
    -resultBundlePath "${shard_root}/Core/Core.xcresult" \
    test-without-building \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "${shard_root}/Logs/core-tests.log" || core_status="${PIPESTATUS[0]}"
  printf 'core-tests\t%s\t%s\t%s\n' \
    "${core_start}" "${SECONDS}" "${core_status}" \
    >> "${shard_root}/StoryTimings.tsv"
  if "${script_dir}/simulator-lease.sh" release "${core_simulator_lease}" "$$"; then
    core_simulator_id=""
    core_simulator_lease=""
  else
    core_status=1
  fi
  return "${core_status}"
}

for story_index in "${!stories[@]}"; do
  story="${stories[${story_index}]}"
  story_output="${ios_dir}/DerivedData/E2E/${story}"
  rm -rf "${story_output}"
  story_start="${SECONDS}"
  skip_build=1
  if [[ "${story_index}" -eq 0 ]]; then skip_build=0; fi

  story_status=0
  PLAYER_E2E_PARALLEL_WORKERS=1 \
    PLAYER_E2E_BUILD_DATA="${shared_build_data}" \
    PLAYER_SKIP_E2E_BUILD="${skip_build}" \
    PLAYER_SKIP_E2E_ENVIRONMENT_VERIFICATION=1 \
    PLAYER_SKIP_PROJECT_GENERATION=1 \
    PLAYER_E2E_OUTPUT="${story_output}" \
    "${script_dir}/run-e2e.sh" --story "${story}" || story_status=$?

  printf '%s\t%s\t%s\t%s\n' \
    "${story}" "${story_start}" "${SECONDS}" "${story_status}" \
    >> "${shard_root}/StoryTimings.tsv"
  if [[ "${story_status}" -ne 0 ]]; then overall_status=1; fi

  if [[ "${story_index}" -eq 0 && "${run_core}" -eq 1 ]]; then
    if ! run_core_tests; then overall_status=1; fi
  fi
done

if [[ "${overall_status}" -ne 0 ]]; then
  echo "E2E shard ${shard_id} failed; retained per-story diagnostics." >&2
  exit "${overall_status}"
fi

echo "E2E shard ${shard_id} passed: ${stories[*]}"
