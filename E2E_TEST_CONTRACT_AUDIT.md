# E2E test-contract audit

**Scope:** R16 selector, narrative, and test-name review  
**Result:** Automated contract is closed; no UI test is unclassified or excluded

## Selection inventory

- The source tree contains 41 `PlayerUITests` test methods.
- `tests/e2e/manifest.json` contains the same 41 selectors exactly once.
- The manifest contains 13 canonical stories, matching the 13 story directories.
- The five CI lanes assign those 13 stories exactly once.
- `run-complete-suite.sh`, `run-e2e-shard.sh`, normal CI, and formal R0
  qualification all derive selectors from the same reviewed manifest.
- There are no manual or noncanonical UI-test exclusions. Platform behavior that
  cannot be automated truthfully is recorded separately in physical-device
  acceptance matrices rather than represented by an omitted test selector.

`apps/ios/scripts/verify-e2e-hygiene.sh` fails when a UI method is absent from
the manifest, a selector is duplicated, a story description and manifest
diverge, a story directory is not selected, or CI duplicates selectors instead
of consuming the manifest. It also enforces the fixed-wait, two-second deadline,
capture-readiness, retry, recording, and evidence contracts.

## Required regressions

- The zero-duration Now Playing regression
  `ImportPlaybackUITests/testNowPlayingRendersWhenImportedDurationIsUnavailable`
  is selected by Story 002.
- `AccessibilityUITests/testAccessibilityPreferenceTogglesUpdateAndPersist` is
  selected by Story 009. It changes both preferences, terminates the process,
  launches the same isolated namespace without reset, and asserts both restored
  switch values and restored model state.
- Newly added R10, R11, R13, and R14 UI regressions are selected in the same
  focused commits as their production or test implementation, so no
  intermediate commit relies on a later selector catch-up.

## Naming and claim audit

The audit compared every UI test name and canonical walkthrough heading with
its setup, production boundary, assertions, relaunch behavior, and captured
evidence. Three names were corrected:

| Prior name | Corrected name | Reason |
| --- | --- | --- |
| `testEditsPersistsIndexesAndUndoesACommittedBookAtomically` | `testPersistsCommittedMetadataUpdatesIndexesAndUndoesAtomically` | Fixes the grammatical claim and states the asserted persistence/index/undo boundaries. |
| `testRepairsMessyMultifileGroupingAndCommitsOneBookAtomically` | `testRepairsMessyMultifileGroupingAndCommitsExactlyOneBook` | The UI proves exactly one committed book; transaction rollback atomicity remains a focused core-test claim. |
| `testRemoteInterruptionAndBackgroundEventsJournalAcknowledgedPositions` | `testRemoteInterruptionRouteLossAndBackgroundEventsJournalAcknowledgedPositions` | The journey now explicitly drives and verifies old-route loss as well as interruption and background checkpoints. |

Remaining strong terms are supported by their assertions. In particular,
“production” means production UI/model/server/package/MediaPlayer behavior with
determinism injected only at an otherwise unavailable platform boundary; it
does not claim a real Files, Photos, StoreKit, Bluetooth, car, or interruption
surface. Those surfaces retain explicit physical-device acceptance rows.
“Persists” requires a process boundary, “exactly” requires an asserted value or
cardinality, and “every” is used only where the test enumerates the complete
closed set named by the contract.

## Reproduction

Run:

```sh
apps/ios/scripts/verify-e2e-hygiene.sh
```

Acceptance evidence must also record the exact commit SHA and the normal/final
CI run IDs; this audit does not turn pending physical-device rows into passes.
