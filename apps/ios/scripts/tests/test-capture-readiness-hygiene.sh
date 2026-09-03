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
  echo 'failure-evidence hygiene requires every UI-test class to use the shared failure-evidence harness' >&2
  exit 1
fi
rg -Fq 'class PlayerUITestCase: XCTestCase' \
  "${ui_test_root}/TestStepHelper.swift" || {
  echo 'failure-evidence hygiene is missing the shared UI-test superclass' >&2
  exit 1
}
player_ui_test_case="$({
  sed -n '/^class PlayerUITestCase: XCTestCase {/,/^}/p' \
    "${ui_test_root}/TestStepHelper.swift"
})"
if rg -q --regexp 'override func record|XCUIScreen\.main\.screenshot|XCTAttachment' \
  <<< "${player_ui_test_case}"; then
  echo 'failure-evidence hygiene rejected blocking in-process failure capture' >&2
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
remote_interruption="${ui_test_root}/RemoteInterruptionUITests.swift"
[[ "$(rg -c 'requiresProductionAdapters: true' "${remote_interruption}")" == "2" ]] || {
  echo 'remote interruption hygiene requires launch and relaunch adapter readiness receipts' >&2
  exit 1
}
rg -Fq 'state.registeredCommands == registeredCommands' "${remote_interruption}"
accessibility_source="${ui_test_root}/AccessibilityUITests.swift"
rg -Fq 'backgroundAndReactivateApplication(app, requiringButton: "play-book")' \
  "${accessibility_source}" || {
  echo 'accessibility lifecycle hygiene requires the exact Book Detail background and foreground receipts' >&2
  exit 1
}
if rg -Fq 'app.activate()' "${accessibility_source}"; then
  echo 'accessibility lifecycle hygiene rejected unacknowledged direct app activation' >&2
  exit 1
fi
if rg -n -U --regexp 'XCUIDevice\.shared\.press\(\.home\)\n[[:space:]]*app\.activate\(\)' \
  "${ui_test_root}" --glob '*.swift' \
  > "${temporary_root}/home-activation-race.log"; then
  cat "${temporary_root}/home-activation-race.log" >&2
  echo 'lifecycle hygiene rejected app activation before SpringBoard acknowledged Home' >&2
  exit 1
fi
content_view_source="${script_dir}/../../Player/ContentView.swift"
player_app_source="${script_dir}/../../Player/PlayerApp.swift"
player_model_source="${script_dir}/../../Player/Core/PlayerModel.swift"
rg -Fq 'name: UIApplication.willResignActiveNotification' "${player_app_source}" || {
  echo 'lifecycle hygiene requires the synchronous UIKit resign-active notification' >&2
  exit 1
}
rg -Fq 'model.prepareBackgroundCheckpoint()' "${player_app_source}" || {
  echo 'lifecycle hygiene requires resign-active durable-checkpoint preparation' >&2
  exit 1
}
rg -Fq 'name: UIApplication.didEnterBackgroundNotification' "${player_app_source}" || {
  echo 'lifecycle hygiene requires the synchronous UIKit background notification' >&2
  exit 1
}
rg -Fq 'await model.checkpointForBackground()' "${player_app_source}" || {
  echo 'lifecycle hygiene requires background to join the prepared checkpoint' >&2
  exit 1
}
if rg -Fq 'model.prepareBackgroundCheckpoint()' "${content_view_source}" \
  || rg -Fq 'await model.checkpointForBackground()' "${content_view_source}"; then
  echo 'lifecycle hygiene rejects coalescible SwiftUI scenePhase checkpoint ownership' >&2
  exit 1
fi
rg -Fq 'await precedingTask?.value' "${player_model_source}" || {
  echo 'lifecycle hygiene requires refreshed checkpoints to serialize behind prior persistence' >&2
  exit 1
}
python3 - "${player_app_source}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
inactive = source.index("applicationWillResignActive")
inactive_receipt = source.index("E2ELifecycleEvent.postSceneBecameInactive()", inactive)
prepare = source.index("model.prepareBackgroundCheckpoint()", inactive_receipt)
prepared_completion = source.index(
    "await model.waitForPreparedBackgroundCheckpoint()", prepare
)
background = source.index("applicationDidEnterBackground", prepared_completion)
background_receipt = source.index(
    "E2ELifecycleEvent.postSceneBecameBackground()", background
)
join = source.index("await model.checkpointForBackground()", background)
if not (
    inactive < inactive_receipt < prepare < prepared_completion
    < background < background_receipt < join
):
    raise SystemExit(
        "lifecycle hygiene requires synchronous UIKit inactivity to prepare and "
        "acknowledge the checkpoint before UIKit background joins it"
    )
PY
transport_controls_source="${ui_test_root}/TransportControlsUITests.swift"
rg -Fq 'deliverPhysicalActionAcknowledgedByStateTransition(' \
  "${transport_controls_source}" || {
  echo 'transport hygiene requires an exact production receipt for play/pause delivery' >&2
  exit 1
}
if rg -n -F 'buttons["player-play-pause"].tap()' "${transport_controls_source}" \
  > "${temporary_root}/raw-transport-play-pause-taps.log"; then
  cat "${temporary_root}/raw-transport-play-pause-taps.log" >&2
  echo 'transport hygiene rejected an unacknowledged play/pause tap' >&2
  exit 1
fi
metadata_editing_source="${ui_test_root}/CommittedMetadataEditingUITests.swift"
metadata_repair_source="${ui_test_root}/MetadataRepairUITests.swift"
test_step_helper_source="${ui_test_root}/TestStepHelper.swift"
python3 - \
  "${metadata_editing_source}" \
  "${metadata_repair_source}" \
  "${test_step_helper_source}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
replacement = source.index('if !replacement.isEmpty {')
clear_receipt = source.rindex(
    'try requireValuePrefix(provenance, "value=empty|")', 0, replacement
)
acknowledged_entry = source.index(
    'typeTextAcknowledgedByEditedField(', replacement
)
focus_receipt = source.index(
    'self.requireMetadataFieldFocus(field, fieldName: fieldName)', acknowledged_entry
)
semantic_receipt = source.index(
    'try requireValuePrefix(provenance, expectedPrefix)', focus_receipt
)
if not clear_receipt < replacement < acknowledged_entry < focus_receipt < semantic_receipt:
    raise SystemExit(
        'metadata-editing hygiene requires an acknowledged clear, exact refocus, '
        'and semantic receipt around replacement synthesis'
    )

repair = Path(sys.argv[2]).read_text()
if 'field.typeText(replacement)' in source or 'field.typeText(replacement)' in repair:
    raise SystemExit(
        'metadata-editing hygiene rejects unacknowledged bulk replacement synthesis'
    )
repair_entry = repair.index('typeTextAcknowledgedByEditedField(')
repair_model_receipt = repair.index(
    'titleValue.waitForStringValue("value=\\(replacement)", timeout: 2)',
    repair_entry,
)
repair_field_receipt = repair.index('try requireValue(field, replacement)', repair_model_receipt)
if not repair_entry < repair_model_receipt < repair_field_receipt:
    raise SystemExit(
        'metadata-repair hygiene requires edited-field delivery followed by '
        'independent model and final field receipts'
    )

helper = Path(sys.argv[3]).read_text()
start = helper.index('func typeTextAcknowledgedByEditedField(')
end = helper.index('\n@MainActor\nfunc performPhysicalInteractionWithoutPostEventQuiescence', start)
body = helper[start:end]
ordered = [
    'let empty = NSPredicate { _, _ in observedText() == "" }',
    'guard waitForPredicate(empty, on: field, timeout: EventDeadline().remaining)',
    'let missingSuffix = String(target.dropFirst(accepted.count))',
    'field.typeText(missingSuffix)',
    'let deadline = EventDeadline()',
    'XCTWaiter.wait(for: [expectation], timeout: deadline.remaining)',
    'current.count > prior.count',
    'target.hasPrefix(current)',
]
positions = [body.index(marker) for marker in ordered]
if positions != sorted(positions):
    raise SystemExit(
        'acknowledged text-entry hygiene requires strict-prefix synthesis followed '
        'by a bounded semantic progress receipt'
    )
PY
zip_source="${ui_test_root}/SafeZIPImportUITests.swift"
rg -Fq 'requireZipSelectionDelivery(' "${zip_source}"
if rg -n -F 'buttons["choose-from-files-empty-library"].tap()' "${zip_source}" \
  > "${temporary_root}/raw-zip-selection-taps.log"; then
  cat "${temporary_root}/raw-zip-selection-taps.log" >&2
  echo 'ZIP hygiene requires an exact terminal receipt for injected Files selection' >&2
  exit 1
fi
python3 - "${zip_source}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
helper = source.index('private func requireZipSelectionDelivery(')
synthesis = source.index(
    'performPhysicalInteractionWithoutPostEventQuiescence(', helper
)
deadline = source.index(
    'if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }',
    synthesis,
)
receipt = source.index('waitForPredicate(', deadline)
if not helper < synthesis < deadline < receipt:
    raise SystemExit(
        'ZIP hygiene requires physical synthesis before the bounded terminal receipt deadline'
    )
for evidence in (
    'ready:library-empty',
    'zip:\\(zipCase):idle:',
    'action.frame == actionFrame',
):
    if evidence not in source[helper:source.index('private func zipCaptureReadiness(', helper)]:
        raise SystemExit(
            f'ZIP hygiene requires unchanged-origin evidence before redelivery: {evidence}'
        )
PY
rg -Fq 'backgroundReceipt.wait(timeout: 2)' \
  "${ui_test_root}/TestStepHelper.swift"
rg -Fq 'inactiveReceipt.wait(timeout: 2)' \
  "${ui_test_root}/TestStepHelper.swift"
if rg -Fq 'sceneBackgroundReceipt.wait' "${ui_test_root}/TestStepHelper.swift"; then
  echo 'lifecycle hygiene rejected waiting on the OS-owned inactive-to-background transition' >&2
  exit 1
fi
rg -Fq 'await model.waitForPreparedBackgroundCheckpoint()' \
  "${player_app_source}"
rg -Fq 'E2ELifecycleEvent.postSceneBecameInactive()' \
  "${player_app_source}"
rg -Fq 'E2ELifecycleEvent.postSceneBecameBackground()' \
  "${player_app_source}"
rg -Fq '.accessibilityIdentifier("e2e-playback-persistence-probe")' \
  "${script_dir}/../../Player/ContentView.swift"
rg -Fq 'E2EPlaybackPersistenceBridge.shared.record(' \
  "${script_dir}/../../Player/Core/PlayerModel.swift"
rg -Fq 'position=90000|reason=pause' \
  "${ui_test_root}/PositionRestoreUITests.swift"
python3 - "${ui_test_root}" "${script_dir}/../../Player/E2ELaunchEnvironment.swift" <<'PY'
import sys
from pathlib import Path

ui_root = Path(sys.argv[1])
launch_environment = Path(sys.argv[2]).read_text()
ui_source = "\n".join(path.read_text() for path in ui_root.glob("*.swift"))
receipt_count = ui_source.count("DarwinEventReceipt(")
qualified_receipt_count = ui_source.count("name: namespacedE2EEvent(")
if receipt_count != qualified_receipt_count or receipt_count == 0:
    raise SystemExit(
        "every Darwin receipt must use the launching application's event namespace; "
        f"receipts={receipt_count}, qualified={qualified_receipt_count}"
    )
for required in (
    'private let e2eEventNamespaceEnvironmentKey = "PLAYER_E2E_EVENT_NAMESPACE"',
    'application.launchEnvironment[e2eEventNamespaceEnvironmentKey]',
):
    if required not in ui_source:
        raise SystemExit(f"the UI runner does not assign isolated event names: {required}")
if launch_environment.count(
    "CFNotificationName(E2EEventNamespace.qualify(name) as CFString)"
) != 2:
    raise SystemExit("every production E2E Darwin publisher must qualify its event name")
PY
rg -Fq 'com.spnss.player.e2e.scene-became-inactive' \
  "${script_dir}/../../Player/E2ELaunchEnvironment.swift"
rg -Fq 'com.spnss.player.e2e.scene-became-background' \
  "${script_dir}/../../Player/E2ELaunchEnvironment.swift"
rg -Fq 'E2EOperationEvent.postReceiverImporting()' \
  "${script_dir}/../../Player/ComputerReceiverView.swift"
rg -Fq 'E2EOperationEvent.postReceiverCompleted()' \
  "${script_dir}/../../Player/ComputerReceiverView.swift"
rg -Fq 'request.entryPoint == .computerReceiver' \
  "${script_dir}/../../Player/Core/PlayerModel.swift"
rg -Fq 'referenceApplicationOwnedImportSources' \
  "${script_dir}/../../Player/Core/PlayerModel.swift"
rg -Fq 'importingReceipt?.wait(timeout: 2)' \
  "${ui_test_root}/LaunchUITests.swift"
rg -Fq 'completedReceipt?.wait(timeout: 2)' \
  "${ui_test_root}/LaunchUITests.swift"
rg -Fq 'E2EOperationEvent.postSupportVerificationFinished()' \
  "${script_dir}/../../Player/SupportDiagnosticsView.swift"
rg -Fq 'verificationFinished?.wait(timeout: 2)' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
python3 - "${ui_test_root}/LaunchUITests.swift" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
startup = source.index(
    'func testAudioSessionConfigurationWarningDoesNotPresentImportAlertAtStartup()'
)
next_selector = source.index('\n  func test', startup + 1)
if 'terminateAndWait(app)' not in source[startup:next_selector]:
    raise SystemExit(
        'launch hygiene requires the startup-warning selector to publish a clean not-running handoff'
    )

for selector, following_selector, minimum_acknowledged_actions in (
    (
        'func testComputerReceiverVisibleActionsDriveProductionState()',
        'func testComputerReceiverCloseWhileActiveConfirmsCleanup()',
        6,
    ),
    (
        'func testComputerReceiverCloseWhileActiveConfirmsCleanup()',
        'func testComputerReceiverRetriesListenerAndImportFailures()',
        5,
    ),
):
    start = source.index(selector)
    end = source.index(following_selector, start)
    journey = source[start:end]
    acknowledged_actions = journey.count(
        'deliverPhysicalActionAcknowledgedByStateTransition('
    )
    if acknowledged_actions < minimum_acknowledged_actions:
        raise SystemExit(
            'receiver confirmation hygiene requires every sequential presentation '
            f'action to have an independent state-transition receipt: {selector}'
        )
    for raw_action in (
        'app.buttons["receive-from-computer-empty-library"].tap()',
        'app.buttons["copy-computer-receiver-address"].tap()',
        'app.buttons["stop-computer-receiver"].tap()',
        'app.buttons["Close"].tap()',
        'app.buttons["Keep Receiving"].tap()',
        'app.buttons["Stop and Clean Up"].tap()',
    ):
        if raw_action in journey:
            raise SystemExit(
                'receiver confirmation hygiene rejects an unacknowledged action: '
                f'{selector}: {raw_action}'
            )
PY
python3 - "${ui_test_root}/ImportIngressResilienceUITests.swift" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
document = source.index(
    'func testDocumentOpenResumesOneImportAcrossAcquireAndInspectRestarts()'
)
share = source.index(
    'func testConsumesAndDeduplicatesShareExtensionAppGroupHandoff()', document
)
helpers = source.index('\n  private func ', share)
if 'let documentURL = try stagedDocumentURL(' not in source[document:share]:
    raise SystemExit(
        'document-ingress hygiene requires an external staged source before the real system URL open'
    )
if 'terminateAndWait(resumedApp)' not in source[document:share]:
    raise SystemExit(
        'launch hygiene requires the document-ingress selector to finish not running'
    )
if 'terminateAndWait(replayApp)' not in source[share:helpers]:
    raise SystemExit(
        'launch hygiene requires the share-handoff selector to finish not running'
    )
staging = source.index('private func stagedDocumentURL(', helpers)
staging_end = source.index('\n  private func ', staging + 1)
staging_source = source[staging:staging_end]
if (
    'FileManager.default.temporaryDirectory' not in staging_source
    or 'copyItem(at: bundledURL, to: stagedURL)' not in staging_source
):
    raise SystemExit(
        'document-ingress hygiene rejects LaunchServices binding against a nested xctest-bundle fixture'
    )
PY
python3 - "${ui_test_root}/TestStepHelper.swift" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
home = source.index('XCUIDevice.shared.press(.home)')
inactive = source.index('inactiveReceipt.wait(timeout: 2)', home)
checkpoint = source.index('backgroundReceipt.wait(timeout: 2)', inactive)
nonquiescent_activation = source.index(
    'performPhysicalInteractionWithoutPostEventQuiescence(in: application',
    checkpoint,
)
app_activation = source.index('application.activate()', nonquiescent_activation)
fresh_control = source.index(
    'application.buttons[interactiveElementIdentifier]', app_activation
)
if not home < inactive < checkpoint < nonquiescent_activation < app_activation < fresh_control:
    raise SystemExit(
        'lifecycle hygiene requires Home, production inactive, completed app-owned checkpoint, non-quiescent app activation, then a freshly resolved exact control'
    )
segment = source[home:inactive]
if 'springboard.activate()' in segment or '.runningForeground' in segment:
    raise SystemExit(
        'lifecycle hygiene rejects sampled SpringBoard state before the stronger production scene receipts'
    )
lifecycle_end = source.index('/// Adjusts an idempotent slider', fresh_control)
if 'application.state' in source[app_activation:lifecycle_end]:
    raise SystemExit(
        'lifecycle hygiene rejects sampled application process state after the exact app-owned control is interactive'
    )
PY
for slider_source in \
  "${ui_test_root}/PositionRestoreUITests.swift" \
  "${ui_test_root}/TransportControlsUITests.swift" \
  "${ui_test_root}/MetadataRepairUITests.swift"; do
  rg -Fq 'adjustSliderAcknowledged(' "${slider_source}" || {
    echo "slider hygiene requires an exact production receipt: ${slider_source}" >&2
    exit 1
  }
done
python3 - "${ui_test_root}" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
uses = []
needle = 'adjust(toNormalizedSliderPosition:'
for path in sorted(root.glob('*.swift')):
    count = path.read_text().count(needle)
    uses.extend([path.name] * count)
if uses != ['TestStepHelper.swift']:
    raise SystemExit(
        'slider hygiene requires exactly one direct XCUI slider adjustment, '
        f'inside the acknowledged helper; found={uses}'
    )

source = (root / 'TestStepHelper.swift').read_text()
helper = source.index('func adjustSliderAcknowledged(')
synthesis = source.index(
    'performPhysicalInteractionWithoutPostEventQuiescence(', helper
)
deadline = source.index(
    'if deliveryDeadline == nil { deliveryDeadline = EventDeadline() }',
    synthesis,
)
receipt = source.index('waitForPredicate(', deadline)
if not helper < synthesis < deadline < receipt:
    raise SystemExit(
        'slider hygiene requires physical synthesis before the bounded receipt deadline'
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
python3 - "${ui_test_root}/BookmarkUITests.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('  private func revealBookmarkRow(')
end = source.index('  private func bookmarkFrameIsUnobscured(', start)
helper = source[start:end]
required = (
    'permitsGeometrySettledFallback: true',
    '{ surface.state()?.atBottom == true }',
    'requiresHittable: false',
    'visible at the proven bottom endpoint',
)
missing = [pattern for pattern in required if pattern not in helper]
if missing:
    raise SystemExit(
        'bookmark reveal hygiene requires correlated bottom geometry and a '
        f'noninteractive visibility assertion; missing={missing}'
    )
if 'row.exists && row.isHittable' in helper:
    raise SystemExit(
        'bookmark reveal hygiene rejects stale hittability as a read-only row precondition'
    )
PY
python3 - "${ui_test_root}/SleepTimerUITests.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('  private func assertEveryProductionSelection() throws {')
end = source.index('  private func assertReplacementCancellationAndHistoryPersist()', start)
helper = source[start:end]
if helper.count('app.launch()') != 1:
    raise SystemExit(
        'sleep-timer selection hygiene requires one app launch for all production choices'
    )
if helper.count('SelectionCase(') != 8:
    raise SystemExit(
        'sleep-timer selection hygiene requires all eight production choices'
    )
required = (
    'namespace: "all-selections"',
    'for (index, selection) in selections.enumerated()',
    'selection.fade != currentFade',
    'tapWhenFullyVisible(app.buttons[selection.buttonID], in: app)',
    'historyCount: index',
    'XCTAssertEqual(probe["latest"], "replaced")',
    'XCTAssertTrue(terminateAndWait(app))',
)
missing = [pattern for pattern in required if pattern not in helper]
if missing:
    raise SystemExit(
        'sleep-timer selection hygiene requires same-session production replacement '
        f'and exact receipts; missing={missing}'
    )
tap_start = source.index('  private func tapWhenFullyVisible(')
tap_end = source.index('  private func tapTrailingSwitchControl(', tap_start)
tap_helper = source[tap_start:tap_end]
tap_required = (
    'surface.state()?.isIdle == true',
    'elementIsFullyVisible(',
    'requiresHittable: false',
    'screen.coordinate(withNormalizedOffset:',
)
missing = [pattern for pattern in tap_required if pattern not in tap_helper]
if missing:
    raise SystemExit(
        'sleep-timer selection tapping requires idle correlated geometry and a '
        f'container-relative physical action; missing={missing}'
    )
if '.isHittable' in tap_helper or 'element.tap()' in tap_helper:
    raise SystemExit(
        'sleep-timer selection tapping rejects XCTest activation-point queries '
        'and direct element activation'
    )
PY
rg -Fq 'case allSelections = "all-selections"' \
  "${ui_test_root}/../Player/E2ELaunchEnvironment.swift"
if rg -Fq 'add.tap()' "${ui_test_root}/BookmarkUITests.swift"; then
  echo 'bookmark hygiene rejects unacknowledged Add Bookmark taps' >&2
  exit 1
fi
rg -Fq 'deliverPhysicalActionAcknowledgedByDisabling(' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'DarwinEventReceipt(' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'DispatchSource.makeReadSource(' \
  "${ui_test_root}/TestStepHelper.swift" || {
  echo 'Darwin receipt hygiene requires an event-driven descriptor source' >&2
  exit 1
}
rg -Fq 'XCTWaiter.wait(for: [receipt], timeout: timeout)' \
  "${ui_test_root}/TestStepHelper.swift" || {
  echo 'Darwin receipt hygiene requires a bounded XCTest event receipt' >&2
  exit 1
}
if rg -Fq 'Darwin.poll(' "${ui_test_root}/TestStepHelper.swift"; then
  echo 'Darwin receipt hygiene rejects a runner-main-thread blocking poll' >&2
  exit 1
fi
rg -Fq '"com.spnss.player.e2e.text-input-focused.\(identifier)"' \
  "${ui_test_root}/BookmarkUITests.swift"
for focus_id in \
  bookmark-search \
  bookmark-label-editor \
  bookmark-note-editor \
  library-search-input; do
  rg -Fq "postTextInputFocused(controlID: \"${focus_id}\")" \
    "${script_dir}/../../Player" || {
    echo "bookmark hygiene requires an exact production focus event for ${focus_id}" >&2
    exit 1
  }
done
if rg -Fq 'postTextInputFocused()' "${script_dir}/../../Player"; then
  echo 'bookmark hygiene rejects the representation-ambiguous shared focus event' >&2
  exit 1
fi
rg -Fq 'name: namespacedE2EEvent(' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'let delivered = focusReceipt.wait(timeout: deliveryDeadline.remaining)' \
  "${ui_test_root}/BookmarkUITests.swift"
if rg -Fq 'while !delivered' "${ui_test_root}/BookmarkUITests.swift"; then
  echo 'bookmark hygiene rejects retrying an already delivered physical focus action' >&2
  exit 1
fi
if rg -Fq 'exactOrigin.exists, currentField.exists, currentField.isEnabled' \
  "${ui_test_root}/BookmarkUITests.swift"; then
  echo 'bookmark hygiene rejects deadline-consuming AX re-resolution between focus attempts' >&2
  exit 1
fi
rg -Fq 'currentField.tap()' \
  "${ui_test_root}/BookmarkUITests.swift" || {
  echo 'bookmark hygiene requires element-bound text-field focus synthesis' >&2
  exit 1
}
focus_helper="$({
  sed -n '/private func focusAndType(/,/private func requireProbe(/p' \
    "${ui_test_root}/BookmarkUITests.swift"
})"
if grep -Fq 'app.coordinate(' <<<"${focus_helper}"; then
  echo 'bookmark hygiene rejects stale app-normalized text-field focus coordinates' >&2
  exit 1
fi
rg -Fq 'performPhysicalInteractionWithoutPostEventQuiescence(in: app)' \
  "${ui_test_root}/BookmarkUITests.swift"
if rg -Fq 'focusProbe.waitForStringValue' "${ui_test_root}/BookmarkUITests.swift"; then
  echo 'bookmark hygiene rejects accessibility polling as a text-input focus receipt' >&2
  exit 1
fi
rg -Fq '"com.spnss.player.e2e.bookmark-search-dismissed"' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'dismissalReceipt.wait(timeout: dismissalDeadline.remaining)' \
  "${ui_test_root}/BookmarkUITests.swift"
rg -Fq 'E2EOperationEvent.postBookmarkSearchDismissed()' \
  "${ui_test_root}/../Player/BookmarksView.swift"
rg -Fq 'UIResponder.keyboardDidHideNotification' \
  "${ui_test_root}/../Player/BookmarksView.swift"
rg -Fq '#selector(UIResponder.resignFirstResponder)' \
  "${ui_test_root}/../Player/BookmarksView.swift"
if rg -Fq 'search.typeKey(.return' "${ui_test_root}/BookmarkUITests.swift" \
  || rg -Fq 'if keyboards.count == 1' "${ui_test_root}/BookmarkUITests.swift"; then
  echo 'bookmark hygiene rejects transient keyboard-count polling as a dismissal receipt' >&2
  exit 1
fi
if rg -Fq 'verify.tap()' "${ui_test_root}/OfflineRecoveryUITests.swift"; then
  echo 'offline diagnostics hygiene rejects an unacknowledged verification tap' >&2
  exit 1
fi
rg -Fq 'deliverPhysicalActionAcknowledgedByDisabling(' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq '"com.spnss.player.e2e.support-verification-finished"' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq '"com.spnss.player.e2e.support-verification-cleanup-finished"' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq 'verificationFinished?.wait(timeout: 2)' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq 'verificationCleanupFinished?.wait(timeout: 2)' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq '"com.spnss.player.e2e.startup-recovery-presented"' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq 'name: namespacedE2EEvent(' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq 'presentationReceipt?.wait(timeout: 2)' \
  "${ui_test_root}/OfflineRecoveryUITests.swift"
rg -Fq 'expectsRecoveryPresentation: false' \
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
multifile_surface="${ui_test_root}/../Player/ContentView.swift"
rg -Fq 'checkpoint.acquisitionComplete' "${multifile_surface}"
rg -Fq 'checkpoint.acquired.count == 8' "${multifile_surface}"
if rg -Fq 'job.stagedAssets.count == 8' "${multifile_surface}"; then
  echo 'multifile acquisition hygiene rejects coupling acquisition to completed review staging' >&2
  exit 1
fi
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
challenge_end="$(rg -n '^func waitForScrollReadiness\(' "${scroll_helper}" | cut -d: -f1)"
challenge_source="$(sed -n "${scroll_end},${challenge_end}p" "${scroll_helper}")"
[[ "$(rg -c 'scrollUntil\(' <<<"${challenge_source}")" == "2" ]]
rg -Fq 'direction: .towardStart' <<<"${challenge_source}"
rg -Fq 'direction: .towardEnd' <<<"${challenge_source}"
if rg -q 'performPhysicalInteractionWithoutPostEventQuiescence' <<<"${challenge_source}"; then
  echo 'endpoint challenge hygiene requires progress-making retreat and restore receipts' >&2
  exit 1
fi
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
