# MVP design specification

## Document status

- **Product:** Player, working title
- **Target:** Native iPhone MVP
- **Minimum OS:** iOS 17
- **Design baseline:** iPhone 17, portrait
- **Last updated:** August 23, 2026
- **Companion documents:** [README.md](README.md), [VISION.md](VISION.md), [E2E_GUIDE.md](E2E_GUIDE.md)

This document defines a buildable MVP, not the eventual full product. It is the source of truth for what the first useful test cohort receives, how the experience behaves, and what must be proven before the target is called complete.

## MVP outcome

A listener can import a DRM-free M4B, M4A, MP3, multi-file selection, folder, or ZIP using only an iPhone; review and correct how the files become a book; organize the resulting local library; listen with audiobook-specific controls; quit or reboot without losing position; and back up the library record.

The MVP succeeds when a cohort can replace its current local-file player for four weeks without desktop metadata tools, silent import failures, source-file damage, or lost playback position.

## Scope boundary

### Included

- iPhone-native SwiftUI interface
- DRM-free M4B, M4A, and MP3 playback
- Single-file, multi-file, folder, and ZIP import through Files and the share sheet
- Managed app storage; source files remain unchanged
- Durable, inspectable import queue
- Embedded metadata, cover, and chapter extraction
- Explainable grouping and natural file ordering
- Import review, split, merge, reorder, edit, cancel, retry, and undo
- Manual title, subtitle, author, narrator, series, series position, description, and cover editing
- Local library browsing, search, sorting, filtering, collections, and finished state
- Background playback, Lock Screen, Control Center, Bluetooth, and headset commands
- Chapter navigation, speed, configurable skips, Smart Rewind, sleep timer, and bookmarks with notes
- Durable position history and recovery from accidental seek or stale state
- Offline operation and portable library backup/export
- VoiceOver, Dynamic Type, Reduce Motion, and sufficient contrast
- Deterministic E2E walkthroughs with canonical pixel baselines (8/255 maximum
  per-channel decoder allowance, with no spatial tolerance)

### Deliberately excluded

- DRM removal or commercial-account extraction
- Metadata lookup from an online catalog
- Audiobookshelf, Plex, Jellyfin, WebDAV, SMB, hosted upload, or an always-on
  receiver (the explicit, foreground-only local receiver is included)
- iCloud synchronization or any account system
- CarPlay, Apple Watch, widgets, Siri, and Shortcuts
- Silence shortening, equalizer, waveform editing, transcription, or read-along
- Writing tags back into source media or producing consolidated M4B files
- iPad-specific layouts
- Storefront, recommendations, social features, and listening streaks

These exclusions keep the MVP centered on local import, repair, and trustworthy listening. Provider-assisted metadata and ecosystem integrations begin only after the local model and recovery behavior pass their release gates.

## Experience principles

1. **Open to the next useful action.** A new user sees one clear import action. A returning listener sees Continue Listening.
2. **No invisible work.** Copying, extracting, inspecting, grouping, committing, retrying, and failing are distinct observable states.
3. **Show the evidence.** A proposed title or order identifies whether it came from embedded tags, a filename, a folder, or manual input.
4. **Keep originals immutable.** Every edit changes Player’s library record. The selected source is never renamed, retagged, moved, or deleted.
5. **Make mistakes cheap.** A listener can undo a committed import, restore a previous field value, or return to a recent playback position.
6. **Present books, not audio tracks.** File boundaries appear only where they help inspection or repair.
7. **Offline is normal.** No screen in the MVP has a required network state.
8. **Power stays progressive.** Casual listeners can accept a good proposal immediately; curators can inspect every file and field.

## Information architecture

The root is a three-tab interface:

| Tab | Purpose | Root state |
| --- | --- | --- |
| **Library** | Find and resume committed books | Empty library, library home, or search results |
| **Inbox** | Observe and resolve imports | Empty, processing queue, review needed, or recoverable failure |
| **Settings** | Playback defaults, storage, backup, accessibility, and diagnostics | Grouped settings list |

A compact mini-player appears immediately above the tab bar whenever a current book exists. It is absent before first playback and while the full player is presented. Tapping it opens Now Playing. The player is a full-screen cover rather than a fourth tab.

Navigation follows these rules:

- Switching tabs preserves each tab’s navigation stack during the session.
- Relaunch selects Library unless an import share request or media remote action provides a more specific destination.
- A pending review adds a count badge to Inbox; processing alone uses a subtle progress badge and does not imply user action.
- Deep links and notifications are outside MVP scope, but route types must not assume tabs are the only entry points.

## Visual language

The initial golden launch screen establishes the direction: quiet, bookish, warm, and native rather than a dense media dashboard.

### Color roles

| Token | Light appearance intent | Usage |
| --- | --- | --- |
| `background` | Warm parchment (`#F6F2EA` vicinity) | Primary screen field |
| `surface` | Near-white warm card | Cards, cover placeholder, sheets |
| `ink` | Near-black blue charcoal | Primary text and icons |
| `secondary` | Neutral charcoal gray | Supporting text and metadata |
| `accent` | Burnt orange (`#B0442A` vicinity) | Primary action, selected tab, progress |
| `success` | Muted forest green | Imported, downloaded, finished |
| `warning` | Ochre | Review needed, uncertain ordering |
| `error` | Deep red | Failed or unsafe import |

Exact source values live in code, meet WCAG contrast requirements in context, and have dark-appearance equivalents before dark mode ships. Status never relies on color alone.

### Typography and spacing

- Use Apple system type and semantic text styles; do not freeze point sizes for body content.
- Large navigation titles identify top-level places.
- Book titles use headline or title styles with two-line truncation in shelves and no truncation on detail screens.
- Metadata uses subheadline/body styles; provenance uses caption.
- Base spacing unit is 4 points, with common gaps of 8, 12, 16, 24, and 32.
- Minimum hit target is 44×44 points; primary bottom actions are at least 52 points high.
- Cards use 16–24 point continuous corners. Shadows are low contrast and never the only boundary.

### Motion

- Import cards move between queue sections with short system animations.
- Progress changes animate only when they convey causal continuity.
- Reduce Motion replaces moves/scales with crossfades or immediate state changes.
- The E2E build disables all animations before the first view is created.

## Screen specifications

### 1. Launch and restoration

The launch screen uses the same background family as Library to avoid a white flash. App startup has four semantic states:

| State value | Visible result | Exit condition |
| --- | --- | --- |
| `starting:database` | Branded progress view | Database opens or recovery is required |
| `recovering:database` | Recovery explanation and restore choices | User chooses a valid recovery path |
| `ready:library-empty` | Empty Library | First book commits |
| `ready:library-populated` | Library home | Immediate |

Normal startup should not briefly render the empty state before populated content loads. Restoration resolves local metadata and current playback position before reporting ready. Import analysis may continue independently after the library becomes ready.

The scaffold implements and tests `ready:library-empty`.

### 2. Empty Library

Visible hierarchy, top to bottom:

1. Large `Library` navigation title.
2. Centered book-stack symbol on a warm surface tile.
3. Heading: `Build your listening library`.
4. Explanation: supported formats, Files source, and source-file preservation.
5. Burnt-orange `Add Audiobook` primary button.
6. Library, Inbox, and Settings tab bar.

`Add Audiobook` opens the system document picker. Cancelling returns to the identical empty state without an error banner. Selecting content immediately creates queue records and routes to Inbox.

Accessibility state: the screen exposes identifier `library-screen` and value `ready:library-empty`. The button exposes `add-audiobook`.

### 3. Populated Library

The Library home prioritizes resumption and coherent browsing:

- Toolbar: profile-free title, Search action, and Add action.
- `Continue Listening`: horizontally scrolling cards for books with progress greater than zero and less than finished. The first card is large enough to show cover, title, current chapter, percent, and remaining time.
- `Up Next`: user-ordered compact row; hidden when empty.
- `Recently Added`: two-column cover grid with title, author, and progress ring.
- `Browse`: rows for Series, Authors, Narrators, Collections, and All Books.

The listener can switch All Books between grid and list. The choice persists locally. Long-pressing a book offers Play, Add to Up Next, Mark Finished/Unfinished, Edit Details, Add to Collection, and Remove.

Removing presents a choice between removing the library record while retaining managed audio for undo, or deleting managed audio. The latter identifies bytes reclaimed and remains recoverable until the app’s trash retention period expires.

### 4. Search, sort, and filters

Search covers normalized title, subtitle, author, narrator, series, tags, collection names, original filenames, bookmark notes, and chapter names. Results update from a local index.

All Books supports:

- sort by title, author, series position, recently added, duration, or progress;
- ascending/descending where meaningful;
- filters for unplayed, in progress, finished, missing metadata, warnings, and format;
- a visible summary such as `23 books · In progress · Series order`;
- one-tap Clear All.

Sort and filters persist until cleared. A zero-result screen states which filters are active and offers Clear Filters; it does not resemble an empty library.

### 5. Import source and queue

The system picker accepts M4B, M4A, MP3, ZIP, and folders. Multiple selection is enabled. Share-sheet imports enter the same pipeline and open Inbox after acquisition begins.

Each selected top-level item creates an import job with a stable identifier. Inbox groups jobs into:

- **Needs Review**
- **In Progress**
- **Ready to Add** when review is optional
- **Failed**
- **Recently Added**, retained for undo during the current retention window

An import card displays source name, detected book count, stage, determinate byte progress when known, and the next available action. The app never uses one indefinite spinner for the entire pipeline.

### 6. Import states and recovery

| State | Required information | Available actions |
| --- | --- | --- |
| `queued` | Source name and queue position | Cancel |
| `acquiring` | Bytes copied/total and available space | Cancel |
| `extracting` | Archive entry count and current safe path | Cancel |
| `inspecting` | Files inspected/total | Cancel |
| `grouping` | Candidate book count | Cancel |
| `needsReview` | Warning count and confidence summary | Review, Cancel |
| `ready` | Book count and storage cost | Add, Review, Cancel |
| `committing` | Items committed/total | No destructive action |
| `committed` | Destination book links and Undo | View, Undo |
| `failedRecoverable` | Plain-language cause and affected file | Retry, Change Selection, Cancel |
| `failedTerminal` | Why the content is unsafe or unsupported | View Details, Remove |

App termination during any pre-commit stage leaves a checkpoint. Relaunch resumes when safe or returns the job to a truthful recoverable state. A commit is atomic per proposed book: no partially visible book may enter Library.

Storage preflight occurs before copying. ZIP extraction rejects absolute paths, parent traversal, links escaping staging, unreasonable expansion ratios, and entries beyond configured size/count limits.

### 7. Review import

Review uses a navigation stack with one proposal per detected book.

The summary shows:

- proposed cover, title, author, narrator, series, sequence, duration, and file count;
- confidence status: Ready, Check Details, or Ordering Problem;
- warnings with direct links to the field or track involved;
- primary `Add to Library` and secondary `Edit` actions.

An expandable Evidence section lists every field’s selected value, alternatives, and provenance. Provenance labels are `Embedded tag`, `Filename`, `Folder name`, `File order`, or `You`. No MVP value comes from the network.

For a batch, `Add All Ready Books` commits only warning-free proposals. Items requiring review remain in Inbox.

### 8. Group and order editor

The editor presents candidate books as sections and source files as draggable rows. Each row shows original filename, duration, parsed disc/track number, and warnings.

Actions:

- reorder within a book;
- move selected tracks to another book;
- split selected tracks into a new book;
- merge candidate books;
- define one file per chapter or respect embedded chapters;
- reset to the analyzer’s proposal;
- preview the first/last five seconds of a selected track when audio is valid.

Natural ordering compares explicit disc/track tags first, then numeric filename components (`2` before `10`), then localized text. Conflicting evidence triggers review; it never silently picks a low-confidence order.

### 9. Metadata editor

Editable MVP fields:

- cover;
- title and sort title;
- subtitle;
- one or more authors;
- one or more narrators;
- series name and position;
- description;
- genres/tags;
- language, publication year, publisher, edition, and abridged status.

Fields show provenance and can be locked. `Clear` is a durable user choice, not an invitation for a future rescan to repopulate the value. Undo restores the last committed edit transaction.

Cover actions are Use Embedded, Choose Photo, Choose File, Remove, and Crop. The original image and crop transform are retained so a later crop is non-destructive.

### 10. Book detail

The detail screen contains:

- large cover with title, author, narrator, series link, and duration;
- primary Play/Resume button with exact resume context;
- progress and last-listened summary;
- Add to Up Next, Mark Finished, Edit, and overflow actions;
- description with collapsed/expanded state;
- chapter list with duration and listened state;
- bookmarks preview;
- Files & Details disclosure for format, source names, size, and warnings.

Tapping a chapter begins at its start after confirmation if doing so would abandon material progress. A finished book can be replayed without first changing its finished state.

### 11. Mini-player

The mini-player shows cover thumbnail, title, chapter, Play/Pause, and a progress affordance. It never displays a whole-book scrubber in the tab-bar-sized surface. Swipe gestures are not required for core operation.

State identifier: `mini-player`; value includes `paused|playing`, stable book ID, chapter index, and integer elapsed milliseconds in E2E builds.

### 12. Now Playing

The full player prioritizes unambiguous controls:

1. Dismiss handle and output-route action.
2. Square cover, allowed to shrink for accessibility sizes.
3. Title, author, current chapter, and chapter count.
4. Chapter scrubber by default, labeled elapsed and remaining.
5. Main controls: Previous Chapter, Back, Play/Pause, Forward, Next Chapter.
6. Speed, Sleep, Chapters, and Bookmark actions.
7. Whole-book progress as text; a separate whole-book scrubber is available only through an explicitly labeled mode.

Default skip intervals are 15 seconds back and 30 seconds forward. Both are configurable. Remote commands use the same values.

Speed ranges from 0.5× to 3.0×. The sheet offers recent/favorite presets and 0.05× adjustment. Speed is stored per book, falling back to the global default.

### 13. Smart Rewind

After resuming:

- less than 30 seconds away: no rewind;
- 30 seconds to 10 minutes: 5 seconds;
- 10 minutes to 1 hour: 15 seconds;
- more than 1 hour: 30 seconds.

The listener can disable Smart Rewind or change the maximum. Rewind never crosses the start of the current logical chapter. The position journal records the pre-rewind location so Undo Resume Rewind can be offered briefly.

### 14. Sleep timer

Presets: 10, 15, 30, 45, and 60 minutes; End of Chapter; End of Track; Custom. The active timer shows remaining time on Now Playing and the mini-player. A configurable shake-to-extend behavior is excluded from MVP.

At expiry, audio fades over five seconds and position is saved at the actual stop point. Reopening within ten minutes offers `Resume with context`, which rewinds from the stop point according to the sleep history rather than treating the interval as an ordinary pause.

### 15. Bookmarks

Adding a bookmark is one tap and immediately stores book, file, chapter, exact position, date, and a generated label. The optional editor adds a note. Bookmark lists are searchable and sort by position or date. Deleting supports undo.

No audio clip or transcription is captured in the MVP. “Context” means timestamps and nearby chapter identity.

### 16. Settings

Groups:

- **Playback:** default speed, skip intervals, Smart Rewind, sleep fade, interruption behavior.
- **Library:** default view/sort, finished threshold, import review policy.
- **Storage:** used bytes, staging bytes, trash, per-book storage list, clear recoverable files.
- **Backup:** export library package, import backup, last successful backup.
- **Accessibility:** app-specific high contrast and reduce decorative artwork options; system settings remain authoritative.
- **About & Diagnostics:** version, licenses, privacy statement, export sanitized support bundle.

Destructive storage actions state exact scope and estimated bytes. They never combine removing a library record, deleting managed audio, and deleting a source file into one ambiguous action.

## Domain model

Identifiers are stable UUIDs unless a content-derived identity is explicitly named.

### Core records

- `Book`: display metadata, sort metadata, state, duration, progress summary, artwork reference.
- `Contributor`: canonical display/sort name and roles such as author or narrator.
- `SeriesMembership`: series identifier, display name, position string, numeric sort components.
- `AudioAsset`: managed URL, original filename, byte count, checksum, container/codec, duration.
- `PlaybackSegment`: ordered mapping from book timeline to asset time range.
- `Chapter`: title, start/end on book timeline, source kind, listened state.
- `PlaybackPosition`: current book time, chapter context, asset mapping, update sequence.
- `PositionEvent`: append-only recent history for recovery and later sync.
- `Bookmark`: stable book position, chapter snapshot, label, note, created/updated dates.
- `ImportJob`: source descriptors, staging paths, stage, progress, error, proposal IDs.
- `BookProposal`: proposed grouping/order, metadata field candidates, confidence, warnings.
- `MetadataValue`: value, provenance, confidence, lock/cleared state, edit transaction.
- `Collection`: name, manual order, book memberships.

Deleting a contributor or series label is not allowed while referenced; edits normalize or merge records transactionally.

## Persistence and file layout

The database and media store are separate:

```text
Application Support/
├── Library.sqlite
├── Backups/
├── Media/<book-id>/<asset-id>.<extension>
├── Artwork/<artwork-id>.<extension>
├── Staging/<import-job-id>/
└── Trash/<transaction-id>/
```

- Imported bytes stream into Staging while a checksum is computed.
- Commit moves validated files into the book directory and updates the database in one recoverable transaction.
- Staging and Trash have manifests; orphan cleanup never guesses from filenames.
- Database migrations are versioned and tested against fixtures from every shipped schema.
- Automatic rotating database backups occur before migration and after a clean significant mutation batch.
- The portable backup contains a versioned JSON manifest, artwork, optional media, and checksums. Export without media is always available.

## Playback integrity contract

Position writes occur:

- at a bounded interval while playing;
- immediately on pause and seek;
- on chapter/file transitions;
- on audio interruption and route change;
- when entering background;
- before replacing the current book;
- when the sleep timer stops playback.

The current position is a compact snapshot backed by a recent append-only event journal. On launch, Player selects the newest internally consistent event, not merely the last database row written. A material jump can be undone from recent history.

Acceptance tolerance is at most 500 milliseconds behind the last acknowledged position and never ahead of it after orderly pause. Crash recovery may resume slightly behind, never beyond audio the listener heard.

## Error language

Every error answers:

1. What happened?
2. Which file or book is affected?
3. Is the source safe and unchanged?
4. What can the listener do now?

Examples:

- `“Chapter 07.mp3” could not be read. The original is unchanged. Choose a replacement or remove this track from the proposal.`
- `This ZIP needs 2.4 GB to unpack, but 1.7 GB is available. Free space or choose a smaller archive.`
- `These files disagree about track 4. Review their order before adding the book.`

Never show a raw framework error as the primary message. Diagnostics may include the underlying domain/code without paths or book metadata unless the listener opts in.

## Accessibility contract

- Every control has a concise label, value, hint where needed, and stable identifier for tests.
- Reading order matches the visible task order.
- Cover images use the book title as alternative text only when the same title is not adjacent; decorative art is hidden.
- Progress conveys elapsed and remaining time, not only a percentage or ring.
- Drag-only editing has Move Up, Move Down, Move to Book, and rotor alternatives.
- Scrubbers have adjustable actions and direct time-entry alternatives.
- All layouts work through the largest accessibility text sizes without hiding actions or requiring horizontal text scrolling.
- VoiceOver announcements report completed import stages and failures, not every progress increment.
- Minimum contrast is 4.5:1 for normal text and 3:1 for large text and essential graphical controls.
- Reduce Motion and Differentiate Without Color are honored.

## Deterministic test design

The testing scheme follows [E2E_GUIDE.md](E2E_GUIDE.md). A screenshot is evidence of layout, while XCUI assertions are evidence of application state. Neither substitutes for the other.

### E2E hooks

The E2E build accepts:

- `-e2e`
- `-e2e-reset`
- `-e2e-fixture <fixture-name>`
- fixed locale, language, content-size category, and time-zone values

Fixtures control database content, media files, clock, identifiers, checksums, import progress events, failure injection, and playback events. Production code receives these through dependency boundaries; views do not branch on fixture names.

Each screen root exposes a semantic state value, for example:

- `ready:library-empty`
- `ready:library-populated`
- `import:inspecting:3-of-8`
- `import:needs-review:ordering`
- `player:paused:<book-id>:<position-ms>`

The value is asserted before capture. Nonvisual effects—position writes, file moves, remote-command registration, and backup contents—also require programmatic assertions.

### Golden-image rules

- Full-screen `XCUIScreen` captures include normalized system chrome.
- Every step uses the unified helper to assert, capture, name, attach, and document.
- Expected and actual PNG sets must match exactly.
- Dimensions must match exactly.
- PNGs are decoded to canonical sRGB RGBA.
- Every channel of every pixel must match; allowed difference count is zero.
- No masking dynamic regions. Dynamic inputs are fixed instead.
- No automatic baseline writes in pull-request CI.
- CI uploads actual screenshots and the `.xcresult` even when comparison fails.

### Required story backlog

| Story | Principal proof | Key captures |
| --- | --- | --- |
| `001-ios-launch` | App restores a ready empty library | Empty Library |
| `002-import-m4b` | One valid book moves through observable stages | Queued, inspecting, ready, committed |
| `003-import-multifile-zip` | Natural order and ZIP safety produce one proposal | Extracting, order review, committed book |
| `004-repair-metadata` | Field provenance, clear/lock, batch series edit, undo | Proposal, editor, corrected detail |
| `005-play-and-restore` | Position survives pause, termination, and relaunch | Now Playing, restored position, history |
| `006-import-failure` | Low storage and corrupt track failures are actionable | Preflight failure, partial-file review |
| `007-sleep-and-bookmark` | Timer and bookmark persist correct context | Timer active, stopped, bookmark detail |
| `008-find-large-library` | Search/sort/filter semantics remain correct | Populated library, filtered results |
| `009-accessibility-layouts` | Largest text and VoiceOver alternatives retain actions | Large-text core screens |

Unit and integration tests cover parsers, ordering, chapter mapping, transactions, migration, position journaling, ZIP defenses, and backup round trips. E2E tests do not replace those faster checks.

## Performance budgets

- Ready Library state: within 1 second after process launch for 1,000 books and within 2 seconds for 10,000 books on the reference simulator fixture.
- Search result update: within 100 milliseconds after query debounce for 10,000 books.
- Scroll: no synchronous metadata parsing, hashing, image decode, or database write on the main actor.
- Position write: acknowledged locally within 100 milliseconds.
- Import progress: first observable queued/acquiring state within 500 milliseconds of picker return.
- Memory: multi-gigabyte files are streamed; no operation loads an entire audio file or archive entry into memory.
- Storage: preflight includes source copy, extraction peak, database/artwork overhead, and safety margin.

These are measured budgets, not reasons to add longer UI-test timeouts. Work exceeding two seconds exposes intermediate observable states.

## Privacy and security

- No account, analytics SDK, advertising SDK, Internet request, or remote
  service in the MVP. The receiver makes a listener-initiated local-network
  connection only while its screen is open.
- Document-picker access is limited to items the listener selects.
- Security-scoped access is held only as long as acquisition requires.
- Support bundles exclude titles, contributor names, notes, filenames, paths, and listening history by default.
- Backup export is explicit and uses the system destination picker.
- ZIP input is hostile until validated.
- Logs never contain raw book metadata at normal levels.

## MVP acceptance checklist

The MVP target is complete only when:

- every Included capability has an implementation and acceptance test;
- all required E2E stories pass semantic assertions and canonical-pixel comparison on the pinned environment;
- the malformed/long-file/multi-file/Unicode/ZIP fixture corpus imports without unexplained failure;
- no known position-loss, source-mutation, database-corruption, or unrecoverable-import defect remains;
- airplane-mode tests cover import from local Files, browsing, search, editing, playback, bookmarks, and backup creation;
- migration and backup restore are tested from every shipped schema;
- VoiceOver and largest Dynamic Type task audits pass for import, correction, playback, and recovery;
- 10,000-record library performance stays within budget;
- every destructive action has precise scope, confirmation proportional to impact, and a tested recovery path;
- App Store privacy declarations match observed behavior.

## Decisions deferred until after MVP evidence

- Online metadata provider selection and licensing
- One-time purchase boundary and exact price
- iCloud schema and progress-conflict UX
- First remote-library adapter
- CarPlay information architecture
- Apple Watch control versus standalone playback
- Cleaned M4B export priority
- Dark-mode visual baseline

Deferral means the model should leave room for these capabilities; it does not authorize placeholder buttons, nonfunctional settings, or premature infrastructure in the MVP.
