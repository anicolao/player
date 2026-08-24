# Backup and restore

Status: implemented for MVP in TestFlight Build 15

## Listener flow

Open **Settings → Backup**. Choose either **Metadata and audio** (the portable
default) or **Metadata only**, then tap **Export Library Backup** and choose a
destination in the system document picker. Player prepares a
`.playerbackup` package and removes its temporary working copy when the picker
closes.

To restore, tap **Choose Player Backup**, select one package, review the replace
confirmation, and tap **Restore Backup**. Player does not change the current
library until the manifest, artwork, and all included audio pass integrity
checks.

A metadata-only restore succeeds only when the corresponding managed audio is
already present on the same device and matches every recorded checksum. For a
new or erased device, use **Metadata and audio**.

## Portable format v1

`.playerbackup` is an Apple package directory with:

- `manifest.json`, encoded with stable sorted keys and ISO-8601 dates;
- a complete normalized `LibrarySnapshot` for books, metadata, positions,
  journals, organization, preferences, sleep history, and bookmarks;
- an artwork digest catalog, even though artwork bytes remain in the snapshot;
  and
- for a media-inclusive backup, one payload at each existing managed
  `Media/<book-id>/<asset-id>.<extension>` path.

The manifest records its own format version, the producing library schema,
backup kind, creation date, media byte counts, and SHA-256 checksums. Imports
from newer portable formats or newer library schemas stop with an explicit
compatibility message.

Ephemeral Inbox jobs, share handoff receipts, active sleep timers, Trash
transactions, and device-specific storage inventories are not portable and are
excluded from the exported snapshot.

## Integrity and transaction rules

- Export and restore copy media in 1 MiB chunks and never allocate a whole
  audiobook in memory.
- Export fails if managed bytes no longer match the immutable asset byte count
  and checksum.
- Restore rejects absolute, traversal, duplicate, missing, extra, or
  catalog-mismatched media paths.
- Restore verifies every payload into a private transaction directory before
  replacing live media.
- The previous Media directory is retained inside that transaction until the
  database save succeeds, then removed. A failure rolls the media move back.
- Restoring the same package repeatedly replaces the prior managed directory;
  it does not create duplicate audio files.

## Automatic database backups

The JSON store creates a backup before reading an older schema and after a new
durable snapshot is saved. Byte-identical consecutive snapshots are
deduplicated, and only the three newest copies remain. Settings shows the
newest valid copy and offers **Restore Latest Database Backup**. These small
automatic copies contain database state only; managed audio remains in place.

Corrupt automatic files are not presented as valid recovery choices. Startup
recovery when the primary database itself cannot open belongs to T18; T16
provides the validated copies and the in-app recovery action.

## Verification

- `LibraryBackupTests` covers media-inclusive and metadata-only round trips,
  repeated restore, tampering, compatibility errors, and backup rotation.
- Story 010 exports, clears, restores, verifies one physical audio copy, and
  opens the restored book at its exact listening position.
