#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/../../.." && pwd)"
ui_test_root="${repository_root}/apps/ios/PlayerUITests"
manifest="${repository_root}/tests/e2e/manifest.json"
workflow="${repository_root}/.github/workflows/ios.yml"
qualification_workflow="${repository_root}/.github/workflows/r0-qualification.yml"

fail() {
  echo "E2E hygiene check failed: $*" >&2
  exit 1
}

jq -e '
  type == "array" and length > 0
  and all(.[]; (.story | test("^[0-9]{3}-[a-z0-9][a-z0-9-]*$")))
  and all(.[]; (.tests | type == "array" and length > 0))
  and ([.[].story] | length == (unique | length))
  and ([.[].tests[]] | length == (unique | length))
' "${manifest}" >/dev/null || fail "the canonical manifest is invalid or contains duplicates"

temporary_root="$(mktemp -d /tmp/player-e2e-hygiene.XXXXXX)"
trap 'rm -rf "${temporary_root}"' EXIT

"${script_dir}/tests/test-e2e-run-support.sh"
"${script_dir}/tests/test-simulator-lease.sh"

jq -r '.[].story' "${manifest}" | sort > "${temporary_root}/manifest-stories"
find "${repository_root}/tests/e2e" -mindepth 1 -maxdepth 1 -type d \
  -exec basename {} \; | sort > "${temporary_root}/story-directories"
cmp "${temporary_root}/manifest-stories" "${temporary_root}/story-directories" \
  || fail "story directories and the canonical manifest differ"

while IFS= read -r story; do
  story_root="${repository_root}/tests/e2e/${story}"
  story_description="${story_root}/story.json"
  [[ -f "${story_description}" ]] || fail "${story} is missing story.json"
  jq -e --arg story "${story}" \
    '.id == $story and .platform == "ios" and (.screenshots | type == "array" and length > 0)' \
    "${story_description}" >/dev/null || fail "${story}/story.json has an invalid identity or screenshot list"

  jq -r '[.test] + (.additionalTests // []) + (.nonvisualTests // []) | .[]' \
    "${story_description}" | sort > "${temporary_root}/${story}-description-tests"
  jq -r --arg story "${story}" '.[] | select(.story == $story) | .tests[]' \
    "${manifest}" | sort > "${temporary_root}/${story}-manifest-tests"
  cmp "${temporary_root}/${story}-description-tests" "${temporary_root}/${story}-manifest-tests" \
    || fail "${story}/story.json and the canonical selectors differ"

  jq -r '.screenshots[]' "${story_description}" | sort \
    > "${temporary_root}/${story}-described-images"
  find "${story_root}/screenshots/ios" -maxdepth 1 -type f -name '*.png' \
    -exec basename {} \; | sort > "${temporary_root}/${story}-committed-images"
  cmp "${temporary_root}/${story}-described-images" "${temporary_root}/${story}-committed-images" \
    || fail "${story}/story.json and committed screenshots differ"

  rg -o '\./screenshots/ios/[0-9]{3}-[A-Za-z0-9._-]+\.png' "${story_root}/README.md" \
    | sed 's#^\./screenshots/ios/##' | sort -u > "${temporary_root}/${story}-readme-images"
  cmp "${temporary_root}/${story}-committed-images" "${temporary_root}/${story}-readme-images" \
    || fail "${story}/README.md and committed screenshots differ"

  expected_index=0
  while IFS= read -r screenshot; do
    expected_prefix="$(printf '%03d-' "${expected_index}")"
    [[ "${screenshot}" == "${expected_prefix}"* ]] \
      || fail "${story} screenshot numbering is not contiguous at ${screenshot}"
    expected_index=$((expected_index + 1))
  done < "${temporary_root}/${story}-committed-images"
done < "${temporary_root}/manifest-stories"

jq -r '.[].tests[]' "${manifest}" | sort > "${temporary_root}/manifest-tests"
: > "${temporary_root}/source-tests"
while IFS= read -r source_file; do
  test_class="$(basename "${source_file}" .swift)"
  while IFS= read -r test_method; do
    printf 'PlayerUITests/%s/%s\n' "${test_class}" "${test_method#func }" \
      >> "${temporary_root}/source-tests"
  done < <(rg -o '^[[:space:]]*func test[A-Za-z0-9_]+' "${source_file}" \
    | sed -E 's/^[[:space:]]+//')
done < <(find "${ui_test_root}" -maxdepth 1 -name '*UITests.swift' -type f | sort)
sort -o "${temporary_root}/source-tests" "${temporary_root}/source-tests"
cmp "${temporary_root}/manifest-tests" "${temporary_root}/source-tests" \
  || fail "every UI test method must appear exactly once in the canonical manifest"

rg -o 'story_[1-3]: [0-9]{3}-[a-z0-9][a-z0-9-]*' "${workflow}" \
  | sed 's/^story_[1-3]: //' | sort > "${temporary_root}/workflow-stories"
cmp "${temporary_root}/manifest-stories" "${temporary_root}/workflow-stories" \
  || fail "every canonical story must appear exactly once in the CI shards"

rg -o 'shard: [a-z0-9][a-z0-9-]*' "${workflow}" \
  | sed 's/^shard: //' | sort > "${temporary_root}/workflow-shards"
[[ "$(wc -l < "${temporary_root}/workflow-shards" | tr -d ' ')" -eq 5 ]] \
  || fail "CI must define exactly five macOS shards"
[[ "$(sort -u "${temporary_root}/workflow-shards" | wc -l | tr -d ' ')" -eq 5 ]] \
  || fail "CI shard identifiers must be unique"
[[ "$(rg -c 'run_core: true' "${workflow}")" -eq 1 ]] \
  || fail "core and fixture tests must run in exactly one CI shard"
[[ "$(rg -c 'PLAYER_E2E_PARALLEL_WORKERS: "1"' "${workflow}")" -eq 1 ]] \
  || fail "CI must keep UI test classes serial within each macOS shard"
rg -q '^[[:space:]]*PLAYER_E2E_PARALLEL_WORKERS=1' \
  "${script_dir}/run-e2e-shard.sh" \
  || fail "the shard runner must keep UI test classes serial"

if rg -q 'PlayerUITests/[A-Za-z0-9_]+/test[A-Za-z0-9_]+' "${workflow}"; then
  fail "CI must derive selectors from the canonical manifest instead of duplicating them"
fi

if rg -n --pcre2 '\b(?:sleep|usleep)\s*\(|DispatchQueue\.[^\n]*asyncAfter|Task\.sleep' \
  "${ui_test_root}" --glob '*.swift'; then
  fail "fixed sleeps are forbidden in UI tests"
fi

if rg -n --pcre2 'timeout:\s*(?:[3-9]|[1-9][0-9]+)(?:\.0+)?\b' \
  "${ui_test_root}" --glob '*.swift'; then
  fail "UI-test transition timeouts may not exceed two seconds"
fi

if rg -n 'continue-on-error:|nick-fields/retry|retry-action' "${workflow}"; then
  fail "CI may not hide an E2E failure behind a retry"
fi

[[ -f "${qualification_workflow}" ]] || fail "the manual R0 qualification workflow is missing"
{
  cat "${temporary_root}/manifest-stories"
  cat "${temporary_root}/manifest-stories"
} | sort > "${temporary_root}/qualification-expected-stories"
rg -o '[0-9]{3}-[a-z0-9][a-z0-9-]*' "${qualification_workflow}" \
  | sort > "${temporary_root}/qualification-workflow-stories"
cmp "${temporary_root}/qualification-expected-stories" \
  "${temporary_root}/qualification-workflow-stories" \
  || fail "R0 qualification must assign every canonical story once in each phase"
[[ "$(rg -c 'arguments=.*--attempts 10' "${qualification_workflow}")" -eq 1 ]] \
  || fail "R0 story qualification must request exactly ten attempts"
[[ "$(rg -c 'matrices 5' "${qualification_workflow}")" -eq 1 ]] \
  || fail "R0 matrix qualification must request exactly five matrices"
if rg -n 'continue-on-error:|nick-fields/retry|retry-action' "${qualification_workflow}"; then
  fail "R0 qualification may not retry or waive a failed measurement"
fi

if CI=true "${script_dir}/run-e2e.sh" --story 001-ios-launch \
  --test PlayerUITests/LaunchUITests/testLaunchesIntoEmptyLibrary \
  --record 001-ios-launch >"${temporary_root}/recording-check.log" 2>&1; then
  fail "recording mode must be rejected in CI"
fi
rg -q 'may never be recorded in CI' "${temporary_root}/recording-check.log" \
  || fail "CI recording rejection did not report its reason"

if CI= GITHUB_ACTIONS= "${script_dir}/run-e2e.sh" --story 001-ios-launch \
  --test PlayerUITests/LaunchUITests/testLaunchesIntoEmptyLibrary \
  --record 001-ios-launch >"${temporary_root}/partial-recording-check.log" 2>&1; then
  fail "recording a selector subset must be rejected"
fi
rg -q 'complete canonical selector set' "${temporary_root}/partial-recording-check.log" \
  || fail "partial recording rejection did not report its reason"

if PLAYER_RECORD_STORY=001-ios-launch "${script_dir}/run-e2e.sh" \
  --story 001-ios-launch >"${temporary_root}/environment-recording-check.log" 2>&1; then
  fail "an environment variable must not silently enable recording"
fi
rg -q 'PLAYER_RECORD_STORY is no longer accepted' \
  "${temporary_root}/environment-recording-check.log" \
  || fail "environment recording rejection did not report its reason"

walkthrough_fixture="${temporary_root}/walkthrough-fixture"
mkdir -p "${walkthrough_fixture}/attachments-a" "${walkthrough_fixture}/attachments-b"
printf '# Test: Later fragment\n\n![Later](./screenshots/ios/002-later.png)\n' \
  > "${walkthrough_fixture}/attachments-a/later.txt"
printf '# Test: Earlier fragment\n\n![First](./screenshots/ios/000-first.png)\n\n![Second](./screenshots/ios/001-second.png)\n' \
  > "${walkthrough_fixture}/attachments-a/earlier.txt"
: > "${walkthrough_fixture}/attachments-a/000.png"
: > "${walkthrough_fixture}/attachments-a/001.png"
: > "${walkthrough_fixture}/attachments-a/002.png"
jq -n '
  [
    {
      testIdentifier: "LaterUITests/testLater()",
      attachments: [
        {suggestedHumanReadableName: "README.md", exportedFileName: "later.txt"},
        {suggestedHumanReadableName: "002-later.png", exportedFileName: "002.png"}
      ]
    },
    {
      testIdentifier: "EarlierUITests/testEarlier()",
      attachments: [
        {suggestedHumanReadableName: "001-second.png", exportedFileName: "001.png"},
        {suggestedHumanReadableName: "README.md", exportedFileName: "earlier.txt"},
        {suggestedHumanReadableName: "000-first.png", exportedFileName: "000.png"}
      ]
    }
  ]
' > "${walkthrough_fixture}/attachments-a/manifest.json"
cp -R "${walkthrough_fixture}/attachments-a/." "${walkthrough_fixture}/attachments-b/"
jq 'map(.attachments |= reverse) | reverse' \
  "${walkthrough_fixture}/attachments-a/manifest.json" \
  > "${walkthrough_fixture}/attachments-b/manifest.json"

"${script_dir}/export-walkthrough.sh" \
  "${walkthrough_fixture}/attachments-a" "${walkthrough_fixture}/walkthrough-a" \
  > "${walkthrough_fixture}/export-a.log"
"${script_dir}/export-walkthrough.sh" \
  "${walkthrough_fixture}/attachments-b" "${walkthrough_fixture}/walkthrough-b" \
  > "${walkthrough_fixture}/export-b.log"
cmp "${walkthrough_fixture}/walkthrough-a/README.md" \
  "${walkthrough_fixture}/walkthrough-b/README.md" \
  || fail "walkthrough README order depends on attachment-export order"
printf '# Test: Earlier fragment\n# Test: Later fragment\n' \
  > "${walkthrough_fixture}/expected-headings"
rg '^# Test:' "${walkthrough_fixture}/walkthrough-a/README.md" \
  > "${walkthrough_fixture}/actual-headings"
cmp "${walkthrough_fixture}/expected-headings" "${walkthrough_fixture}/actual-headings" \
  || fail "walkthrough README fragments are not ordered by screenshot number"

"${script_dir}/compare-walkthrough-readme.sh" \
  "${walkthrough_fixture}/walkthrough-a/README.md" \
  "${walkthrough_fixture}/walkthrough-b/README.md" \
  "${walkthrough_fixture}/matching-diagnostics" \
  > "${walkthrough_fixture}/matching-comparison.log"
sed 's/^# Test:/# Changed Test:/' "${walkthrough_fixture}/walkthrough-b/README.md" \
  > "${walkthrough_fixture}/changed-README.md"
if "${script_dir}/compare-walkthrough-readme.sh" \
  "${walkthrough_fixture}/walkthrough-a/README.md" \
  "${walkthrough_fixture}/changed-README.md" \
  "${walkthrough_fixture}/mismatch-diagnostics" \
  > "${walkthrough_fixture}/mismatch-comparison.log" 2>&1; then
  fail "walkthrough README comparison accepted changed documentation"
fi
[[ -s "${walkthrough_fixture}/mismatch-diagnostics/README.diff" ]] \
  || fail "walkthrough README comparison did not retain a unified diff"

echo "E2E hygiene passed: manifest, shards, waits, retries, recording guard, and walkthrough docs."
