# Offline recovery and support audit

Status: implemented and executable in Story 011

Bookshelf's core library has no account, server, metadata provider, telemetry, or
cloud synchronization dependency. The only networking API in the app target is
the listener owned by `ComputerReceiver`, which binds a private local receiver
only while the listener has explicitly opened **Receive from Computer**. Closing
that screen stops the receiver. The embedded uploader has no remote URL.

## Airplane Mode task matrix

| Task | Local dependency | Executable evidence |
| --- | --- | --- |
| Import from Files | security-scoped file URLs, streamed managed copy | Stories 002, 003, and 006; import/core tests |
| Browse and organize | versioned `Library.json` plus managed artwork | Story 008; library organization tests |
| Search | in-memory index derived from the local snapshot | Story 008; 10,000-book search test |
| Edit metadata and cover | atomic catalog transaction; source media unchanged | Story 004; metadata repair tests |
| Play and seek | AVFoundation reading managed media | Stories 002 and 005; playback tests |
| Save and jump to bookmarks | local catalog and position journal | Story 007; bookmark tests |
| Export and restore backup | local package, checksums, and system file destinations | Story 010; backup round-trip tests |
| Startup recovery | rotating local database copies and quarantine | Story 011; offline recovery tests |
| Export support diagnostics | allowlisted aggregate JSON written locally | Story 011; forbidden-data byte inspection |

The status bar remains deterministic in screenshots and does not claim that a
simulator has physically enabled Airplane Mode. Offline confidence instead
comes from dependency inspection plus executable task paths whose production
services accept no remote client. This avoids treating an icon as proof.

## Startup recovery contract

- A storage-container initialization error renders a retryable screen instead
  of calling `fatalError`.
- A catalog decode or compatibility failure keeps the recovery screen visible
  until exactly one retry, restore, or fresh-library transaction completes.
- Every rotating copy is decoded independently. Invalid copies are counted but
  never selected.
- Before a valid copy or empty catalog replaces the primary, the primary is
  moved into `Recovery/Quarantine` with an opaque generated name.
- App-owned top-level media, staging, and trash directories are associated only
  by UUIDs present in catalog records. Unknown UUID directories move to
  `Recovery/Orphans`; audiobook filenames are not used to infer ownership and
  bytes are not deleted.
- The post-recovery storage manifest is rebuilt from the reconciled filesystem
  and committed atomically.

## Diagnostic data boundary

The `.playersupport` report has an allowlisted schema containing only:

- report, app, build, and library-schema versions;
- creation time;
- aggregate book, asset, import, collection, bookmark, backup, and quarantine
  counts;
- a coarse startup issue code; and
- the static fact that local features do not require Internet.

It does not serialize or derive titles, contributors, descriptions, notes,
bookmark text, chapter names, source filenames, filesystem paths, media or
artwork checksums, receiver credentials, pairing secrets, playback positions,
position journals, sleep history, or other listening history. Unit and Story
011 fixtures place unique forbidden strings in these fields and inspect the
final exported bytes for their absence before the evidence passes.
