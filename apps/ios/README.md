# Player for iOS

This directory contains the native SwiftUI app, its imported-media core, and deterministic launch/import/playback tests. The project is generated from `project.yml`; the generated `Player.xcodeproj` is committed so it can be opened directly and checked for reproducibility.

## Pinned environment

- Xcode 26.6
- iOS 26.5 simulator runtime
- iPhone 17 simulator
- XcodeGen 2.46.0
- Application deployment target: iOS 17

## Generate the project

```bash
apps/ios/scripts/generate-project.sh
```

The script downloads the pinned XcodeGen archive when needed and verifies its SHA-256 digest before executing it.

## Run an E2E story

```bash
apps/ios/scripts/run-e2e.sh
```

With no arguments the runner executes Story 001. A story and XCTest selector can be named explicitly:

```bash
apps/ios/scripts/run-e2e.sh \
  002-import-and-play \
  PlayerUITests/ImportPlaybackUITests/testReviewsCommitsAndPlaysOneAudiobook
```

The runner owns a story-specific temporary simulator, verifies the pinned toolchain, normalizes rendering state, runs semantic assertions, exports every generated step, and requires an exact pixel match with the committed baseline.

To intentionally record a reviewed baseline on the pinned environment:

```bash
apps/ios/scripts/run-e2e.sh --story 002-import-and-play \
  --test PlayerUITests/ImportPlaybackUITests/testReviewsCommitsAndPlaysOneAudiobook \
  --record 002-import-and-play
```

See [E2E_GUIDE.md](../../E2E_GUIDE.md) for the complete contract.

## Current product slice

- Library, Inbox, and Settings tabs
- Files importer with queued, acquiring, inspecting, review, and committed states
- Versioned atomic local persistence and immutable managed-media storage
- Streaming SHA-256 copy verification and storage preflight
- AVFoundation duration/basic metadata inspection and play/pause
- Review Import, populated Library, Book Detail, and Now Playing screens
- Light-mode E2E configuration with animations disabled
- Accessibility identifiers and an explicit `ready:library-empty` state value
- Generated launch and import/playback walkthroughs with full-screen baselines
- Exact native sRGB RGBA screenshot comparator with zero differing pixels allowed

Multi-file grouping, metadata repair, and advanced listening tools remain sequenced in [IMPLEMENTATION_PLAN.md](../../IMPLEMENTATION_PLAN.md).
