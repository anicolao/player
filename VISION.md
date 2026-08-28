# Product vision

## In one sentence

Bookshelf makes a personal audiobook collection feel as effortless and dependable as a first-party library, without taking ownership or control away from the listener.

## Why this should exist

People who own DRM-free audiobooks face an odd split in today’s iOS market:

- storefront apps offer a polished experience but are built around books bought inside their ecosystems;
- standalone players can play local files, but import and repair often remain fragile or manual;
- self-hosted systems offer rich server-side management, but add infrastructure and can make mobile browsing, downloads, or progress dependent on successful synchronization;
- desktop tools can repair tags, chapters, and file structure, but turn “listen to this book” into a multi-app maintenance job.

The opportunity is to join two products that are usually separate: a great audiobook player and a humane personal-library manager. Bookshelf should accept the collection the listener already has—one M4B, seventy poorly named MP3s, or anything in between—and guide it into shape on the device where it will be heard.

This is not a bet that nobody has built a good iOS audiobook player. Several have. It is a bet that **import certainty, reversible metadata management, and local-first ownership can form a better center of gravity** than either playback alone or a server connection alone.

## Research snapshot

Research was reviewed on August 18, 2026. It included recent and long-running discussions on Reddit, Apple Support Communities, MobileRead, GitHub issue trackers, official product pages, and the Audiobookshelf documentation. Community posts are qualitative signals, not a statistically representative survey; feature claims were cross-checked against current official listings where possible.

### What listeners repeatedly ask for

#### 1. “Let me get my files in, regardless of where they are.”

Listeners describe workflows involving Files, iCloud Drive, Dropbox, AirDrop, desktop file sharing, external drives, ZIPs, Plex, and Audiobookshelf. Multi-file imports are especially easy to get wrong or make tedious. A long-running BookPlayer report describes imports that simply produced no visible result, while another explains an iOS file-association workaround needed for MP4 audio. Those examples point to a broader requirement: an import must be observable, resumable, and explain failures rather than silently doing nothing. ([BookPlayer import issue](https://github.com/TortugaPower/BookPlayer/issues/625), [AirDrop/file association discussion](https://github.com/TortugaPower/BookPlayer/issues/461))

Current players validate the breadth of demand. BookPlayer supports AirDrop, Files, desktop file sharing, ZIPs, Audiobookshelf, and Jellyfin; Bound supports Files, Dropbox, OneDrive, and Wi-Fi upload. Import flexibility is table stakes, but reliability and a coherent post-import review experience remain room for differentiation. ([BookPlayer listing](https://apps.apple.com/us/app/bookplayer/id1138219998), [Bound listing](https://apps.apple.com/us/app/bound-audiobook-player/id1041727137))

#### 2. “Treat a folder of tracks as one book—and help me clean it up.”

The loudest metadata complaints are mundane and costly: several MP3s that should be one book, missing or unusable chapters, absent covers, inconsistent series numbers, empty narrator fields, and chapter names such as “Track 01.” People report moving among ffmpeg, Mp3tag, m4b-tool, scripts, and server-side matchers just to prepare a title. Others describe a bad automated match leaving hundreds of books with broken series, duplicate entries, or wrong-language metadata. ([cleanup workflow discussion](https://www.reddit.com/r/audiobookshelf/comments/1t7fg8z/does_anyone_else_spend_more_time_cleaning/), [metadata failure discussion](https://www.reddit.com/r/audiobookshelf/comments/1s982bv/i_think_i_messed_up_all_my_meta_data/))

The lesson is not “automate every field.” It is “make the common cleanup path fast, show confidence and provenance, support batches, and make every automated change undoable.” Users with carefully curated libraries distrust a matcher that is fast but destructive.

#### 3. “Never lose my place.”

Position memory is foundational. People switch apps specifically because a general media player loses their position. Self-hosted users report sync gaps between downloaded mobile playback and browser playback, and describe sync as a major class of open issues. Bookshelf must first make local position storage exceptionally durable; cross-device sync should arrive only with explicit conflict handling and inspectable status. ([local-player discussion](https://www.reddit.com/r/audiobooks/comments/13t5ea1/looking_for_audiobook_app_for_iphone/), [Audiobookshelf sync discussion](https://www.reddit.com/r/audiobookshelf/comments/1kig06p/progress_sync_failure_between_ios_app_downloaded/))

#### 4. “Offline means the whole useful experience.”

An audio download alone is not enough. Listeners want to browse covers, descriptions, authors, series, progress, and history while a server is asleep or unreachable. Community discussions explicitly call out libraries that disappear away from the network and ask for full metadata caching. ([offline-library discussion](https://www.reddit.com/r/audiobookshelf/comments/1sdb8na/ios_app_with_cached_metadata/), [offline-use discussion](https://www.reddit.com/r/audiobookshelf/comments/1g13yof/how_am_i_supposed_to_use_the_app_offline/))

For Bookshelf, the local database is therefore the primary experience, not a temporary cache. Remote sources synchronize into it; they do not define whether the library exists.

#### 5. “Give me audiobook controls, everywhere I listen.”

The stable baseline is clear across BookPlayer, Bound, and Prologue: chapters, fine-grained playback speed, smart rewind, configurable skip intervals, sleep at a time or chapter boundary, bookmarks, Lock Screen controls, CarPlay, and per-book settings. Voice boost/equalization, Siri, widgets, iPad, and Apple Watch are increasingly expected by power users. ([BookPlayer listing](https://apps.apple.com/us/app/bookplayer/id1138219998), [Bound listing](https://apps.apple.com/us/app/bound-audiobook-player/id1041727137), [Prologue features](https://prologue.audio/))

These are not the strategic wedge, but omitting them makes the import advantage irrelevant. Playback must be calm, fast, and trustworthy enough to disappear into a commute, workout, or bedtime routine.

#### 6. “Do not make me surrender privacy or pay forever to hear my own files.”

In community feedback, listeners object to granting a new app access to an entire cloud drive, prefer on-device processing, and regularly praise one-time purchases or free local playback. The product should use system document pickers where possible, keep analysis on device by default, and separate a sustainable paid upgrade from the basic ability to hear files the user owns. ([cloud-access concern](https://www.reddit.com/r/audiobooks/comments/1skl5uf/i_built_an_iphone_audiobook_player_for_people_who/), [player recommendations and pricing preferences](https://www.reddit.com/r/audiobooks/comments/1v77mmh/whats_your_favorite_ios_audiobook_player_app_for/))

### Competitive reality

The market is active, and the bar is high:

| Product/model | Demonstrated strength | Opportunity left open |
| --- | --- | --- |
| Apple Books/storefront | Integrated Apple experience | Awkward personal-file workflows and limited on-device metadata control |
| BookPlayer/local-first | Broad import routes, strong playback, CarPlay/Watch, open source | Make import review, confidence, batch cleanup, and reversible metadata the central workflow |
| Bound/local + cloud | Straightforward cloud/Wi-Fi import and mature playback | Deeper library repair, large-library tooling, and modern native continuity |
| Prologue/Plex + Audiobookshelf | Excellent server-backed library, playback, CarPlay, and Watch support | A complete server-free workflow for local files and on-device management |
| Audiobookshelf/server | Rich matching, chapter editing, merging, multi-user sync | No-server setup, iOS-native local ownership, and reliable offline-first simplicity |

Audiobookshelf itself demonstrates that lookup, cover matching, chapter editing, metadata embedding, and multi-file M4B merging are valued parts of audiobook management. Bookshelf should bring the highest-frequency parts of that workflow to iPhone without trying to reproduce an entire home server. ([Audiobookshelf overview](https://audiobookshelf.org/docs/documentation/introduction/))

## Who Bookshelf is for

### The file owner

Has DRM-free M4B and MP3 books from publishers, CDs, public-domain sources, or personal conversions. Wants to AirDrop or select files and listen, not learn tagging software.

### The careful curator

Has hundreds or thousands of titles. Cares about narrator, edition, cover, series order, and consistent naming. Wants powerful batch operations, but refuses automation that cannot be reviewed or undone.

### The self-hoster

May already run Audiobookshelf, Plex, or Jellyfin. Wants downloads and progress to behave predictably when the server or network is unavailable. Values an adapter to the local library, not a UI that becomes empty offline.

### The everyday listener

Mostly sees Continue Listening and Now Playing. Needs instant resumption, comprehensible chapters, sleep controls, CarPlay, Bluetooth behavior, and accessibility. Benefits from clean metadata without wanting to manage it.

These are modes, not mutually exclusive market segments. One person may be a curator on Sunday and an everyday listener all week.

## Jobs to be done

- **When someone sends me audiobook files,** help me turn them into one correctly ordered book so I can start listening without using a computer.
- **When metadata is incomplete or wrong,** give me a trustworthy suggestion and a quick way to correct it so my library stays coherent.
- **When I stop listening for any reason,** preserve exactly where I was and give me enough rewind context when I return.
- **When I leave home or lose connectivity,** keep my library, covers, notes, and downloaded books fully usable.
- **When I am driving, exercising, or falling asleep,** expose the right safe controls without making me handle the phone.
- **When my collection grows,** help me find, batch-organize, back up, and move it without locking the work inside the app.

## North-star experience

A listener receives a ZIP containing 23 MP3 files. They share it to Bookshelf.

Bookshelf immediately shows an import card with extraction and analysis progress. It recognizes one likely book, sorts the files despite inconsistent zero-padding, reads the available tags, and flags two uncertain track positions. It proposes a cover and series match, clearly labeling which values came from the files, folder name, and online catalog. The listener swaps the two tracks, accepts the match, and taps Add.

The book appears in Continue Listening and plays from chapter one. The listener changes speed to 1.35×; that preference stays with the book. At bedtime they choose “End of chapter.” The next morning, Smart Rewind restores a little context. In Airplane Mode, the cover, chapter list, bookmarks, and library search all still work. Months later, the listener can export a backup containing the original media plus portable library metadata.

This whole flow should feel ordinary.

## Product principles

### Local is the source of truth

Playback never waits for login, metadata lookup, or sync. Network services enrich and synchronize a library that already works locally.

### Make uncertainty visible

Metadata has provenance and confidence. Bookshelf says “from embedded tag,” “inferred from filename,” or “matched online,” and asks for review when evidence conflicts.

### Automate reversibly

Imports, batch edits, regrouping, and matches create undoable library transactions. Originals are immutable unless the listener explicitly exports a new file.

### Model books, not tracks

One book may contain one file, many files, embedded chapters, inferred chapters, or a mixture. The interface consistently presents a book and its navigable sections.

### Reliability before reach

Local position integrity comes before sync. iPhone playback comes before Watch playback. A reliable Files import comes before many remote connectors.

### Progressive power

The default path is import, confirm, play. Detailed provenance, chapter repair, batch editing, and diagnostics are close at hand but never forced on a casual listener.

### Respect attention and ownership

No store feed, advertising, engagement notifications, or streak shame. Listening statistics, if added, serve the listener. Data leaves the device only through an action or integration they chose.

### Accessible by construction

VoiceOver labels, Dynamic Type, logical focus, large targets, high contrast, non-color status, reduced motion, and alternatives to precision scrubbing are acceptance criteria, not a polish phase.

## The product system

```text
Files / AirDrop / Share / ZIP / remote adapter
                       │
                       ▼
              Persistent import queue
                       │
                       ▼
       Grouping + ordering + metadata evidence
                       │
                       ▼
          Review inbox (accept / fix / undo)
                       │
                       ▼
     Local library + managed immutable media
          │             │              │
          ▼             ▼              ▼
       Browse        Playback       Backup/export
                         │
                         ▼
             Optional sync destinations
```

### Import pipeline

The import pipeline is a durable state machine, not a modal spinner:

1. **Acquire** a copy into a staging area and record source, byte size, and checksum.
2. **Validate** type, readability, archive safety, and available storage before committing.
3. **Inspect** container metadata, artwork, duration, tracks, and embedded chapters.
4. **Group and order** with explainable heuristics. Never rely on lexicographic filename order alone.
5. **Enrich** from optional metadata providers only after local evidence is available.
6. **Review** conflicts and low-confidence fields in the inbox.
7. **Commit atomically** into managed storage and the library database.
8. **Clean staging safely** after success or an explicit cancellation.

Closing the app, receiving a call, losing a cloud connection, or running out of space must lead to a resumable or clearly recoverable state. The user can inspect each file’s status and retry only the failed part.

### Metadata and chapter model

The canonical library record should support:

- title, sort title, subtitle, description, language, publication date, and identifiers;
- multiple authors and narrators with canonical display and sort names;
- multiple series memberships with decimal or textual position where needed;
- genres, tags, collections, edition, abridgement status, and publisher;
- cover art with source and crop history;
- source-file mapping, duration, codec details, and original filenames;
- embedded, file-derived, imported, or manually defined chapters;
- field-level provenance, confidence, lock state, and edit history.

The first release does not need every field in its UI. The model should avoid painting the product into a music-tag-shaped corner.

Suggested metadata is staged as a diff. A listener can accept individual fields, prefer one source, lock curated values against future refreshes, apply changes across a series, and undo a completed operation. A rescan never resurrects a value the listener intentionally cleared.

### Library

The home screen prioritizes the next listening action: Continue Listening, Up Next, and Recently Added. Deep browsing supports authors, narrators, series, collections, genres, and folders without turning the top level into a wall of categories.

Large-library behavior is a release criterion. Search and common filters should feel immediate with 10,000 book records. Covers load progressively. Indexing, hashing, and waveform or silence analysis run incrementally with thermal and battery awareness.

### Playback

Position is stored frequently, on pause, on route change, on interruption, when entering background, and during orderly termination. A small append-only playback journal protects against a corrupted or partially committed latest value. The UI may expose recent position history so an accidental scrub or stale sync can be reversed.

The player supports:

- play/pause, chapter navigation, configurable forward/back skips, and precise seeking;
- speed presets plus fine adjustment, remembered per book;
- smart rewind scaled to time away, with user-controlled bounds;
- sleep after a duration, at chapter end, or at track end, with fade and extend;
- bookmarks with notes and optional automatic context timestamps;
- clear chapter and whole-book remaining time without ambiguous scrubbers;
- interruption and route-change behavior appropriate for calls, navigation prompts, AirPods, Bluetooth, AirPlay, and CarPlay.

Silence shortening and audio processing should be off by default, measurable for battery cost, and tested to avoid clipping intentional dramatic pauses.

### Sync and integrations

Remote systems are adapters, never special cases threaded through the UI. An adapter can discover items, acquire audio, push/pull progress, and map metadata. Its capabilities are explicit; unsupported operations remain local.

Sync needs a visible state and conflict policy. A newer timestamp alone is not always authoritative: a long offline session can be newer in meaning but older in server receipt time. Position events should retain device, book edition/file identity, listening interval, and monotonic sequence where available. On a material conflict, Bookshelf offers both positions with surrounding chapter/time context.

## Priorities

### Must be excellent for MVP

- Import from Files, share sheet, AirDrop, and ZIP
- M4B/M4A/MP3, including very long files and multi-file books
- Explainable grouping and natural track ordering
- Embedded tag, artwork, and chapter reading
- Inbox review; manual split, merge, reorder, and metadata editing
- Managed local storage, duplicate detection, and storage preflight
- Durable playback position and recent-position recovery
- Background/Lock Screen/Bluetooth controls
- Chapters, speed, skip controls, smart rewind, sleep timer, and bookmarks
- Continue Listening, series, search, sorting, filters, and finished state
- Full offline behavior, backup/export of library data, VoiceOver, and Dynamic Type
- Import diagnostics, safe library/database recovery, and large-library
  performance and migration evidence

### Expected for 1.0

- Metadata lookup with field-level acceptance and provenance
- Batch edit and series cleanup
- CarPlay
- Localization-ready UI beyond the MVP's English evidence
- Provider-assisted batch workflows and integration-level accessibility audits

### Valuable later

- Opt-in iCloud library/progress sync
- Audiobookshelf first, then other server/source adapters based on demand
- Finder/Apple Devices drop box, Shortcuts automation, and watched-folder import
  where iOS permits (the foreground local web receiver already ships)
- Apple Watch control and, later, standalone downloads/playback
- Voice boost, equalizer, silence shortening, and listening statistics
- Chapter waveform editing, safe consolidation/export to M4B, and embedded-tag export
- EPUB pairing and on-device read-along position mapping

### Explicit non-goals

- DRM removal or direct extraction from protected commercial libraries
- An audiobook store, recommendation feed, social network, or review platform
- Mandatory accounts, servers, or cloud storage
- Supporting every audio codec before the core formats are reliable
- Cross-platform UI parity at the expense of a native iOS experience
- Cloud transcription or AI metadata processing by default
- Silent source-file mutation

## Business model principles

The exact model remains open, but the constraints are not:

- A listener can import and play local books without advertising or an ongoing subscription.
- Payment prompts never interrupt playback or hold the listener’s library hostage.
- A one-time Pro unlock is the preferred starting model for advanced management and platform integrations.
- Recurring charges are considered only for features with real recurring costs, such as hosted services, and must be optional.
- Export and data portability are never paywalled as a retention tactic.

## Success measures

### Activation

- At least 90% of valid single-file imports reach playable state without intervention.
- At least 80% of representative multi-file fixtures are grouped and ordered correctly on first proposal.
- Median time from choosing a valid local file to playable library item is under 30 seconds, excluding unavoidable file-copy time.

### Trust and reliability

- No known position-loss defect ships; position recovery succeeds across the interruption test matrix.
- Fewer than 0.5% of import attempts end in an unexplained failure state.
- Every automated metadata change can be traced to a source and undone.
- Airplane Mode passes all local library, search, cover, chapter, bookmark, and playback acceptance tests.

### Ongoing value

- Most successful first imports lead to playback in the same session.
- Listeners with 100+ books can find and start a target book without manually browsing folders.
- Support reports trend toward identifiable file/provider edge cases rather than “nothing happened” or “lost my place.”

Metrics must be obtainable through opt-in, privacy-preserving analytics or volunteered diagnostics. The product will not collect a catalog of book titles or listening history merely to measure itself.

## Roadmap and release gates

### Phase 0 — Corpus and foundations

Build a legally shareable synthetic fixture corpus before the visible app: varied tags, Unicode and numbered filenames, corrupt artwork, multiple chapter schemes, huge durations, ZIP edge cases, and interrupted copies. Define the canonical book model, import states, playback journal, and migration strategy.

**Gate:** The import analyzer and playback engine pass deterministic fixture tests; no UI is required to prove the model.

### Phase 1 — One book, never lose the place

Implement managed storage, single-file import, metadata/chapter inspection, local library persistence, background playback, remote commands, and position recovery.

**Gate:** A long M4B survives force quit, reboot, interruptions, route changes, and repeated migration tests without losing or materially moving position.

### Phase 2 — The import inbox

Add multi-select, folders, ZIPs, grouping, natural ordering, duplicate detection, manual repair, covers, metadata editing, and atomic commit/undo.

**Gate:** The representative messy-library corpus can be imported entirely on iPhone, and every failure is actionable and recoverable.

### Phase 3 — Daily-driver MVP

Add series and collection browsing, search/filter, bookmarks, speed, smart
rewind, sleep timer, backup/export, storage tools, accessibility coverage,
startup recovery, sanitized diagnostics, and large-library evidence.

**Gate:** A test cohort can use Bookshelf as its primary local audiobook app for four weeks with no position loss or source-file damage.

### Phase 4 — 1.0 integration quality

Add provider-assisted metadata, batch workflows, CarPlay, localization
groundwork, and optimizations or diagnostic tools beyond the MVP evidence.

**Gate:** Core interactions meet performance targets at 10,000 records; CarPlay and VoiceOver task audits pass; recovery from low storage and interrupted import is verified.

### Phase 5 — Continuity

Add opt-in iCloud sync, Audiobookshelf integration, and then Watch or other adapters according to validated demand.

**Gate:** Offline changes reconcile without silent position loss, duplicates, or curated-metadata overwrite. Sync state and conflicts are understandable to nontechnical users.

## Risks and hard choices

### Scope inflation

Playback, metadata management, servers, Watch, CarPlay, conversion, and read-along could each become a product. The release gates enforce an order: local import and playback reliability first.

### Metadata quality and provider terms

No catalog is complete, edition matching is ambiguous, and provider licensing or APIs can change. The product must work with embedded/manual metadata, isolate providers behind adapters, store provenance, and never represent an uncertain match as authoritative.

### iOS storage and background constraints

Large books stress temporary storage, memory, cloud downloads, and background execution. Imports require storage preflight, streaming hashes and copies, resumable checkpoints, bounded concurrency, and honest foreground requirements when iOS cannot guarantee completion.

### Sync conflict and identity

The same title may exist in different encodings with different durations or chapter layouts. Sync cannot assume title equality or raw seconds alone. Stable content identity and normalized position mapping need design before public sync.

### Destructive convenience

Writing tags and merging files feels convenient until a crash, provider mismatch, or storage failure damages the only copy. Bookshelf starts with an immutable managed copy plus reversible database metadata. Cleaned-media export can be added later as a separate transaction.

### Sustainability

A no-subscription preference must coexist with ongoing maintenance across iOS releases. Price the durable product honestly, keep recurring infrastructure optional, and avoid promising expensive hosted services through a one-time purchase.

## Open product questions

- What working name should replace “Bookshelf,” and what identity best communicates ownership plus calm listening?
- What minimum iOS version balances modern audio/background APIs against device longevity?
- Which metadata providers offer the best legal, stable coverage for editions, narrators, series, and covers?
- Should the MVP support linked external files as an expert option, or only managed copies with predictable availability?
- Which portable sidecar format best preserves edits, provenance, chapters, bookmarks, and progress across export/import?
- Is a consolidated M4B export important enough to precede cloud/server sync?
- Which advanced feature has strongest validated demand after CarPlay: iCloud sync, Audiobookshelf, Watch, silence shortening, or read-along?

These questions should be answered with prototypes, fixture tests, and interviews—not feature-count comparisons alone.

## Research references

- [BookPlayer feature listing](https://apps.apple.com/us/app/bookplayer/id1138219998)
- [BookPlayer source repository](https://github.com/TortugaPower/BookPlayer)
- [Bound feature listing](https://apps.apple.com/us/app/bound-audiobook-player/id1041727137)
- [Prologue product page](https://prologue.audio/)
- [Audiobookshelf overview and tools](https://audiobookshelf.org/docs/documentation/introduction/)
- [Audiobookshelf community app landscape](https://audiobookshelf.org/docs/documentation/community/community-apps/)
- [Reddit: cleanup before Audiobookshelf import](https://www.reddit.com/r/audiobookshelf/comments/1t7fg8z/does_anyone_else_spend_more_time_cleaning/)
- [Reddit: metadata damage and recovery](https://www.reddit.com/r/audiobookshelf/comments/1s982bv/i_think_i_messed_up_all_my_meta_data/)
- [Reddit: iOS player experiences and metadata concerns](https://www.reddit.com/r/audiobooks/comments/13t5ea1/looking_for_audiobook_app_for_iphone/)
- [Reddit: offline metadata caching](https://www.reddit.com/r/audiobookshelf/comments/1sdb8na/ios_app_with_cached_metadata/)
- [Reddit: progress synchronization failure](https://www.reddit.com/r/audiobookshelf/comments/1kig06p/progress_sync_failure_between_ios_app_downloaded/)
- [MobileRead: series management and iOS player requirements](https://www.mobileread.com/forums/showthread.php?nojs=1&t=323085)
- [Apple Support Community: personal audiobook metadata limitations](https://discussions.apple.com/thread/250728842)
