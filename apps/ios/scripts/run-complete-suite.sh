#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_dir="$(cd "${script_dir}/.." && pwd)"
repository_root="$(cd "${ios_dir}/../.." && pwd)"
destination="${PLAYER_COMPLETE_SUITE_DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=26.5}"
core_build_data="${ios_dir}/DerivedData/CompleteSuiteCore"

cd "${repository_root}"
"${script_dir}/verify-e2e-environment.sh"
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

run_story() {
  local story="$1"
  shift
  "${script_dir}/run-e2e.sh" "${story}" "$@"
  # Retain the materialized reviewable walkthrough while bounding disk use
  # across all twelve isolated simulator builds.
  rm -rf "${ios_dir}/DerivedData/E2E/${story}/Build"
  rm -rf "${ios_dir}/DerivedData/E2E/${story}/Attachments"
  rm -rf "${ios_dir}/DerivedData/E2E/${story}/Results"
}

run_story 001-ios-launch \
  PlayerUITests/LaunchUITests/testLaunchesIntoEmptyLibrary
run_story 002-import-and-play \
  PlayerUITests/ImportPlaybackUITests/testAbandonsReadyImportAndClearsInbox \
  PlayerUITests/ImportPlaybackUITests/testReviewsCommitsAndPlaysOneAudiobook \
  PlayerUITests/MetadataChapterUITests/testShowsEmbeddedMetadataAndStartsAChapter \
  PlayerUITests/ImportIngressResilienceUITests/testDocumentOpenResumesOneImportAcrossAcquireAndInspectRestarts \
  PlayerUITests/ImportIngressResilienceUITests/testConsumesAndDeduplicatesShareExtensionAppGroupHandoff
run_story 003-multifile-grouping \
  PlayerUITests/MultifileGroupingUITests/testRepairsMessyMultifileGroupingAndCommitsOneBookAtomically
run_story 004-metadata-repair \
  PlayerUITests/MetadataRepairUITests/testRepairsLocksCommitsAndUndoesMetadataWithoutChangingAudio
run_story 005-play-and-restore \
  PlayerUITests/PositionRestoreUITests/testRestoresAnAcknowledgedPausedPositionAfterTermination \
  PlayerUITests/RemoteInterruptionUITests/testRemoteInterruptionAndBackgroundEventsJournalAcknowledgedPositions \
  PlayerUITests/TransportControlsUITests/testCustomizesAndRestoresListeningControls \
  PlayerUITests/SmartRewindUITests/testSmartRewindAdaptsClampsPersistsAndUndoesExactly \
  PlayerUITests/SmartRewindUITests/testSmartRewindNoticeDismissesAfterFiveSecondsOfPlaybackProgress
run_story 006-safe-zip-import \
  PlayerUITests/SafeZIPImportUITests/testRejectsHostileZIPsThenCancelsAndRetriesAValidArchive \
  PlayerUITests/ImportRecoveryStorageUITests/testRecoversMixedImportsAndExplainsStorageWithoutTouchingSources
run_story 007-sleep-timer \
  PlayerUITests/SleepTimerUITests/testSleepTimerPersistsFadesStopsAndResumesWithContextExactly \
  PlayerUITests/BookmarkUITests/testBookmarksCaptureOrganizeSearchJumpDeleteAndUndoExactly
run_story 008-library-search \
  PlayerUITests/LibraryOrganizationUITests/testOrganizesDailyLibraryAndRestoresATrashedBook
run_story 009-accessible-core-journeys \
  PlayerUITests/AccessibilityUITests/testCoreJourneysRemainCompleteAtLargestAccessibilityText
run_story 010-library-backup \
  PlayerUITests/BackupUITests/testExportsClearsAndRestoresAVerifiedPortableLibrary
run_story 011-offline-recovery \
  PlayerUITests/OfflineRecoveryUITests/testRecoversStartupAndExportsOnlySanitizedOfflineDiagnostics
run_story 012-monetization \
  PlayerUITests/MonetizationUITests/testExplainsExhaustionAndCompletesAOneTimeUnlock

echo "Complete Player suite passed: unit/integration tests and Stories 001-012."
