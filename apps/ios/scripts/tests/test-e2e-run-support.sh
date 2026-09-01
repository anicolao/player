#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_scripts="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_scripts}/../../.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/player-e2e-support.XXXXXX")"
trap 'rm -rf "${temporary_root}"' EXIT

fail() {
  echo "E2E run-support test failed: $*" >&2
  exit 1
}

assert_prepares_output_parent() {
  local caller="$1"
  local preparation="$2"
  local invocation="$3"
  local label="$4"
  local preparation_line
  local invocation_line

  preparation_line="$(rg -n -F -m 1 -- "${preparation}" "${caller}" | cut -d: -f1 || true)"
  [[ -n "${preparation_line}" ]] || fail "${label} does not prepare the E2E output parent"
  invocation_line="$(rg -n -F -m 1 -- "${invocation}" "${caller}" | cut -d: -f1 || true)"
  [[ -n "${invocation_line}" ]] || fail "${label} does not invoke the E2E runner"
  (( preparation_line < invocation_line )) \
    || fail "${label} prepares the E2E output parent after invoking the runner"
}

fake_ios="${temporary_root}/ios"
mkdir -p "${fake_ios}"
first_output="$("${ios_scripts}/prepare-e2e-output.sh" "${fake_ios}" 001-ios-launch)"
second_output="$("${ios_scripts}/prepare-e2e-output.sh" "${fake_ios}" 001-ios-launch)"
[[ "${first_output}" != "${second_output}" ]] || fail "same-story defaults collided"
[[ -d "${first_output}" && -d "${second_output}" ]] || fail "default outputs were not created"

explicit_parent="${temporary_root}/explicit"
mkdir -p "${explicit_parent}"
explicit_output="${explicit_parent}/attempt-01"
[[ "$("${ios_scripts}/prepare-e2e-output.sh" "${fake_ios}" 001-ios-launch "${explicit_output}")" == "${explicit_output}" ]] \
  || fail "explicit output was not returned"
[[ -d "${explicit_output}" ]] || fail "explicit output was not atomically reserved"
if "${ios_scripts}/prepare-e2e-output.sh" "${fake_ios}" 001-ios-launch "${explicit_output}" >/dev/null 2>&1; then
  fail "an existing explicit output was accepted"
fi
if "${ios_scripts}/prepare-e2e-output.sh" "${fake_ios}" 001-ios-launch relative/output >/dev/null 2>&1; then
  fail "a relative explicit output was accepted"
fi
ln -s "${first_output}" "${explicit_parent}/linked-output"
if "${ios_scripts}/prepare-e2e-output.sh" "${fake_ios}" 001-ios-launch "${explicit_parent}/linked-output" >/dev/null 2>&1; then
  fail "a symlink explicit output was accepted"
fi

# Explicit output allocation deliberately rejects a missing parent. Keep every
# repository-owned orchestrator responsible for preparing that parent before it
# delegates to run-e2e.sh; this check is static so it cannot invoke Xcode.
assert_prepares_output_parent \
  "${ios_scripts}/run-e2e-shard.sh" \
  'mkdir -p "${ios_dir}/DerivedData/E2E"' \
  '"${script_dir}/run-e2e.sh"' \
  'the shard runner'
assert_prepares_output_parent \
  "${ios_scripts}/run-complete-suite.sh" \
  'mkdir -p "${ios_dir}/DerivedData/E2E"' \
  '"${script_dir}/run-e2e.sh"' \
  'the complete-suite runner'
assert_prepares_output_parent \
  "${repository_root}/scripts/capture-marketing-screenshots" \
  'mkdir -p "$(dirname "${story_output}")"' \
  'apps/ios/scripts/run-e2e.sh' \
  'the marketing screenshot runner'

fake_repository="${temporary_root}/repository"
mkdir -p \
  "${fake_repository}/apps/ios/Player" \
  "${fake_repository}/apps/ios/ShareExtension" \
  "${fake_repository}/apps/ios/PlayerTests" \
  "${fake_repository}/apps/ios/PlayerUITests" \
  "${fake_repository}/apps/ios/Config" \
  "${fake_repository}/apps/ios/Player.xcodeproj" \
  "${fake_repository}/apps/ios/scripts" \
  "${fake_repository}/fake-bin" \
  "${fake_repository}/Build/Build/Products"
cp "${ios_scripts}/e2e-build-provenance.sh" "${fake_repository}/apps/ios/scripts/"
printf 'app\n' > "${fake_repository}/apps/ios/Player/App.swift"
printf 'extension\n' > "${fake_repository}/apps/ios/ShareExtension/Share.swift"
printf 'tests\n' > "${fake_repository}/apps/ios/PlayerTests/Tests.swift"
printf 'ui tests\n' > "${fake_repository}/apps/ios/PlayerUITests/UITests.swift"
printf 'config\n' > "${fake_repository}/apps/ios/Config/E2E.xcconfig"
printf 'project spec\n' > "${fake_repository}/apps/ios/project.yml"
printf 'generated project\n' > "${fake_repository}/apps/ios/Player.xcodeproj/project.pbxproj"
printf 'xctestrun\n' > "${fake_repository}/Build/Build/Products/Player.xctestrun"
printf 'Xcode 26.6\nBuild version 17G86\n' > "${fake_repository}/toolchain-version"
printf '26.5\n' > "${fake_repository}/sdk-version"
printf '23F80\n' > "${fake_repository}/sdk-build"

printf '#!/usr/bin/env bash\ncat "${PLAYER_TEST_TOOLCHAIN_VERSION}"\n' \
  > "${fake_repository}/fake-bin/xcodebuild"
printf '#!/usr/bin/env bash\ncase "$*" in *--show-sdk-version) cat "${PLAYER_TEST_SDK_VERSION}" ;; *--show-sdk-build-version) cat "${PLAYER_TEST_SDK_BUILD}" ;; *) exit 2 ;; esac\n' \
  > "${fake_repository}/fake-bin/xcrun"
chmod +x "${fake_repository}/fake-bin/xcodebuild" "${fake_repository}/fake-bin/xcrun"
git -C "${fake_repository}" init -q
git -C "${fake_repository}" config user.email e2e@example.invalid
git -C "${fake_repository}" config user.name 'E2E Test'
git -C "${fake_repository}" add apps
git -C "${fake_repository}" commit -qm initial

provenance="${fake_repository}/apps/ios/scripts/e2e-build-provenance.sh"
provenance_env=(
  "PATH=${fake_repository}/fake-bin:${PATH}"
  "DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer"
  "PLAYER_TEST_TOOLCHAIN_VERSION=${fake_repository}/toolchain-version"
  "PLAYER_TEST_SDK_VERSION=${fake_repository}/sdk-version"
  "PLAYER_TEST_SDK_BUILD=${fake_repository}/sdk-build"
)
env "${provenance_env[@]}" "${provenance}" write "${fake_repository}/Build" iPhone-17 iOS-26-5
env "${provenance_env[@]}" "${provenance}" verify "${fake_repository}/Build" iPhone-17 iOS-26-5

relocated_repository="${temporary_root}/relocated-repository"
git clone -q "${fake_repository}" "${relocated_repository}"
cp -R "${fake_repository}/Build" "${relocated_repository}/Build"
env "${provenance_env[@]}" \
  "${relocated_repository}/apps/ios/scripts/e2e-build-provenance.sh" verify \
  "${relocated_repository}/Build" iPhone-17 iOS-26-5

assert_rejected() {
  local device="$1"
  local runtime="$2"
  local label="$3"
  if env "${provenance_env[@]}" "${provenance}" verify \
    "${fake_repository}/Build" "${device}" "${runtime}" >/dev/null 2>&1; then
    fail "${label} was accepted"
  fi
}

printf 'dirty app\n' >> "${fake_repository}/apps/ios/Player/App.swift"
assert_rejected iPhone-17 iOS-26-5 source-mutation
git -C "${fake_repository}" checkout -q -- apps/ios/Player/App.swift
printf 'changed generated project\n' >> "${fake_repository}/apps/ios/Player.xcodeproj/project.pbxproj"
assert_rejected iPhone-17 iOS-26-5 project-mutation
git -C "${fake_repository}" checkout -q -- apps/ios/Player.xcodeproj/project.pbxproj
assert_rejected iPhone-17 iOS-26-6 runtime-mutation
printf 'Xcode 26.7\nBuild version 17H1\n' > "${fake_repository}/toolchain-version"
assert_rejected iPhone-17 iOS-26-5 toolchain-mutation
printf 'Xcode 26.6\nBuild version 17G86\n' > "${fake_repository}/toolchain-version"
printf '26.6\n' > "${fake_repository}/sdk-version"
assert_rejected iPhone-17 iOS-26-5 sdk-mutation
printf '26.5\n' > "${fake_repository}/sdk-version"
printf 'changed xctestrun\n' >> "${fake_repository}/Build/Build/Products/Player.xctestrun"
assert_rejected iPhone-17 iOS-26-5 xctestrun-mutation
printf 'xctestrun\n' > "${fake_repository}/Build/Build/Products/Player.xctestrun"
mv \
  "${fake_repository}/Build/PlayerE2EBuildProvenance.json" \
  "${fake_repository}/Build/PlayerE2EBuildProvenance.saved"
assert_rejected iPhone-17 iOS-26-5 missing-manifest

comparison_binary="${temporary_root}/compare-walkthrough"
swiftc "${ios_scripts}/compare-walkthrough.swift" -o "${comparison_binary}"
reference_screenshot="${repository_root}/tests/e2e/007-sleep-timer/screenshots/ios/000-persisted-active-sleep-timer.png"
different_screenshot="${repository_root}/tests/e2e/007-sleep-timer/screenshots/ios/001-sleep-stop-resume-context.png"
[[ -f "${reference_screenshot}" ]] || fail "the comparison fixture screenshot is missing"
[[ -f "${different_screenshot}" ]] || fail "the different comparison fixture is missing"

missing_root="${temporary_root}/missing-actual"
mkdir -p "${missing_root}/expected" "${missing_root}/actual"
cp "${reference_screenshot}" "${missing_root}/expected/000-screen.png"
if "${comparison_binary}" \
  "${missing_root}/expected" "${missing_root}/actual" "${missing_root}/diagnostics" \
  --retain-all-evidence >"${missing_root}/comparison.log" 2>&1; then
  fail "a missing actual screenshot was accepted"
fi
jq -e '
  .failureCount == 1
  and .fileSetMatches == false
  and .expectedNames == ["000-screen.png"]
  and .actualNames == []
  and .images == [{
    name: "000-screen.png",
    result: "missing-actual",
    expectedArtifact: "000-screen-expected.png",
    actualArtifact: "000-screen-actual-missing.txt",
    diffArtifact: "000-screen-diff-unavailable.txt"
  }]
' "${missing_root}/diagnostics/summary.json" >/dev/null \
  || fail "missing-actual diagnostics are incomplete"
[[ -f "${missing_root}/diagnostics/000-screen-expected.png" ]] \
  || fail "missing-actual diagnostics omitted the reviewed image"
[[ -s "${missing_root}/diagnostics/000-screen-actual-missing.txt" ]] \
  || fail "missing-actual diagnostics omitted the actual placeholder"
[[ -s "${missing_root}/diagnostics/000-screen-diff-unavailable.txt" ]] \
  || fail "missing-actual diagnostics omitted the diff placeholder"

retained_match_root="${temporary_root}/retained-match"
mkdir -p "${retained_match_root}/expected" "${retained_match_root}/actual"
cp "${reference_screenshot}" "${retained_match_root}/expected/000-screen.png"
cp "${reference_screenshot}" "${retained_match_root}/actual/000-screen.png"
"${comparison_binary}" \
  "${retained_match_root}/expected" "${retained_match_root}/actual" \
  "${retained_match_root}/diagnostics" --retain-all-evidence \
  >"${retained_match_root}/comparison.log" 2>&1 \
  || fail "matching screenshots were rejected while retaining failure evidence"
jq -e '
  .failureCount == 0
  and .fileSetMatches == true
  and .images[0].result == "exact"
  and .images[0].expectedArtifact == "000-screen-expected.png"
  and .images[0].actualArtifact == "000-screen-actual.png"
  and .images[0].diffArtifact == "not-required"
' "${retained_match_root}/diagnostics/summary.json" >/dev/null \
  || fail "matching failure evidence did not retain both reviewed and actual screenshots"
[[ -f "${retained_match_root}/diagnostics/000-screen-expected.png" \
  && -f "${retained_match_root}/diagnostics/000-screen-actual.png" ]] \
  || fail "matching failure evidence omitted reviewed or actual screenshots"

pixel_root="${temporary_root}/pixel"
mkdir -p "${pixel_root}/expected" "${pixel_root}/actual"
cp "${reference_screenshot}" "${pixel_root}/expected/000-screen.png"
cp "${different_screenshot}" "${pixel_root}/actual/000-screen.png"
if "${comparison_binary}" \
  "${pixel_root}/expected" "${pixel_root}/actual" "${pixel_root}/diagnostics" \
  >"${pixel_root}/comparison.log" 2>&1; then
  fail "a real pixel difference was accepted"
fi
jq -e '
  .failureCount == 1
  and .fileSetMatches == true
  and .images[0].result == "pixel-difference"
  and .images[0].expectedArtifact == "000-screen-expected.png"
  and .images[0].actualArtifact == "000-screen-actual.png"
  and .images[0].diffArtifact == "000-screen-diff.png"
' "${pixel_root}/diagnostics/summary.json" >/dev/null \
  || fail "pixel-difference diagnostics are incomplete"
[[ -f "${pixel_root}/diagnostics/000-screen-expected.png" \
  && -f "${pixel_root}/diagnostics/000-screen-actual.png" \
  && -f "${pixel_root}/diagnostics/000-screen-diff.png" ]] \
  || fail "pixel-difference diagnostics omitted expected, actual, or diff images"

qualified_root="${temporary_root}/qualified-system-region"
mkdir -p "${qualified_root}/expected" "${qualified_root}/actual"
cp "${reference_screenshot}" "${qualified_root}/expected/000-screen.png"
cp "${different_screenshot}" "${qualified_root}/actual/000-screen.png"
cp \
  "${repository_root}/tests/e2e/009-accessible-core-journeys/screenshots/ios/comparison-policy.json" \
  "${qualified_root}/expected/comparison-policy-source.json"
sed \
  -e 's/002-large-text-book-detail.png/000-screen.png/' \
  -e 's/"height": 303/"height": 2622/' \
  -e 's/"y": 2319/"y": 0/' \
  "${qualified_root}/expected/comparison-policy-source.json" \
  > "${qualified_root}/expected/comparison-policy.json"
rm "${qualified_root}/expected/comparison-policy-source.json"
"${comparison_binary}" \
  "${qualified_root}/expected" "${qualified_root}/actual" \
  "${qualified_root}/diagnostics" \
  >"${qualified_root}/comparison.log" 2>&1 \
  || fail "a difference confined to a reviewed system-owned region was rejected"
jq -e '
  .failureCount == 0
  and .images[0].result == "canonical"
  and .images[0].qualifiedSystemPixelCount > 0
' "${qualified_root}/diagnostics/summary.json" >/dev/null \
  || fail "qualified system-region diagnostics did not identify the confined pixels"

outside_root="${temporary_root}/outside-qualified-region"
mkdir -p "${outside_root}/expected" "${outside_root}/actual"
cp "${reference_screenshot}" "${outside_root}/expected/000-screen.png"
cp "${different_screenshot}" "${outside_root}/actual/000-screen.png"
sed \
  -e 's/002-large-text-book-detail.png/000-screen.png/' \
  -e 's/"height": 303/"height": 1/' \
  -e 's/"width": 1206/"width": 1/' \
  -e 's/"y": 2319/"y": 0/' \
  "${repository_root}/tests/e2e/009-accessible-core-journeys/screenshots/ios/comparison-policy.json" \
  > "${outside_root}/expected/comparison-policy.json"
if "${comparison_binary}" \
  "${outside_root}/expected" "${outside_root}/actual" "${outside_root}/diagnostics" \
  >"${outside_root}/comparison.log" 2>&1; then
  fail "a pixel difference outside a reviewed system-owned region was accepted"
fi
jq -e '
  .failureCount == 1
  and .images[0].result == "pixel-difference"
  and .images[0].pixelCount > 0
' "${outside_root}/diagnostics/summary.json" >/dev/null \
  || fail "outside-region diagnostics did not retain the unqualified pixel failure"

file_set_root="${temporary_root}/file-set"
mkdir -p "${file_set_root}/expected" "${file_set_root}/actual"
cp "${reference_screenshot}" "${file_set_root}/expected/000-expected-only.png"
cp "${reference_screenshot}" "${file_set_root}/actual/001-actual-only.png"
if "${comparison_binary}" \
  "${file_set_root}/expected" "${file_set_root}/actual" "${file_set_root}/diagnostics" \
  >"${file_set_root}/comparison.log" 2>&1; then
  fail "different screenshot file sets were accepted"
fi
jq -e '
  .failureCount == 2
  and .fileSetMatches == false
  and ([.images[].result] | sort) == ["missing-actual", "unexpected-actual"]
  and all(.images[]; .expectedArtifact and .actualArtifact and .diffArtifact)
' "${file_set_root}/diagnostics/summary.json" >/dev/null \
  || fail "file-set diagnostics are incomplete"
[[ -f "${file_set_root}/diagnostics/000-expected-only-expected.png" ]] \
  || fail "file-set diagnostics omitted the reviewed image"
[[ -f "${file_set_root}/diagnostics/001-actual-only-actual.png" ]] \
  || fail "file-set diagnostics omitted the unexpected actual image"
[[ -s "${file_set_root}/diagnostics/000-expected-only-diff-unavailable.txt" \
  && -s "${file_set_root}/diagnostics/001-actual-only-diff-unavailable.txt" ]] \
  || fail "file-set diagnostics omitted an explicit diff placeholder"

dimension_root="${temporary_root}/dimension"
mkdir -p "${dimension_root}/expected" "${dimension_root}/actual"
cp "${reference_screenshot}" "${dimension_root}/expected/000-screen.png"
sips --resampleHeightWidth 64 32 "${reference_screenshot}" \
  --out "${dimension_root}/actual/000-screen.png" >/dev/null
if "${comparison_binary}" \
  "${dimension_root}/expected" "${dimension_root}/actual" "${dimension_root}/diagnostics" \
  >"${dimension_root}/comparison.log" 2>&1; then
  fail "different screenshot dimensions were accepted"
fi
jq -e '
  .failureCount == 1
  and .fileSetMatches == true
  and .images[0].result == "dimension-difference"
  and .images[0].expectedArtifact == "000-screen-expected.png"
  and .images[0].actualArtifact == "000-screen-actual.png"
  and .images[0].diffArtifact == "000-screen-diff-unavailable.txt"
' "${dimension_root}/diagnostics/summary.json" >/dev/null \
  || fail "dimension diagnostics are incomplete"
[[ -f "${dimension_root}/diagnostics/000-screen-expected.png" \
  && -f "${dimension_root}/diagnostics/000-screen-actual.png" \
  && -s "${dimension_root}/diagnostics/000-screen-diff-unavailable.txt" ]] \
  || fail "dimension diagnostics omitted expected, actual, or diff-placeholder evidence"

unreadable_root="${temporary_root}/unreadable"
mkdir -p "${unreadable_root}/expected" "${unreadable_root}/actual"
cp "${reference_screenshot}" "${unreadable_root}/expected/000-screen.png"
printf 'not a png\n' > "${unreadable_root}/actual/000-screen.png"
if "${comparison_binary}" \
  "${unreadable_root}/expected" "${unreadable_root}/actual" "${unreadable_root}/diagnostics" \
  >"${unreadable_root}/comparison.log" 2>&1; then
  fail "an unreadable actual screenshot was accepted"
fi
jq -e '
  .failureCount == 1
  and .images[0].result == "image-unreadable"
  and (.images[0].errors | length) == 1
  and .images[0].expectedArtifact == "000-screen-expected.png"
  and .images[0].actualArtifact == "000-screen-actual.png"
  and .images[0].diffArtifact == "000-screen-diff-unavailable.txt"
' "${unreadable_root}/diagnostics/summary.json" >/dev/null \
  || fail "unreadable-image diagnostics are incomplete"
[[ -f "${unreadable_root}/diagnostics/000-screen-expected.png" \
  && -f "${unreadable_root}/diagnostics/000-screen-actual.png" \
  && -s "${unreadable_root}/diagnostics/000-screen-diff-unavailable.txt" ]] \
  || fail "unreadable-image diagnostics omitted source files or the diff placeholder"

run_e2e="${ios_scripts}/run-e2e.sh"
target_install_line="$(rg -n -m 1 'run_logged_phase target-install' "${run_e2e}" | cut -d: -f1)"
target_hide_line="$(rg -n -m 1 'run_logged_phase target-source-hiding' "${run_e2e}" | cut -d: -f1)"
test_phase_line="$(rg -n -m 1 'run_logged_phase test xcodebuild test-without-building' "${run_e2e}" | cut -d: -f1)"
[[ -n "${target_install_line}" && -n "${target_hide_line}" && -n "${test_phase_line}" \
  && "${target_install_line}" -lt "${target_hide_line}" \
  && "${target_hide_line}" -lt "${test_phase_line}" ]] \
  || fail "the exact target application is not installed before XCTest launch"
rg -Fq 'target_application="${build_data}/Build/Products/E2E-iphonesimulator/Player.app"' "${run_e2e}" \
  || fail "target preinstallation is not bound to the exact E2E build product"
rg -Fq 'test_runner_application="${build_data}/Build/Products/E2E-iphonesimulator/PlayerUITests-Runner.app"' "${run_e2e}" \
  || fail "test-runner preinstallation is not bound to the exact E2E build product"
rg -Fq 'XCUIApplication(bundleIdentifier: "com.spnss.player")' \
  "${repository_root}/apps/ios/PlayerUITests/TestStepHelper.swift" \
  || fail "Bookshelf UI tests are not bound to the explicitly preinstalled application"
if rg -n 'XCUIApplication\(\)' \
  "${repository_root}/apps/ios/PlayerUITests" --glob '*.swift'; then
  fail "a UI test still requests Xcode's deferred target-application installation"
fi
project_spec="${repository_root}/apps/ios/project.yml"
generated_project="${repository_root}/apps/ios/Player.xcodeproj/project.pbxproj"
if rg -n 'TEST_TARGET_NAME' "${project_spec}" "${generated_project}"; then
  fail "the UI-test bundle still lets Xcode reinstall the target application during test-without-building"
fi
rg -Fq "Installed app at path:" "${run_e2e}" \
  || fail "the E2E harness does not reject an Xcode-managed target reinstall"
rg -Fq 'restore_hidden_target_application' "${run_e2e}" \
  || fail "the immutable target source is not restored after XCTest"
rg -Fq '        Player: all' "${project_spec}" \
  || fail "the Player scheme no longer builds the target application"
rg -Fq '        PlayerUITests: [test]' "${project_spec}" \
  || fail "the Player scheme no longer builds the UI-test bundle"
runner_install_line="$(rg -F -n -m 1 'xcrun simctl install "${simulator}" "${test_runner}"' "${run_e2e}" | cut -d: -f1)"
runner_receipt_line="$(rg -F -n -m 1 'xcrun simctl launch --terminate-running-process' "${run_e2e}" | cut -d: -f1)"
[[ -n "${runner_install_line}" && -n "${runner_receipt_line}" \
  && "${runner_install_line}" -lt "${runner_receipt_line}" \
  && "${runner_receipt_line}" -lt "${test_phase_line}" ]] \
  || fail "the exact test runner lacks a FrontBoard registration receipt before XCTest launch"
reset_line="$(rg -n -m 1 'run_logged_phase simulator-control-plane-reset' "${run_e2e}" | cut -d: -f1)"
lease_line="$(rg -n -F -m 1 'simulator_lease="${simulator_lease_root}/story-' "${run_e2e}" | cut -d: -f1)"
[[ -n "${reset_line}" && -n "${lease_line}" && "${reset_line}" -lt "${lease_line}" ]] \
  || fail "the hosted simulator control plane is not reset before the next exact lease"
first_boot_receipt_line="$(rg -n -F -m 1 'xcrun simctl bootstatus "${simulator_id}" -b' "${run_e2e}" | cut -d: -f1)"
configuration_line="$(rg -n -F -m 1 'xcrun simctl ui "${simulator_id}" content_size "${expected_content_size}"' "${run_e2e}" | cut -d: -f1)"
final_configuration_line="$(rg -n -F 'xcrun simctl ui "${simulator_id}" content_size "${expected_content_size}"' "${run_e2e}" | sed -n '2p' | cut -d: -f1)"
final_contrast_line="$(rg -n -F 'xcrun simctl ui "${simulator_id}" increase_contrast "${expected_increase_contrast}"' "${run_e2e}" | sed -n '2p' | cut -d: -f1)"
chronod_disable_line="$(rg -n -F -m 1 'xcrun simctl spawn "${simulator_id}" launchctl disable "${chronod_service}"' "${run_e2e}" | cut -d: -f1)"
first_disabled_receipt_line="$(rg -n -F -m 1 'xcrun simctl spawn "${simulator_id}" launchctl print-disabled user/501' "${run_e2e}" | cut -d: -f1)"
stabilization_shutdown_line="$(rg -n -F -m 1 'xcrun simctl shutdown "${simulator_id}"' "${run_e2e}" | cut -d: -f1)"
second_boot_receipt_line="$(rg -n -F 'xcrun simctl bootstatus "${simulator_id}" -b' "${run_e2e}" | sed -n '2p' | cut -d: -f1)"
configuration_receipt_line="$(rg -n -F -m 1 '[[ "$(xcrun simctl ui "${simulator_id}" content_size)" == "${expected_content_size}" ]]' "${run_e2e}" | cut -d: -f1)"
second_disabled_receipt_line="$(rg -n -F 'xcrun simctl spawn "${simulator_id}" launchctl print-disabled user/501' "${run_e2e}" | sed -n '2p' | cut -d: -f1)"
chronod_rejection_line="$(rg -n -F -m 1 'if xcrun simctl spawn "${simulator_id}" launchctl print "${chronod_service}"' "${run_e2e}" | cut -d: -f1)"
[[ -n "${first_boot_receipt_line}" && -n "${configuration_line}" \
  && -n "${final_configuration_line}" && -n "${final_contrast_line}" \
  && -n "${chronod_disable_line}" && -n "${first_disabled_receipt_line}" \
  && -n "${stabilization_shutdown_line}" && -n "${second_boot_receipt_line}" \
  && -n "${configuration_receipt_line}" && -n "${second_disabled_receipt_line}" \
  && -n "${chronod_rejection_line}" \
  && "${first_boot_receipt_line}" -lt "${configuration_line}" \
  && "${configuration_line}" -lt "${chronod_disable_line}" \
  && "${chronod_disable_line}" -lt "${first_disabled_receipt_line}" \
  && "${first_disabled_receipt_line}" -lt "${stabilization_shutdown_line}" \
  && "${stabilization_shutdown_line}" -lt "${second_boot_receipt_line}" \
  && "${second_boot_receipt_line}" -lt "${final_configuration_line}" \
  && "${final_configuration_line}" -lt "${final_contrast_line}" \
  && "${final_contrast_line}" -lt "${configuration_receipt_line}" \
  && "${configuration_receipt_line}" -lt "${second_disabled_receipt_line}" \
  && "${second_disabled_receipt_line}" -lt "${chronod_rejection_line}" \
  && "${chronod_rejection_line}" -lt "${target_install_line}" ]] \
  || fail "the fresh simulator does not isolate widget scheduling across its clean-boot boundary"
[[ "$(rg -F -c 'xcrun simctl ui "${simulator_id}" content_size "${expected_content_size}"' "${run_e2e}")" == 2 \
  && "$(rg -F -c 'xcrun simctl ui "${simulator_id}" increase_contrast "${expected_increase_contrast}"' "${run_e2e}")" == 2 ]] \
  || fail "the exact accessibility configuration is not asserted in both boot epochs"
[[ "$(rg -F -c 'xcrun simctl spawn "${simulator_id}" launchctl print-disabled user/501' "${run_e2e}")" == 2 ]] \
  || fail "the widget scheduler disable lacks receipts on both sides of the clean boot"
if rg -n -F 'launchctl kill SIGKILL "${chronod_service}"' "${run_e2e}" \
  || rg -n -F 'launchctl bootout "${chronod_service}"' "${run_e2e}"; then
  fail "the E2E harness still races a running widget scheduler with kill or bootout"
fi
if rg -n '(^|[^[:alpha:]])(sleep|usleep)[[:space:](]' "${run_e2e}" >/dev/null; then
  fail "the E2E harness contains a fixed settling wait"
fi
control_plane_reset="${ios_scripts}/reset-hosted-simulator-control-plane.sh"
normal_story_workflow="${repository_root}/.github/workflows/ios-e2e-story.yml"
qualification_workflow="${repository_root}/.github/workflows/r0-qualification.yml"
if rg -F 'PLAYER_RESET_HOSTED_SIMULATOR_CONTROL_PLANE: "1"' \
  "${normal_story_workflow}" >/dev/null; then
  fail "a one-story fresh-host normal job still destroys its CoreSimulator service"
fi
[[ "$(rg -F -c 'PLAYER_RESET_HOSTED_SIMULATOR_CONTROL_PLANE: "1"' \
  "${qualification_workflow}")" == 1 ]] \
  || fail "formal fresh-story jobs reset CoreSimulator or matrix lanes lost their between-story reset"
rg -Fq "alarm shift; exec @ARGV or exit 127' 2" "${control_plane_reset}" \
  || fail "hosted simulator control-plane events are not hard-capped at two seconds"
if rg -n '(^|[^[:alpha:]])(sleep|usleep)[[:space:](]' "${control_plane_reset}" >/dev/null; then
  fail "hosted simulator reset contains a fixed wait"
fi
control_plane_fake_bin="${temporary_root}/control-plane-bin"
control_plane_log="${temporary_root}/control-plane.log"
mkdir -p "${control_plane_fake_bin}"
cat > "${control_plane_fake_bin}/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'launchctl\t%s\n' "$*" >> "${PLAYER_CONTROL_PLANE_LOG}"
[[ "$*" == "kill SIGKILL user/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService" ]]
exit "${PLAYER_CONTROL_PLANE_EXIT_CODE:-0}"
EOF
cat > "${control_plane_fake_bin}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun\t%s\n' "$*" >> "${PLAYER_CONTROL_PLANE_LOG}"
[[ "$*" == "simctl list runtimes --json" ]]
exit "${PLAYER_CONTROL_PLANE_SIMCTL_EXIT_CODE:-0}"
EOF
chmod +x "${control_plane_fake_bin}/launchctl" "${control_plane_fake_bin}/xcrun"
if env PATH="${control_plane_fake_bin}:${PATH}" \
  PLAYER_CONTROL_PLANE_LOG="${control_plane_log}" \
  GITHUB_ACTIONS=false "${control_plane_reset}" >/dev/null 2>&1; then
  fail "simulator control-plane reset ran outside an isolated hosted job"
fi
env PATH="${control_plane_fake_bin}:${PATH}" \
  PLAYER_CONTROL_PLANE_LOG="${control_plane_log}" \
  GITHUB_ACTIONS=true "${control_plane_reset}"
[[ "$(wc -l < "${control_plane_log}" | tr -d ' ')" == 2 ]] \
  || fail "hosted simulator reset did not perform one termination and one readiness RPC"
[[ "$(sed -n '1p' "${control_plane_log}")" == $'launchctl\tkill SIGKILL user/'* \
  && "$(sed -n '2p' "${control_plane_log}")" == $'xcrun\tsimctl list runtimes --json' ]] \
  || fail "hosted simulator reset is not receipted in causal order"
: > "${control_plane_log}"
env PATH="${control_plane_fake_bin}:${PATH}" \
  PLAYER_CONTROL_PLANE_LOG="${control_plane_log}" \
  PLAYER_CONTROL_PLANE_EXIT_CODE=113 \
  GITHUB_ACTIONS=true "${control_plane_reset}"
[[ "$(wc -l < "${control_plane_log}" | tr -d ' ')" == 2 \
  && "$(sed -n '2p' "${control_plane_log}")" == $'xcrun\tsimctl list runtimes --json' ]] \
  || fail "an already absent service did not proceed to the readiness RPC"
: > "${control_plane_log}"
if env PATH="${control_plane_fake_bin}:${PATH}" \
  PLAYER_CONTROL_PLANE_LOG="${control_plane_log}" \
  PLAYER_CONTROL_PLANE_EXIT_CODE=1 \
  GITHUB_ACTIONS=true "${control_plane_reset}" >/dev/null 2>&1; then
  fail "hosted simulator reset accepted an unknown launchctl failure"
fi
[[ "$(wc -l < "${control_plane_log}" | tr -d ' ')" == 1 ]] \
  || fail "hosted simulator reset continued after an unknown launchctl failure"
: > "${control_plane_log}"
if env PATH="${control_plane_fake_bin}:${PATH}" \
  PLAYER_CONTROL_PLANE_LOG="${control_plane_log}" \
  PLAYER_CONTROL_PLANE_SIMCTL_EXIT_CODE=1 \
  GITHUB_ACTIONS=true "${control_plane_reset}" >/dev/null 2>&1; then
  fail "hosted simulator reset accepted a missing readiness receipt"
fi
[[ "$(wc -l < "${control_plane_log}" | tr -d ' ')" == 2 ]] \
  || fail "hosted simulator reset retried a failed readiness receipt"
for destination_source in \
  "${run_e2e}" \
  "${ios_scripts}/run-e2e-shard.sh" \
  "${ios_scripts}/qualification/run-matrix-lane.sh" \
  "${ios_scripts}/launch-simulator.sh" \
  "${ios_scripts}/run-complete-suite.sh"; do
  if rg -n -F 'platform=iOS Simulator,id=' "${destination_source}" >/dev/null; then
    fail "a simulator destination remains architecture-ambiguous in ${destination_source}"
  fi
done
rg -Fq 'log_started_at="${run_started_at/T/ }"' "${run_e2e}" \
  && rg -Fq 'log_started_at="${log_started_at%Z}"' "${run_e2e}" \
  || fail "failure logging does not convert the retained ISO instant for log show"
rg -Fq -- '--start "${log_started_at}" --style compact --info --debug' "${run_e2e}" \
  || fail "failure logging does not cover the complete attempt"
for retained_log in player.log simulator-system.log coresimulator-host.log semantic-probes.log; do
  rg -Fq "${retained_log}" "${run_e2e}" \
    || fail "failure diagnostics do not retain ${retained_log}"
done
rg -Fq 'xcresulttool export diagnostics' "${run_e2e}" \
  || fail "failure diagnostics do not export the retained xcresult diagnostics"
failure_evidence_line="$(rg -n -m 1 'failure-screenshot-evidence' "${run_e2e}" | cut -d: -f1)"
attachment_export_line="$(rg -n -m 1 'run_logged_phase attachment-export' "${run_e2e}" | cut -d: -f1)"
failure_screen_line="$(rg -n -m 1 'run_logged_phase failure-screen-capture' "${run_e2e}" | cut -d: -f1)"
test_exit_line="$(rg -n -F -m 1 'exit "${test_status}"' "${run_e2e}" | cut -d: -f1)"
[[ -n "${attachment_export_line}" && -n "${failure_screen_line}" \
  && -n "${failure_evidence_line}" && -n "${test_exit_line}" \
  && "${attachment_export_line}" -lt "${failure_screen_line}" \
  && "${failure_screen_line}" -lt "${failure_evidence_line}" \
  && "${failure_evidence_line}" -lt "${test_exit_line}" ]] \
  || fail "UI-test failures exit before screenshot evidence is materialized"
rg -Fq 'extract-xctest-failure-frame.swift' "${run_e2e}" \
  || fail "UI-test failures cannot fall back to an exported XCTest recording"
bounded_live_line="$(rg -n -F -m 1 -- '--capture-live "${simulator_id}"' "${run_e2e}" | cut -d: -f1)"
retained_xctest_line="$(rg -n -F -m 1 -- '--failure-screenshot-only' "${run_e2e}" | cut -d: -f1)"
recording_fallback_line="$(rg -n -F -m 1 -- '--recording-only' "${run_e2e}" | cut -d: -f1)"
[[ -n "${bounded_live_line}" && -n "${retained_xctest_line}" \
  && -n "${recording_fallback_line}" \
  && "${retained_xctest_line}" -lt "${bounded_live_line}" \
  && "${bounded_live_line}" -lt "${recording_fallback_line}" ]] \
  || fail "failure capture is not ordered retained screenshot, bounded live image, then recording"
rg -Fq 'if [[ "${retained_screenshot_status}" -eq 2 ]]; then retained_screenshot_status=0; fi' \
  "${run_e2e}" \
  || fail "only an absent retained failure screenshot permits a successful fallback"
if [[ "$(rg -F -c 'return "${retained_screenshot_status}"' "${run_e2e}")" != "3" ]]; then
  fail "fallback images do not preserve malformed or ambiguous screenshot failure status"
fi
if rg -Fq 'xcrun simctl io "${simulator_id}" screenshot' "${run_e2e}"; then
  fail "run-e2e can still block directly on a live simulator screenshot"
fi
rg -Fq 'failureScreen: $failureScreen' "${run_e2e}" \
  || fail "FailureEvidence does not bind the failure-screen provenance"
rg -Fq -- '--retain-all-evidence' "${run_e2e}" \
  || fail "UI-test failure comparison does not retain matching expected and actual images"
rg -Fq 'cp -R "${baseline_story}/." "${recording_stage}/"' "${run_e2e}" \
  || fail "baseline recording does not preserve reviewed auxiliary story files"
rg -Fq 'find "${recording_stage}/screenshots/ios" -type f -name '\''*.png'\'' -depth -delete' "${run_e2e}" \
  || fail "baseline recording does not replace the complete prior screenshot image set"
if rg -Fq 'find "${recording_stage}/screenshots/ios" -type f -depth -delete' "${run_e2e}"; then
  fail "baseline recording still deletes reviewed non-image comparison policy"
fi

python3 "${ios_scripts}/qualification/test_evidence_manifest.py" \
  || fail "the content-addressed per-attempt evidence contract is not fail closed"
for contract_call in \
  'qualification_write_evidence_manifest' \
  'qualification_validate_evidence_manifest'; do
  rg -Fq "${contract_call}" "${run_e2e}" \
    || fail "run-e2e does not invoke ${contract_call} during finalization"
done
for lane_script in \
  "${ios_scripts}/qualification/run-story-lane.sh" \
  "${ios_scripts}/qualification/run-matrix-lane.sh"; do
  rg -Fq 'qualification_validate_evidence_manifest' "${lane_script}" \
    || fail "$(basename "${lane_script}") does not revalidate every attempt"
  rg -Fq 'infrastructure_invalid=1' "${lane_script}" \
    || fail "$(basename "${lane_script}") does not fail closed on invalid infrastructure"
  rg -Fq 'evidenceValid' "${lane_script}" \
    || fail "$(basename "${lane_script}") does not retain its evidence verdict"
done

echo "E2E output, build provenance, and failure-evidence tests passed."
