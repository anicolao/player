# Player

> A local-first audiobook player for iPhone that turns scattered, imperfect audio files into a clean, dependable library.

**Player** is a working title for an iOS app for people who bring their own DRM-free audiobooks. Its defining feature is not another play button: it is a forgiving path from “these files are somewhere on my phone or cloud drive” to “this is one correctly ordered, beautifully presented book.”

The repository contains the native SwiftUI product, its local import and
playback core, and nine deterministic end-to-end product journeys. Builds are
distributed to an internal TestFlight group while the remaining MVP completion
gates are closed. [VISION.md](VISION.md) explains the product direction,
[MVP_DESIGN.md](MVP_DESIGN.md) defines the first useful target,
[UX_DESIGN.md](UX_DESIGN.md) defines the interaction and visual system,
[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) contains the original tracer
plan, and [MVP_COMPLETION_PLAN.md](MVP_COMPLETION_PLAN.md) is the active release
train. [BACKUP_AND_RESTORE.md](BACKUP_AND_RESTORE.md) specifies the portable
backup format and recovery guarantees, and
[ACCESSIBILITY_AUDIT.md](ACCESSIBILITY_AUDIT.md) records the accessibility task
matrix and reproducible evidence.

## The product promise

1. **Getting a book in is easy.** Import an M4B, a folder of MP3s, or a ZIP from Files, iCloud Drive, AirDrop, the share sheet, or a nearby computer.
2. **Player makes a good first guess and shows its work.** It groups tracks, determines order, reads embedded chapters and tags, detects duplicates, and proposes metadata without silently overwriting anything.
3. **Fixing a library takes seconds, not a desktop toolchain.** Edit title, author, narrator, series, sequence, cover, and chapter names on the phone, individually or in batches.
4. **Playback never loses the listener’s place.** Position, bookmarks, settings, and sleep history are durable. Downloads remain useful without a network connection.
5. **The listener stays in control.** Originals are preserved, metadata changes are reversible, broad cloud-drive access is unnecessary, and core local playback does not require an account or subscription.

## Product experience and active MVP target

### Import without ceremony

- Files picker, share sheet, AirDrop/document open, a private local web
  receiver, and iPhone Mirroring drag and drop where Apple supports it
- Single-file books and multi-file folders
- ZIP archives with safe extraction and useful progress reporting
- Initial support for DRM-free M4B, M4A, and MP3; additional formats will be added only when they can be handled reliably
- A persistent, inspectable import queue with cancellation and retry
- Duplicate and partial-import detection
- Clear, actionable errors that identify the affected file
- Explicit local-network receiving while its on-device screen is open; no
  Internet upload or account is required

Files selected through Apple’s document picker are copied into Player’s managed storage. The source is never modified. A future export flow may write cleaned metadata or produce a consolidated M4B, but only as an explicit action.

### A real import inbox

Every new item lands in an inbox before joining the library. Player proposes:

- which files belong to the same book;
- track and chapter order, using tags, filenames, folder structure, and duration;
- title, subtitle, authors, narrators, series, and series position;
- cover art and description;
- warnings for missing tracks, suspicious ordering, malformed chapters, and conflicting tags.

The listener can accept the proposal, correct just the uncertain fields, split or merge groups, and undo the result. Confidence and provenance are visible; guesses never masquerade as facts.

### Library management made for audiobooks

- Continue Listening, Up Next, Recently Added, Finished, and Downloaded views
- Browse by author, narrator, series, genre, collection, and folder
- Search across metadata, notes, bookmarks, and original filenames
- Sort by series position, title, author, duration, date added, or progress
- Filters for unplayed, in progress, finished, missing metadata, and import warnings
- Multi-select and batch editing
- Custom collections, favorites, reading list, archive, and manual ordering
- Per-book file inspection and storage management
- Checksum-verified metadata-only or media-inclusive library backup and restore

### Playback that earns trust

- Exact position recovery, including after termination or an interrupted audio session
- Chapter navigation and both chapter-level and whole-book timelines
- Configurable skip intervals and fine-grained speed control
- Per-book speed, voice boost, and playback preferences
- Smart rewind based on time away
- Sleep timer by duration, end of chapter, or end of track, with extend/reset controls
- Bookmarks with optional notes and a short captured context window
- Lock Screen, Control Center, Bluetooth, and headset remote commands
- VoiceOver, Dynamic Type, sufficient contrast, and controls that do not rely on color alone

Later releases may add CarPlay, Siri/Shortcuts, silence shortening, Apple Watch
offline playback, widgets, listening statistics, iCloud progress sync, and
read-along support. These are not allowed to compromise position integrity or
offline reliability.

## Scope by release

| Stage | Outcome | Included |
| --- | --- | --- |
| **Foundation** | One book imports and plays reliably | M4B/M4A/MP3, managed local storage, embedded metadata and chapters, durable position, background and remote controls |
| **MVP** | A listener can build and maintain a useful library entirely on iPhone | Multi-file/ZIP import, import inbox, manual metadata and cover editing, grouping and ordering, search/filter/series, bookmarks, sleep timer, speed, smart rewind, backup/export |
| **MVP completion** | The app is dependable in daily life | Portable backup/restore, VoiceOver and largest-text audit, robust interrupted receiver imports, recovery diagnostics, and performance validation with large libraries |
| **Later** | The library follows the listener | CarPlay, opt-in iCloud sync, Audiobookshelf and other source adapters, Apple Watch, advanced audio, metadata-provider plugins, cleaned-file/M4B export |

The roadmap is capability-based, not a release-date promise. Reliability gates are defined in [VISION.md](VISION.md#roadmap-and-release-gates).

## Product and engineering guardrails

- **Native and offline-first.** Swift and SwiftUI, with AVFoundation/MediaPlayer for playback and Apple-platform integrations.
- **One canonical book model.** A book can contain one or many source files; the user should not have to convert files merely to make chapters work.
- **Atomic persistence.** Playback position and edits are committed safely and recoverably. Database backups and migrations are tested product features.
- **Non-destructive metadata.** The app’s library record is separate from the imported media. Any future tag writing or conversion produces an explicit export.
- **No hidden network dependency.** Imported books, covers, metadata, search, and playback work in Airplane Mode.
- **Least-privilege access.** Prefer Apple’s Files picker and security-scoped access over requesting an entire cloud account.
- **Observable failure.** Imports and syncs have inspectable state, useful errors, and retry controls.
- **Performance is a feature.** Library interactions should remain responsive with thousands of books and imports should not monopolize battery, memory, or storage.

## What Player will not do

- Circumvent DRM or import protected files from commercial services
- Sell audiobooks or become a discovery storefront
- Require a self-hosted server for the core experience
- Upload a listener’s library or listening history by default
- Silently reorganize, rename, retag, or delete source files
- Add generative features that send book audio to a third party without explicit, informed consent

## Development

The iPhone app lives in `apps/ios/` and is generated reproducibly with XcodeGen. The pinned local setup is Xcode 26.6, iOS 26.5, iPhone 17, and XcodeGen 2.46.0.

With Nix installed, generate the project, build the app, boot a persistent development simulator, install Player, and launch it with one command:

```bash
nix develop
```

The development simulator and its app data are reused on later runs. To enter the same development shell without building or launching Simulator, run `PLAYER_SKIP_SIMULATOR_LAUNCH=1 nix develop`.

For the one-time Apple Developer Program and App Store Connect handoff needed
for unattended signing and TestFlight deployment, follow
[TESTFLIGHT_SETUP.md](TESTFLIGHT_SETUP.md). Never place Apple API private keys
in this repository or in chat.

Generate the Xcode project:

```bash
apps/ios/scripts/generate-project.sh
```

Run the launch E2E story and require a canonical match against the committed
screenshot. Canonical sRGB channels may differ by at most 8/255 for decoder
rounding; no pixel may move, be masked, or exceed that channel allowance:

```bash
apps/ios/scripts/run-e2e.sh
```

The runner creates and deletes its own `Player E2E` simulator. See [apps/ios/README.md](apps/ios/README.md) for native project details and [E2E_GUIDE.md](E2E_GUIDE.md) for the semantic and canonical-pixel verification contract.

## Contributing

Product feedback is especially useful when it includes the starting file layout, import route, desired grouping/order, and what the app actually did. Please do not attach copyrighted audiobook files to public issues; use a minimal synthetic fixture that reproduces the problem.

Contributions should align with the priorities and non-goals in
[VISION.md](VISION.md) and the active completion gate in
[MVP_COMPLETION_PLAN.md](MVP_COMPLETION_PLAN.md).

## Legal and license

Player is intended for DRM-free audio that a listener owns or is authorized to use. It will not include DRM circumvention.

Player is free software licensed under the [GNU General Public License v3.0](LICENSE).
