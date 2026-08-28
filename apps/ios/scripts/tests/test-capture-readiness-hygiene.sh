#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${script_dir}/../verify-e2e-hygiene.sh"
ui_test_root="${script_dir}/../../PlayerUITests"
temporary_root="$(mktemp -d /tmp/player-capture-readiness-test.XXXXXX)"
trap 'rm -rf "${temporary_root}"' EXIT

valid_root="${temporary_root}/valid"
invalid_root="${temporary_root}/invalid"
mkdir -p "${valid_root}" "${invalid_root}"

cat > "${valid_root}/ValidUITests.swift" <<'SWIFT'
final class ValidUITests {
  func testValidCaptures() throws {
    try tester.step(
      "first",
      description: "captureReadiness: in a string is irrelevant",
      verifications: [
        StepVerification(specification: "nested") { true },
      ],
      captureReadiness: CaptureReadiness(specification: "ready", anchor: anchor) {
        true
      }
    )
    try tester.step("second", description: "ready", verifications: [], captureReadiness: gate)
  }
}
SWIFT

cat > "${invalid_root}/MissingCaptureUITests.swift" <<'SWIFT'
final class MissingCaptureUITests {
  func testMissingGate() throws {
    try tester.step(
      "missing",
      description: "captureReadiness: text must not satisfy hygiene",
      verifications: [
        StepVerification(specification: "nested") {
          let captureReadiness: Bool = true
          return captureReadiness
        },
      ]
    )
  }
}
SWIFT

"${checker}" --check-capture-readiness-root "${valid_root}" \
  > "${temporary_root}/valid.log"
rg -q 'Capture readiness hygiene passed for 2 tester.step calls' \
  "${temporary_root}/valid.log"

if "${checker}" --check-capture-readiness-root "${invalid_root}" \
  > "${temporary_root}/invalid.log" 2>&1; then
  echo "capture-readiness hygiene accepted a tester.step call without a gate" >&2
  exit 1
fi
rg -q 'MissingCaptureUITests.swift:3: tester.step screenshot is missing top-level captureReadiness:' \
  "${temporary_root}/invalid.log"

"${checker}" --check-capture-readiness-root "${ui_test_root}" \
  > "${temporary_root}/current.log"
rg -q 'Capture readiness hygiene passed for [1-9][0-9]* tester.step calls' \
  "${temporary_root}/current.log"

selector_sources=(
  "${ui_test_root}/AccessibilityUITests.swift"
  "${ui_test_root}/AppStoreListingUITests.swift"
  "${ui_test_root}/BookmarkUITests.swift"
  "${ui_test_root}/ImportIngressResilienceUITests.swift"
  "${ui_test_root}/ImportPlaybackUITests.swift"
  "${ui_test_root}/ImportRecoveryStorageUITests.swift"
  "${ui_test_root}/LaunchUITests.swift"
  "${ui_test_root}/LibraryOrganizationUITests.swift"
  "${ui_test_root}/OfflineRecoveryUITests.swift"
  "${ui_test_root}/PositionRestoreUITests.swift"
  "${ui_test_root}/TestStepHelper.swift"
)

assert_pattern_absent() {
  local pattern="$1"
  local failure_message="$2"
  if rg -n --regexp "${pattern}" "${selector_sources[@]}" \
    > "${temporary_root}/selector-violation.log"; then
    cat "${temporary_root}/selector-violation.log" >&2
    echo "${failure_message}" >&2
    exit 1
  fi
}

assert_pattern_absent '\.firstMatch' \
  'selector hygiene rejected an ambiguous firstMatch query'
assert_pattern_absent 'identifier == %@ OR label == %@' \
  'selector hygiene rejected an identifier-or-label fallback query'
assert_pattern_absent 'identifier BEGINSWITH %@ OR label BEGINSWITH %@' \
  'selector hygiene rejected an identifier-prefix-or-label-prefix fallback query'
assert_pattern_absent 'app\.buttons\["Done"\]' \
  'selector hygiene rejected an unscoped Done button query'

if rg -n --fixed-strings 'dismissAppleIntelligenceNotificationIfPresent()' \
  "${ui_test_root}" \
  --glob '*.swift' \
  --glob '!TestStepHelper.swift' \
  > "${temporary_root}/system-overlay-bypass.log"; then
  cat "${temporary_root}/system-overlay-bypass.log" >&2
  echo 'system-overlay hygiene rejected a direct best-effort dismissal call' >&2
  exit 1
fi

bookmark_backdoor_sources=(
  "${ui_test_root}/BookmarkUITests.swift"
  "${ui_test_root}/../Player/BookmarksView.swift"
  "${ui_test_root}/../Player/ContentView.swift"
)
if rg -n --regexp 'e2e-[^"[:space:]]*(scroll|align)|bookmarks-walkthrough-bottom' \
  "${bookmark_backdoor_sources[@]}" \
  > "${temporary_root}/bookmark-scroll-backdoor.log"; then
  cat "${temporary_root}/bookmark-scroll-backdoor.log" >&2
  echo 'bookmark hygiene rejected an E2E-only scroll/alignment backdoor identifier' >&2
  exit 1
fi

rg -Fq 'func resolveAppleIntelligenceNotification(' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'guard notificationTitles.count == 1 else {' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'attachSystemInterruptionEvidence(' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'let dismissed = waitForNoElements(notificationTitles, deadline: EventDeadline())' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'let doneButtons = app.navigationBars.buttons.matching(' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'doneButtons.count,' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq '"Now Playing must expose one navigation-scoped Done button"' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'performBookmarkFramingGesture(in: scroll)' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'bookmarkSegmentIsFramed(segment, within: scroll)' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'requiresScrollableRange: true' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'terminalEndpoint: \.atBottom' \
  "${ui_test_root}/BookmarkUITests.swift"

echo "Capture-readiness and selector source hygiene tests passed."
