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

echo "E2E output isolation and build provenance tests passed."
