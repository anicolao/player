# iOS end-to-end testing

Player uses XCTest/XCUIAutomation for semantic verification and full-screen screenshots for exact visual regression testing. The test and its generated walkthrough are both executable product specifications.

## Non-negotiable contract

- Every screenshot is captured only after programmatic assertions establish the intended application state.
- Baselines and actual images must contain the same filenames and dimensions.
- Images are decoded into canonical sRGB RGBA bytes and compared per pixel and per channel.
- **Zero differing pixels are allowed.** There is no threshold, ratio, masking, antialiasing allowance, or retry.
- A baseline update is a reviewed design change, never an automatic response to failure.
- Test code may not use `sleep`, `usleep`, `Thread.sleep`, `Task.sleep`, delayed dispatch, fixed polling, or test retries.
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

## Run the launch story

The runner creates and later deletes a simulator named `Player E2E`; it does not reuse a personal simulator.

To compare against committed baselines:

```bash
apps/ios/scripts/run-e2e.sh
```

To intentionally record the initial or a changed baseline:

```bash
PLAYER_RECORD_SCREENSHOTS=1 apps/ios/scripts/run-e2e.sh
```

The test result, raw attachments, and materialized actual walkthrough remain under `apps/ios/DerivedData/` for diagnosis. The exact comparator is [compare-walkthrough.swift](apps/ios/scripts/compare-walkthrough.swift).

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
2. Inspect the actual screenshot in `apps/ios/DerivedData/ActualWalkthrough/`.
3. Explain the design change in the review.
4. Record on the pinned environment.
5. Review the changed PNG and generated README together.
6. Run once more without the recording flag to prove an exact match.

Do not record baselines on a different Xcode, runtime, simulator model, locale, content-size category, or appearance.

