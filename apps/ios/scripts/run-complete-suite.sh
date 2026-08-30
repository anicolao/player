#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
story_manifest="${repository_root}/tests/e2e/manifest.json"
destination="${PLAYER_COMPLETE_SUITE_DESTINATION:-platform=iOS Simulator,arch=arm64,name=iPhone 17,OS=26.5}"
core_build_data="${ios_dir}/DerivedData/CompleteSuiteCore"

cd "${repository_root}"
"${script_dir}/verify-e2e-environment.sh"
"${script_dir}/verify-e2e-hygiene.sh"
project_snapshot="$(mktemp /tmp/player-project.XXXXXX)"
trap 'rm -f "${project_snapshot}"' EXIT
cp "${ios_dir}/Player.xcodeproj/project.pbxproj" "${project_snapshot}"
"${script_dir}/generate-project.sh"
cmp "${project_snapshot}" "${ios_dir}/Player.xcodeproj/project.pbxproj"

"${script_dir}/fixtures/verify-generated-fixtures.sh"
"${script_dir}/fixtures/verify-messy-multifile-fixture.sh"
"${script_dir}/fixtures/verify-zip-fixtures.sh"
"${script_dir}/fixtures/verify-import-channel-fixtures.sh"
"${script_dir}/fixtures/verify-metadata-repair-fixture.sh"
"${script_dir}/fixtures/verify-populated-library-fixture.sh"

xcodebuild -quiet \
  -project "${ios_dir}/Player.xcodeproj" \
  -scheme Player \
  -configuration E2E \
  -destination "${destination}" \
  -derivedDataPath "${core_build_data}" \
  -only-testing:PlayerTests \
  test \
  CODE_SIGNING_ALLOWED=NO
rm -rf "${core_build_data}"
mkdir -p "${ios_dir}/DerivedData/E2E"

run_story() {
  local story="$1"
  shift
  local story_output="${ios_dir}/DerivedData/E2E/${story}"
  rm -rf "${story_output}"
  PLAYER_SKIP_PROJECT_GENERATION=1 \
    PLAYER_E2E_OUTPUT="${story_output}" \
    "${script_dir}/run-e2e.sh" "${story}" "$@"
  # Retain the materialized reviewable walkthrough while bounding disk use
  # across all canonical isolated simulator builds.
  rm -rf "${story_output}/Build"
  rm -rf "${story_output}/Attachments"
  rm -rf "${story_output}/Results"
}

story_count="$(jq 'length' "${story_manifest}")"
for ((story_index = 0; story_index < story_count; story_index += 1)); do
  story="$(jq -r ".[${story_index}].story" "${story_manifest}")"
  selectors=()
  while IFS= read -r selector; do
    selectors+=("${selector}")
  done < <(jq -r ".[${story_index}].tests[]" "${story_manifest}")
  run_story "${story}" "${selectors[@]}"
done

echo "Complete Player suite passed: unit/integration tests and Stories 001-013."
