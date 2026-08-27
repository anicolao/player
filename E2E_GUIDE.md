# iOS end-to-end testing

Player uses XCTest/XCUIAutomation for semantic verification and full-screen screenshots for exact visual regression testing. The test and its generated walkthrough are both executable product specifications.

## Non-negotiable contract

- Every screenshot is captured only after programmatic assertions establish the intended application state.
- Baselines and actual images must contain the same filenames and dimensions.
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

The runner creates and later deletes a simulator named `Player E2E`; it does not reuse a personal simulator.

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
apps/ios/scripts/run-e2e.sh --story 002-import-and-play \
  --test PlayerUITests/ImportPlaybackUITests/testReviewsCommitsAndPlaysOneAudiobook \
  --record 002-import-and-play
```

The test result, raw attachments, and materialized actual walkthrough remain under `apps/ios/DerivedData/E2E/<story>/` for diagnosis. The exact comparator is [compare-walkthrough.swift](apps/ios/scripts/compare-walkthrough.swift).

In GitHub Actions, the core suite and each committed story run in isolated
parallel jobs. Every story uploads its own diagnostics artifact, and the
`Core tests and exact E2E walkthroughs` aggregate succeeds only when the core
job and every story job succeed. Serial release work advances only from that
aggregate green result for the exact commit SHA.

To run the complete serial acceptance suite locally—fixture verification, all
unit/integration tests, and Stories 001–011—use:

```bash
apps/ios/scripts/run-complete-suite.sh
```

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
