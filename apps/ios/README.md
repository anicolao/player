# Player for iOS

This directory contains the initial native SwiftUI scaffold and its deterministic launch-story test. The project is generated from `project.yml`; the generated `Player.xcodeproj` is committed so it can be opened directly and checked for reproducibility.

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

## Run the E2E launch story

```bash
apps/ios/scripts/run-e2e.sh
```

The runner owns a temporary simulator named `Player E2E`, normalizes its rendering state, builds the E2E configuration, runs the semantic launch assertions, exports the screenshot and generated walkthrough, and requires an exact pixel match with the committed baseline.

To intentionally record a reviewed baseline on the pinned environment:

```bash
PLAYER_RECORD_SCREENSHOTS=1 apps/ios/scripts/run-e2e.sh
```

See [E2E_GUIDE.md](../../E2E_GUIDE.md) for the complete contract.

## Current scaffold

- Library, Inbox, and Settings tabs
- Empty-library state and Files importer entry point
- Light-mode E2E configuration with animations disabled
- Accessibility identifiers and an explicit `ready:library-empty` state value
- One generated launch walkthrough and full-screen baseline
- Exact native sRGB RGBA screenshot comparator with zero differing pixels allowed

Import processing, persistence, metadata editing, and playback are specified in [MVP_DESIGN.md](../../MVP_DESIGN.md) but are not implemented yet.

