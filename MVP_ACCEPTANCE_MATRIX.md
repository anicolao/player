# MVP acceptance evidence

Status: C05 executable evidence complete; final C06 visual audit pending

This matrix maps the complete T00–T19 contract to committed, reproducible
evidence. The canonical command is:

```bash
apps/ios/scripts/run-complete-suite.sh
```

It verifies the pinned environment, reproducible project and legal fixtures,
runs every unit/integration test, and then executes exact-pixel Stories 001–011.
GitHub Actions runs the same core and story gates in parallel and requires their
aggregate result for each release SHA.

| Tracer | Acceptance claim | Executable evidence |
| --- | --- | --- |
| T00–T01 | Launch and the empty Library are usable and visually stable. | [Story 001](tests/e2e/001-ios-launch/README.md) |
| T02–T05 | Single-book import, review, metadata/chapters, commit, and playback work atomically. | [Story 002](tests/e2e/002-import-and-play/README.md), `PlayerCoreTests` |
| T06 | Messy multi-file books group, order, and commit as one book. | [Story 003](tests/e2e/003-multifile-grouping/README.md), `PlayerCoreTests` |
| T07–T08 | Full metadata repair, confidence/evidence, locking, and undo preserve audio. | [Story 004](tests/e2e/004-metadata-repair/README.md), `PlayerCoreTests` |
| T09 | Durable playback position, background/interruption handling, and transport preferences restore exactly. | [Story 005](tests/e2e/005-play-and-restore/README.md), `TransportPreferencesTests`, `SmartRewindTests` |
| T10–T11 | ZIP and every shipped ingress route are safe, restartable, deduplicated, and recoverable. | [Story 006](tests/e2e/006-safe-zip-import/README.md), `SafeZipExtractorTests`, `ImportRecoveryTests`, `ComputerReceiverTests` |
| T12–T13 | Sleep timer and bookmarks persist, search, jump, delete, and undo. | [Story 007](tests/e2e/007-sleep-timer/README.md), `SleepTimerTests`, `BookmarkTests` |
| T14–T15 | Large daily libraries organize, search, filter, scroll lazily, trash, and restore deterministically. | [Story 008](tests/e2e/008-library-search/README.md), `LibraryOrganizationTests`, `LibrarySearchTests` |
| T16 | Portable backup/restore verifies metadata, artwork, and media; database backups rotate. | [Story 010](tests/e2e/010-library-backup/README.md), [format contract](BACKUP_AND_RESTORE.md), `LibraryBackupTests` |
| T17 | Core journeys remain complete at AX5 with programmatic accessibility semantics and preferences. | [Story 009](tests/e2e/009-accessible-core-journeys/README.md), [accessibility audit](ACCESSIBILITY_AUDIT.md), `AccessibilityPreferencesTests` |
| T18 | Invalid startup state is preserved and recoverable; offline tasks work; support export is redacted. | [Story 011](tests/e2e/011-offline-recovery/README.md), [offline audit](OFFLINE_RECOVERY_AUDIT.md), `OfflineRecoveryTests` |
| T19 | 1k/10k durable startup, 10k search/index windows, multi-gig streaming, every schema, and the complete suite meet their contracts. | `MVPScaleTests`, `LibrarySearchTests`, schemas `PlayerTests/Fixtures/Schemas/library-v01…v15.json`, `run-complete-suite.sh` |

## Performance and corpus gates

| Gate | Budget / invariant | Proof |
| --- | --- | --- |
| 1,000-record ready state | under 1 second | `MVPScaleTests.testReadyStateStartupMeetsOneAndTenThousandRecordBudgets` loads the durable v15 store through `PlayerModel.restore()` |
| 10,000-record ready state | under 2 seconds | same test and production restore path |
| 10,000-record search | under 100 ms | `LibrarySearchTests.testTenThousandBookIndexReturnsResultsWithinOneHundredMilliseconds` |
| Index/scroll stability | off `MainActor`; stable first, middle, and final result windows | actor-isolated `LibrarySearchIndexBuilder`, lazy Story 008 UI, and `testActorIndexerProducesStableWindowsForTenThousandScrollableResults` |
| Large import and backup | more than 2 GiB per simulated path; no chunk above 1 MiB | production `StreamingFileIO` exercised by `MVPScaleTests.testMultiGigabyteImportAndBackupStreamsStayWithinOneMiB` |
| Shipped schemas | committed v1–v15 fixture migrates to v15 and round-trips | `MVPScaleTests.testEveryCommittedSchemaFixtureMigratesAndRoundTrips` |

All corpus content is synthetic. The private full-book smoke test remains an
opt-in local check and its content, title, filenames, and output are never
committed or uploaded.
