# iOS end-to-end testing

Player uses XCTest/XCUIAutomation for semantic verification and full-screen screenshots for exact visual regression testing. The test and its generated walkthrough are both executable product specifications.

## Non-negotiable contract

- Every screenshot is captured only after programmatic assertions establish the intended application state.
- Baselines and actual images must contain the same filenames and dimensions.
- The generated walkthrough README must match the reviewed baseline byte for byte.
- Multi-class README fragments are ordered by their lowest numbered screenshot,
  independent of XCTest completion or attachment-export order.
- Images are decoded into canonical sRGB RGBA bytes and compared per pixel and per channel.
- After canonical sRGB decoding, a channel may differ by at most 8/255 to absorb
  Core Graphics rounding observed across otherwise identical Xcode 26.6
  runners. Any channel delta of 9 or greater fails. There is no spatial
  threshold, ratio, masking, antialiasing region, or retry.
- A baseline update is a reviewed design change, never an automatic response to failure.
- Test code may not use arbitrary sleeps, delayed dispatch, or test retries. Every screenshot step waits for explicit semantic verifications, then captures immediately; pixel changes must be fixed at their source rather than hidden behind a generic rendering timer.
- Every observable condition has a maximum timeout of two seconds. Longer work must expose intermediate states that can be asserted independently.

## Pinned rendering environment

- Xcode 26.6
- iOS 26.5 simulator runtime
- iPhone 17 simulator
- Portrait orientation
- Light appearance
- Standard Dynamic Type
- English language with `en_CA` locale
- `America/Toronto` time zone
- Fixed 9:41 AM status bar, charged 100% battery, and full network indicators
- Animations disabled in the E2E build

Changing any item requires recording and reviewing a complete new baseline set.

## Run a story

The runner creates and later deletes a simulator named for the story; it does
not reuse a personal simulator. Multi-class stories may use up to two isolated
XCTest simulator clones so their selected tests can run concurrently without
sharing application state.

Every simulator created by the E2E and core-test harness has a durable lease
containing its exact UDID and owning process identity. Normal exit and INT/TERM
release that lease; the next acquisition reconciles a lease left by a dead
owner. Reconciliation validates every record before acting and never deletes
by simulator name, prefix, or glob, so an unrelated personal simulator is not
part of harness cleanup. A malformed record stops reconciliation without
deleting anything.

To compare against committed baselines:

```bash
apps/ios/scripts/run-e2e.sh
```

To run another story:

```bash
apps/ios/scripts/run-e2e.sh \
  002-import-and-play \
  PlayerUITests/ImportPlaybackUITests/testReviewsCommitsAndPlaysOneAudiobook
```

To intentionally record the initial or a changed baseline, pass the exact story identifier; recording is rejected in CI:

```bash
apps/ios/scripts/run-e2e.sh --story 002-import-and-play --record 002-import-and-play
```

The runner prints the collision-free output directory reserved for each direct
invocation. The run manifest, phase timings, logs, test result, raw attachments,
materialized actual walkthrough, and failure diagnostics remain there. A pixel
failure includes the expected, actual, and red heatmap diff images plus a
machine-readable summary. Orchestrators may set `PLAYER_E2E_OUTPUT` to an
absolute, nonexistent directory; the runner atomically reserves it and refuses
to delete or reuse an existing path. The exact image comparator is
[compare-walkthrough.swift](apps/ios/scripts/compare-walkthrough.swift).
A document mismatch retains the expected README, actual README, and unified
diff under the same story's diagnostics directory.

In GitHub Actions, five balanced macOS shards match the available runner
concurrency. Each shard verifies and generates the project once, builds the
complete test bundle once, and then runs its assigned stories sequentially.
Only immutable build products are shared: every story still gets a newly
created simulator, result bundle, logs, comparisons, and separately named
diagnostics artifact. Reuse is fail-closed: a stored manifest must match the
source and generated-project content, commit, Xcode and simulator SDK,
destination runtime/device, and `.xctestrun` hash. One shard also runs the
fixture checks and core suite from the shared build. UI-test classes run serially within each shard because
concurrent XCTest clones contend for simulator accessibility services; the
safe parallelism boundary is the five independent macOS hosts. The
`Core tests and exact E2E walkthroughs` aggregate succeeds only when all five
shards succeed for the exact commit SHA.

To exercise the same build-sharing contract locally, pass canonical story IDs
to the shard runner. `--core` additionally exercises the fixture and core-test
gate:

```bash
apps/ios/scripts/run-e2e-shard.sh \
  --shard local-smoke \
  --core \
  010-library-backup \
  011-offline-recovery
```

Shard timing and core diagnostics remain under
`apps/ios/DerivedData/E2EShards/<shard>/`; the story evidence remains in its
normal per-story directory.

To run the complete serial acceptance suite locally—fixture verification, all
unit/integration tests, and Stories 001–013—use:

```bash
apps/ios/scripts/run-complete-suite.sh
```

To measure a story repeatedly without concealing failures or overwriting any
attempt's evidence, use:

```bash
apps/ios/scripts/measure-e2e-reliability.sh \
  --story 005-play-and-restore \
  --attempts 10
```

The command retains every attempt and writes TSV and JSON summaries under
`apps/ios/DerivedData/E2EQualification/`. A failed attempt is counted and the
remaining requested measurements still run; there is no retry-to-green path.
The worktree and commit must remain unchanged throughout the run. The
environment and generated project are verified once, and immutable test build
products are reused, but each attempt creates a clean simulator and retains an
independent result bundle, log set, walkthrough, and comparison diagnostics.

The performance, migration, and tracer mapping is maintained in
[MVP_ACCEPTANCE_MATRIX.md](MVP_ACCEPTANCE_MATRIX.md).

## Story structure

Each story lives under `tests/e2e/<number>-<name>/` and contains:

```text
story.json
README.md
screenshots/
└── ios/
    └── 000-step-name.png
```

[`tests/e2e/manifest.json`](tests/e2e/manifest.json) is the canonical mapping
from stories to UI-test selectors. The hygiene check requires every UI test to
appear exactly once and requires the five CI shards to assign every canonical
story exactly once. Each story's `story.json` records its fixture and expected
screenshot inventory.

The Swift `TestStepHelper` combines state assertions, screenshot capture, deterministic naming, and walkthrough generation in one operation. Screenshot counters and Markdown references are not maintained manually.

## Baseline review

When a visual change is intentional:

1. Run the normal test and inspect the failure.
2. Inspect the actual screenshot in `apps/ios/DerivedData/E2E/<story>/ActualWalkthrough/`.
3. Explain the design change in the review.
4. Record on the pinned environment.
5. Review the changed PNG and generated README together.
6. Run once more without the recording flag to prove a canonical match.

Do not record baselines on a different Xcode, runtime, simulator model, locale, content-size category, or appearance.
