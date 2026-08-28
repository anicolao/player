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

## Launch without opening Xcode

From the repository root, Nix can generate and build the project, create or reuse a persistent iPhone 17 simulator, install the app, and launch it:

```bash
nix develop
```

This uses the locally installed pinned Xcode toolchain; Nix supplies the command-line dependencies but does not package Xcode or the simulator runtime. Set `PLAYER_SKIP_SIMULATOR_LAUNCH=1` when you only want the development shell.

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

The runner owns a story-specific temporary simulator, verifies the pinned toolchain, normalizes rendering state, runs semantic assertions, exports every generated step, and requires a canonical pixel match with the committed baseline. Each direct invocation reserves a unique output directory and prints its path, so concurrent runs of the same story cannot overwrite one another. The canonical comparator permits at most 8/255 per sRGB channel for decoder rounding and permits no spatial mismatch.

To intentionally record a reviewed baseline on the pinned environment:

```bash
apps/ios/scripts/run-e2e.sh --story 002-import-and-play --record 002-import-and-play
```

See [E2E_GUIDE.md](../../E2E_GUIDE.md) for the complete contract.

## Current product slice

- Library, Inbox, and Settings tabs with search, sorting, filtering, collections,
  trash, and storage management
- Files, document-open/AirDrop, Share Extension, safe ZIP, private local web,
  and region-gated iPhone Mirroring import routes
- Queued, acquiring, inspecting, recoverable failure, review, committed,
  cancellation, retry, abandonment, and duplicate states
- Versioned atomic local persistence and immutable managed-media storage
- Streaming SHA-256 copy verification and storage preflight
- Explainable grouping/order, full manual metadata and cover repair, and undo
- AVFoundation playback with chapters, durable position/history, remote
  commands, speed, skip preferences, Smart Rewind, sleep timer, and bookmarks
- Light-mode E2E configuration with animations disabled
- Accessibility identifiers and exact semantic values for stable story states
- Stories 001–013 covering launch/import, grouping, metadata, ZIP, Library,
  position restoration, sleep timer, bookmarks, accessibility, backup,
  recovery, monetization, and App Store surfaces
- Native sRGB RGBA screenshot comparator that rejects any channel delta above 8/255
- Server-confirmed byte-offset resume and explicit repeat-import controls for
  the local computer receiver (Build 14 candidate)
- Versioned `.playerbackup` export/restore with streamed media checksums and
  rotating automatic database copies (Build 15 candidate)
- Explicit startup recovery with preserved corrupt-store evidence, UUID-owned
  orphan quarantine, offline task audit, and sanitized support export (Build 17)
- Durable 1,000/10,000-record startup budgets, actor-isolated search indexing,
  bounded-memory multi-gig import/backup proof, and schema 1–15 fixtures (Build
  18 candidate)

Run `apps/ios/scripts/run-complete-suite.sh` for all unit/integration checks and
Stories 001–013. The remaining final mockup comparison is tracked in the serial
[MVP completion release train](../../MVP_COMPLETION_PLAN.md), with executable
coverage mapped in [MVP_ACCEPTANCE_MATRIX.md](../../MVP_ACCEPTANCE_MATRIX.md).
