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

if rg -n --regexp 'class [A-Za-z0-9]+UITests: ' \
  "${ui_test_root}" --glob '*UITests.swift' \
  | rg -v ': PlayerUITestCase \{' \
  > "${temporary_root}/failure-screen-superclass.log"; then
  cat "${temporary_root}/failure-screen-superclass.log" >&2
  echo 'failure-evidence hygiene requires every UI-test class to retain a failure screenshot' >&2
  exit 1
fi
for retained_failure_pattern in \
  'class PlayerUITestCase: XCTestCase' \
  'override func record(_ issue: XCTIssue)' \
  'data: screenshot.pngRepresentation' \
  'uniformTypeIdentifier: UTType.png.identifier' \
  'attachment.name = "xctest-failure-screen.png"' \
  'attachment.lifetime = .keepAlways' \
  'add(attachment)' \
  'super.record(issue)'; do
  rg -Fq "${retained_failure_pattern}" "${ui_test_root}/TestStepHelper.swift" || {
    echo "failure-evidence hygiene is missing: ${retained_failure_pattern}" >&2
    exit 1
  }
done
player_ui_test_case="$({
  sed -n '/^class PlayerUITestCase: XCTestCase {/,/^}/p' \
    "${ui_test_root}/TestStepHelper.swift"
})"
if rg -Fq 'XCTAttachment(screenshot:' <<< "${player_ui_test_case}"; then
  echo 'failure-evidence hygiene rejected an attachment whose encoded type XCTest may change' >&2
  exit 1
fi

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
rg -Fq 'let notificationFrame = notificationTitle.frame' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'let coordinateFrame = springboard.windows.allElementsBoundByIndex' \
  "${ui_test_root}/TestStepHelper.swift"
if rg -Fq 'let springboardFrame = springboard.frame' \
  "${ui_test_root}/TestStepHelper.swift"; then
  echo 'system-overlay hygiene rejected pixel-space SpringBoard frame normalization' >&2
  exit 1
fi
rg -Fq 'springboard.coordinate(' \
  "${ui_test_root}/TestStepHelper.swift"
if rg -Fq 'notificationTitle.swipeUp()' \
  "${ui_test_root}/TestStepHelper.swift"; then
  echo 'system-overlay hygiene rejected an element-bound swipe on a transient notification' >&2
  exit 1
fi

for lifecycle_source in \
  "${ui_test_root}/PositionRestoreUITests.swift" \
  "${ui_test_root}/RemoteInterruptionUITests.swift"; do
  rg -Fq 'backgroundAndReactivateApplication(' "${lifecycle_source}" || {
    echo "lifecycle hygiene requires an exact background receipt before reactivation: ${lifecycle_source}" >&2
    exit 1
  }
  rg -Fq 'performBoundedForegroundInteraction(' "${lifecycle_source}" || {
    echo "lifecycle hygiene requires bounded foreground synthesis after Home: ${lifecycle_source}" >&2
    exit 1
  }
done
if rg -n -U --regexp 'XCUIDevice\.shared\.press\(\.home\)\n[[:space:]]*app\.activate\(\)' \
  "${ui_test_root}" --glob '*.swift' \
  > "${temporary_root}/home-activation-race.log"; then
  cat "${temporary_root}/home-activation-race.log" >&2
  echo 'lifecycle hygiene rejected app activation before SpringBoard acknowledged Home' >&2
  exit 1
fi
rg -Fq 'backgroundReceipt.wait(timeout: 2)' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'application.wait(for: .runningBackground, timeout: 2)' \
  "${ui_test_root}/TestStepHelper.swift" || {
  echo 'lifecycle hygiene requires a bounded Home-delivery receipt before the scene checkpoint deadline' >&2
  exit 1
}
python3 - "${ui_test_root}/TestStepHelper.swift" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
home = source.index('XCUIDevice.shared.press(.home)')
background = source.index('application.wait(for: .runningBackground, timeout: 2)', home)
checkpoint = source.index('backgroundReceipt.wait(timeout: 2)', background)
activation = source.index('application.activate()', checkpoint)
if not home < background < checkpoint < activation:
    raise SystemExit(
        'lifecycle hygiene requires Home delivery, checkpoint completion, then activation'
    )
PY
rg -Fq 'applicationFrame.contains(elementFrame)' \
  "${ui_test_root}/TestStepHelper.swift"
if [[ "$(rg -c \
  '^[[:space:]]{4}(?:let captureBoundaryResolution = )?dismissAppleIntelligenceNotificationIfPresent\(\)$' \
  "${ui_test_root}/TestStepHelper.swift")" != "2" ]]; then
  echo 'system-overlay hygiene requires resolution before readiness and at capture' >&2
  exit 1
fi
rg -Fq 'let dismissed = waitForNoElements(notificationTitles, deadline: EventDeadline())' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'let doneButtons = app.navigationBars.buttons.matching(' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'doneButtons.count,' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq '"Now Playing must expose one navigation-scoped Done button"' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq '{ surface.state()?.atBottom == true }' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'after bottom-endpoint framing' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'bookmarkSegmentIsFramed(segment, within: scroll)' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'requiresScrollableRange: true' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'terminalEndpoint: \.atBottom' \
  "${ui_test_root}/BookmarkUITests.swift"
if rg -Fq 'add.tap()' "${ui_test_root}/BookmarkUITests.swift"; then
  echo 'bookmark hygiene rejects unacknowledged Add Bookmark taps' >&2
  exit 1
fi
rg -Fq 'deliverPhysicalActionAcknowledgedByDisabling(' \
  "${ui_test_root}/BookmarkUITests.swift"
if rg -Fq 'verify.tap()' "${ui_test_root}/OfflineRecoveryUITests.swift"; then
  echo 'offline diagnostics hygiene rejects an unacknowledged verification tap' >&2
  exit 1
fi
rg -Fq 'deliverPhysicalActionAcknowledgedByDisabling(' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq 'guard !isWorking else { return }' \
  "${ui_test_root}/../Player/SupportDiagnosticsView.swift"
rg -Fq 'isWorking = true' \
  "${ui_test_root}/../Player/SupportDiagnosticsView.swift"
rg -Fq '@State private var isSavingBookmark = false' \
  "${ui_test_root}/../Player/ContentView.swift"
rg -Fq '.disabled(isSavingBookmark)' \
  "${ui_test_root}/../Player/ContentView.swift"
delivery_helper="${ui_test_root}/TestStepHelper.swift"
delivery_helper_start="$(rg -n '^func deliverPhysicalActionAcknowledgedByDisabling\(' \
  "${delivery_helper}" | cut -d: -f1)"
delivery_helper_end="$(rg -n '^func waitForNoElements\(' \
  "${delivery_helper}" | cut -d: -f1)"
delivery_helper_body="$(sed -n "${delivery_helper_start},${delivery_helper_end}p" \
  "${delivery_helper}")"
delivery_helper_gesture="$(rg -n -m 1 \
  'performPhysicalInteractionWithoutPostEventQuiescence' \
  <<<"${delivery_helper_body}" | cut -d: -f1)"
delivery_helper_deadline="$(rg -n -m 1 \
  'deliveryDeadline = EventDeadline()' \
  <<<"${delivery_helper_body}" | cut -d: -f1)"
[[ -n "${delivery_helper_gesture}" && -n "${delivery_helper_deadline}" \
  && "${delivery_helper_gesture}" -lt "${delivery_helper_deadline}" ]] || {
  echo 'async action hygiene requires a post-synthesis delivery deadline' >&2
  exit 1
}
rg -Fq 'waitForExistence(container, deadline: EventDeadline())' \
  "${ui_test_root}/AccessibilityUITests.swift"
multifile_grouping="${ui_test_root}/MultifileGroupingUITests.swift"
if rg -n --regexp 'select(B4|Prelude|B3)\.tap\(\)' "${multifile_grouping}" \
  > "${temporary_root}/multifile-selection-tap.log"; then
  cat "${temporary_root}/multifile-selection-tap.log" >&2
  echo 'multifile hygiene rejected an element-bound reversible selection tap' >&2
  exit 1
fi
[[ "$(rg -c '^[[:space:]]+try selectTrack\($' \
  "${multifile_grouping}")" == "3" ]] || {
  echo 'multifile hygiene requires every track selection to use bounded delivery' >&2
  exit 1
}
rg -Fq 'private func selectTrack(' \
  "${multifile_grouping}"
rg -Fq 'performPhysicalInteractionWithoutPostEventQuiescence(' \
  "${multifile_grouping}"
rg -Fq 'waitForPredicate(selected, on: action, timeout: selectionDeadline.remaining)' \
  "${multifile_grouping}"
rg -Fq 'let orderScroll = app.collectionViews.firstMatch' "${multifile_grouping}"
rg -Fq 'let revealPredicate = NSPredicate' "${multifile_grouping}"
rg -Fq 'timeout: min(0.35, revealDeadline.remaining)' "${multifile_grouping}"
offline_recovery="${ui_test_root}/OfflineRecoveryUITests.swift"
if rg -Fq 'app.buttons["startup-recovery-restore"].tap()' "${offline_recovery}"; then
  echo 'Offline recovery hygiene rejects element-bound durable restore taps' >&2
  exit 1
fi
rg -Fq 'try tapRecoveryAction("startup-recovery-restore", in: app)' "${offline_recovery}"
rg -Fq 'let restoreDeadline = EventDeadline()' "${offline_recovery}"
rg -Fq 'performPhysicalInteractionWithoutPostEventQuiescence(' "${offline_recovery}"
library_organization="${ui_test_root}/LibraryOrganizationUITests.swift"
rg -Fq 'presentTabAction(addAudiobook, destination: receiverScreen, in: app)' \
  "${library_organization}"
rg -Fq 'performPhysicalInteractionWithoutPostEventQuiescence(' "${library_organization}"
rg -Fq 'timeout: min(0.25, deliveryDeadline.remaining)' "${library_organization}"
if rg -Fq 'tapTabAction(addAudiobook, in: app)' "${library_organization}"; then
  echo 'Library organization hygiene rejects an unacknowledged Add action tap' >&2
  exit 1
fi
for delivery_source in \
  "${multifile_grouping}:tapPhysicalAction:selectTrack" \
  "${library_organization}:presentTabAction:requireValue" \
  "${ui_test_root}/BackupUITests.swift:tapProductionAction:requireOperation" \
  "${ui_test_root}/LibrarySearchCoverageUITests.swift:deliverPhysicalAction:tap"; do
  delivery_file="${delivery_source%%:*}"
  delivery_remainder="${delivery_source#*:}"
  delivery_start_name="${delivery_remainder%%:*}"
  delivery_end_name="${delivery_remainder#*:}"
  delivery_start="$(rg -n "^  private func ${delivery_start_name}\\(" \
    "${delivery_file}" | cut -d: -f1)"
  delivery_end="$(rg -n "^  private func ${delivery_end_name}\\(" \
    "${delivery_file}" | cut -d: -f1)"
  delivery_body="$(sed -n "${delivery_start},${delivery_end}p" "${delivery_file}")"
  delivery_gesture="$(rg -n -m 1 \
    'performPhysicalInteractionWithoutPostEventQuiescence' \
    <<<"${delivery_body}" | cut -d: -f1)"
  delivery_deadline="$(rg -n -m 1 \
    'deliveryDeadline = EventDeadline\(\)' \
    <<<"${delivery_body}" | cut -d: -f1)"
  [[ -n "${delivery_gesture}" && -n "${delivery_deadline}" \
    && "${delivery_gesture}" -lt "${delivery_deadline}" ]] || {
    echo "physical delivery hygiene requires a post-synthesis receipt deadline: ${delivery_file}" >&2
    exit 1
  }
  rg -Fq 'frame ==' <<<"${delivery_body}"
done
library_search_coverage="${ui_test_root}/LibrarySearchCoverageUITests.swift"
if rg -n --regexp 'try tap\((menu|item), in: app\)' "${library_search_coverage}" \
  > "${temporary_root}/search-menu-delivery.log"; then
  cat "${temporary_root}/search-menu-delivery.log" >&2
  echo 'Library search hygiene rejects unacknowledged menu action taps' >&2
  exit 1
fi
rg -Fq 'until: itemControl' "${library_search_coverage}"
rg -Fq 'value != %@' "${library_search_coverage}"
computer_receiver_tests="${ui_test_root}/../PlayerTests/ComputerReceiverTests.swift"
rg -Fq 'fileprivate static let webRuntimePrimer = ReceiverWebRuntimePrimer()' \
  "${computer_receiver_tests}"
rg -Fq 'MainActor.assumeIsolated { _ = webRuntimePrimer }' \
  "${computer_receiver_tests}"
rg -Fq 'final class WebKitComputerReceiverTests: XCTestCase {' \
  "${computer_receiver_tests}"
rg -Fq 'let webView = runtimePrimer.beginJourney(with: documentBridge)' \
  "${computer_receiver_tests}"
rg -Fq 'defer { runtimePrimer.endJourney() }' \
  "${computer_receiver_tests}"
[[ "$(rg -c 'WKWebView\(' "${computer_receiver_tests}")" == "1" ]] || {
  echo 'WebKit receiver hygiene requires the journey to reuse the retained primed web view' >&2
  exit 1
}
[[ "$(rg -c 'func testWebKitBrowserCompletesARealLocalHTTPImport\(\)' \
  "${computer_receiver_tests}")" == "1" ]] || {
  echo 'WebKit receiver hygiene requires exactly one late browser journey' >&2
  exit 1
}
receiver_suite_line="$(rg -n '^final class ComputerReceiverTests: XCTestCase' \
  "${computer_receiver_tests}" | cut -d: -f1)"
webkit_suite_line="$(rg -n '^final class WebKitComputerReceiverTests: XCTestCase' \
  "${computer_receiver_tests}" | cut -d: -f1)"
[[ "${receiver_suite_line}" -lt "${webkit_suite_line}" ]] || {
  echo 'WebKit receiver hygiene requires the primer suite before the browser journey' >&2
  exit 1
}
scroll_helper="${ui_test_root}/TestStepHelper.swift"
scroll_start="$(rg -n '^func scrollUntil\(' "${scroll_helper}" | cut -d: -f1)"
scroll_end="$(rg -n '^func challengeSettledEnd\(' "${scroll_helper}" | cut -d: -f1)"
gesture_line="$(sed -n "${scroll_start},${scroll_end}p" "${scroll_helper}" \
  | rg -n -m 1 'performPhysicalInteractionWithoutPostEventQuiescence' | cut -d: -f1)"
deadline_line="$(sed -n "${scroll_start},${scroll_end}p" "${scroll_helper}" \
  | rg -n -m 1 'let actionDeadline = EventDeadline\(\)' \
  | cut -d: -f1)"
[[ -n "${scroll_start}" && -n "${scroll_end}" \
  && -n "${gesture_line}" && -n "${deadline_line}" \
  && "${gesture_line}" -lt "${deadline_line}" ]] || {
  echo 'scroll hygiene requires the two-second action deadline to begin after physical synthesis' >&2
  exit 1
}
rg -Fq 'var remainingGestureCount = max(' "${scroll_helper}"
rg -Fq 'while remainingGestureCount > 0' "${scroll_helper}"
rg -Fq 'remainingGestureCount -= 1' "${scroll_helper}"
rg -Fq 'terminateAndDisplaceSurface(app)' \
  "${ui_test_root}/AccessibilityUITests.swift"
if [[ "$(rg -c 'terminateAndWait\(' "${ui_test_root}/AccessibilityUITests.swift")" != "1" ]]; then
  echo 'accessibility lifecycle hygiene requires every process boundary to displace glass' >&2
  exit 1
fi
accessibility_tests="${ui_test_root}/AccessibilityUITests.swift"
framing_start="$(rg -n '^  private func settleCaptureFraming\(' \
  "${accessibility_tests}" | cut -d: -f1)"
framing_end="$(rg -n '^  private func waitForCaptureAnchor\(' \
  "${accessibility_tests}" | cut -d: -f1)"
framing_source="$(sed -n "${framing_start},${framing_end}p" \
  "${accessibility_tests}")"
if rg -q 'for _ in 0\.\.<[0-9]+' <<<"${framing_source}"; then
  echo 'accessibility framing hygiene rejects a fixed correction-attempt ceiling' >&2
  exit 1
fi
rg -Fq 'while true {' <<<"${framing_source}"
rg -Fq 'updatedError < abs(displacement) - 0.5' <<<"${framing_source}"
rg -Fq 'let actionDeadline = EventDeadline()' <<<"${framing_source}"
rg -Fq 'let settledGeometryReceipt = after.completionGeometryID == after.geometryID' \
  <<<"${framing_source}"
rg -Fq 'phaseCompletion || settledGeometryReceipt' <<<"${framing_source}"

echo "Capture-readiness and selector source hygiene tests passed."
