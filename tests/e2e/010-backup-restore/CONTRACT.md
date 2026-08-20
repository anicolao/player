# Story 010 backup and restore contract

## Scope and trust boundary

Story 010 proves production backup export, destructive reset, validated restore,
hostile-package rejection, and automatic database fallback. The E2E bootstrap
may seed deterministic records and generated managed bytes, inject a document
selection result, capture an exported package URL, and damage the primary
database only while the app is terminated. It must not implement package
encoding, validation, library replacement, checksum decisions, or database
fallback.

The app must validate a complete restore package before mutating the library.
Replacement commits the database and managed media as one recoverable boundary.
On any validation or commit failure, both remain byte-for-byte unchanged.

## Privacy and fixture contract

`PlayerUITests/Fixtures/SyntheticBackupRestore` contains only:

- one original generated 8,461-byte AAC M4B copied from the verified format fixture;
- an invented two-book descriptor with stable lowercase UUIDs;
- deterministic format-1/library-schema-14 metadata-only and including-media packages;
- deterministic checksum-mismatch, `../` traversal, and schema-999 packages.

No file is derived from `books/`, a local audiobook, discovered media tags,
private artwork, user paths, or network data. Fixtures and exported packages
are covered by `SyntheticBackupRestore.sha256`. Verification reproduces every
byte in a fresh temporary directory, checks Core Audio readability, inspects ZIP
entry names without extracting the traversal archive, proves the deliberate
checksum mismatch, and hashes the checked-in source before and after. UI probes
report only synthetic canonical UUIDs, counts, booleans, enum codes, and byte
totals; they never report paths or checksum strings.

Stable fixture IDs are:

```text
book 1       a1000000-0000-0000-0000-000000000001
book 2       a1000000-0000-0000-0000-000000000002
asset 1      a1000000-0000-0000-0000-000000000101
asset 2      a1000000-0000-0000-0000-000000000102
bookmark     a1000000-0000-0000-0000-000000000301
collection   a1000000-0000-0000-0000-000000000401
metadata export operation a1000000-0000-0000-0000-000000000501
media export operation    a1000000-0000-0000-0000-000000000502
restore operation         a1000000-0000-0000-0000-000000000503
```

## Bootstrap and document channels

The initial launch uses:

```text
-e2e -e2e-reset -e2e-fixture synthetic-backup-restore
```

The UI-test bundle supplies checked-in bytes only through:

```text
PLAYER_E2E_BACKUP_DESCRIPTOR_BASE64
PLAYER_E2E_BACKUP_AUDIO_BASE64
PLAYER_E2E_BACKUP_METADATA_PACKAGE_BASE64
PLAYER_E2E_BACKUP_MEDIA_PACKAGE_BASE64
PLAYER_E2E_BACKUP_TAMPERED_PACKAGE_BASE64
PLAYER_E2E_BACKUP_TRAVERSAL_PACKAGE_BASE64
PLAYER_E2E_BACKUP_TOO_NEW_PACKAGE_BASE64
```

Production `restore-backup` asks an injected document-acquisition boundary for
one URL. `-e2e-backup-input last-exported-media` returns the package created by
the production exporter earlier in the same persistent fixture root. The other
accepted values (`tampered`, `traversal`, `too-new`) stage the corresponding
checked-in bytes and return their URLs. The source checksum is sampled before
and after restore. There are no fixture-named buttons in the production UI.

The fixed clock is `2026-08-20T13:41:00Z`. Relaunch without `-e2e-reset` opens
the durable store and never reseeds. `-e2e-damage-primary-database` is accepted
only on a non-reset launch and flips deterministic bytes in the closed primary
database before the production persistence layer opens it. It does not touch
the automatic backup or invoke recovery.

## Settings surface and exact initial state

Settings exposes `settings-backup-restore`. Its destination is
`backup-restore-screen` and offers these production controls:

```text
export-backup-metadata
export-backup-media
restore-backup
erase-library-data
confirm-erase-library-data
```

The model-derived probes are:

```text
backup-library-probe
library:books=2:order=a1000000-0000-0000-0000-000000000001,a1000000-0000-0000-0000-000000000002:assets=2:current=a1000000-0000-0000-0000-000000000001:up-next=a1000000-0000-0000-0000-000000000001,a1000000-0000-0000-0000-000000000002

backup-metadata-probe
metadata:positions=a1000000-0000-0000-0000-000000000001@45000,a1000000-0000-0000-0000-000000000002@120000:finished=a1000000-0000-0000-0000-000000000002:bookmarks=a1000000-0000-0000-0000-000000000301@a1000000-0000-0000-0000-000000000001@42000:collections=a1000000-0000-0000-0000-000000000401(a1000000-0000-0000-0000-000000000002,a1000000-0000-0000-0000-000000000001)

backup-settings-probe
settings:rate=1.25:back=15:forward=30:rewind=true:rewind-max=20:fade=true:view=list

backup-integrity-probe
integrity:managed-files=2:managed-bytes=16922:checksums-valid=true:package-sources-unchanged=true
```

The bookmark label and note, both invented, are asserted through production
bookmark search after restore rather than emitted into a global hidden probe.

## Production export

Tapping `export-backup-metadata` and `export-backup-media` uses the same package
writer used outside E2E. The injected export sink retains the resulting URL and
independently reads the archive for the read-only `backup-export-probe`; it does
not construct or modify a package. Exact values are:

```text
export:operation=a1000000-0000-0000-0000-000000000501:mode=metadata-only:format=1:reader=1:library-schema=14:books=2:assets=2:media-files=0:media-bytes=0:manifest-valid=true:payload-valid=true:source-unchanged=true

export:operation=a1000000-0000-0000-0000-000000000502:mode=including-media:format=1:reader=1:library-schema=14:books=2:assets=2:media-files=2:media-bytes=16922:manifest-valid=true:payload-valid=true:source-unchanged=true
```

Metadata-only export preserves references and all library metadata but includes
no managed bytes. Media-inclusive export contains each managed asset under a
confined relative path and verifies each source while reading it. It excludes
staging, Trash, automatic database backups, temporary files, and E2E state.

## Erase, restore review, and atomic replacement

`erase-library-data` requires `confirm-erase-library-data`. The production
operation removes the two books and their managed copies plus dependent
positions, bookmarks, collections, queue state, and current-book state. It does
not delete either exported package. Exact empty probes are:

```text
library:books=0:order=none:assets=0:current=none:up-next=none
metadata:positions=none:finished=none:bookmarks=none:collections=none
integrity:managed-files=0:managed-bytes=0:checksums-valid=true:package-sources-unchanged=true
```

With `-e2e-backup-input last-exported-media`, tapping `restore-backup` opens
`restore-review-screen` only after central-directory safety, schema, manifest,
payload, media checksum, entry count, and uncompressed-size validation. Its
`restore-review-probe` is:

```text
restore:operation=a1000000-0000-0000-0000-000000000503:mode=including-media:format=1:reader=1:library-schema=14:books=2:assets=2:bookmarks=1:collections=1:media-files=2:media-bytes=16922:conflicts=0:strategy=replace-library:validated=true
```

The stable screen contains `restore-replace-library` and requires
`confirm-restore-replace-library`. The single proposed screenshot is captured
here because it uniquely communicates scope and destructive intent. Export,
moving, hostile error, and database fallback states remain nonvisual.

Successful replacement exposes `restore-result-probe`:

```text
restore:completed:operation=a1000000-0000-0000-0000-000000000503:books=2:assets=2:bookmarks=1:collections=1:managed-files=2:managed-bytes=16922:checksums-valid=true
```

All four initial probes must return byte-for-byte to their initial values.
Book Detail bookmark search must find bookmark
`a1000000-0000-0000-0000-000000000301` with label
`Opening Signal · 0:42` and note `Return to the quiet clue.`. Collection Detail
must retain b2 then b1. A process relaunch must preserve the restored result.

## Hostile package rejection

Each hostile case relaunches the same restored library without reset, selects
one injected checked-in URL through the production `restore-backup` control,
and exposes `backup-error-screen`, `backup-error-probe`,
`choose-another-backup`, and `cancel-backup-restore`. Values are:

```text
restore-error:code=checksum-mismatch:recoverable=true:library-unchanged=true:managed-unchanged=true:source-unchanged=true
restore-error:code=unsafe-path:recoverable=false:library-unchanged=true:managed-unchanged=true:source-unchanged=true
restore-error:code=library-schema-too-new:supported=14:found=999:recoverable=false:library-unchanged=true:managed-unchanged=true:source-unchanged=true
```

No hostile entry is extracted before archive-wide validation. No raw path,
checksum, decoder error, or package internals appear in visible copy or probes.

## Automatic database backup recovery

`erase-library-data` removes automatic database backups and resets the
automatic-backup generation counter to zero while preserving both portable
exports. Export, restore review, hostile validation failures, and ordinary
relaunches do not create or rotate an automatic backup. Successful
`replace-library` creates exactly one validated snapshot of the restored
database as generation 1.

After the restored state has been saved and the app terminated, a non-reset launch with
`-e2e-damage-primary-database` must cause ordinary store loading to reject the
primary, validate the automatic backup, restore it atomically, and retain the
damaged database only as non-user-visible diagnostics according to product
policy.

The UI presents `database-recovery-banner` with `dismiss-database-recovery`.
The read-only `database-recovery-probe` is:

```text
database-recovery:recovered=true:generation=1:books=2:assets=2:source=automatic:primary-replaced=true:managed-checksums-valid=true
```

The four exact library probes must still match. Recovery selects generation 1
without consuming any portable-operation or automatic-backup UUID, does not
increment or rotate the generation, and never rewrites managed media. General
retention is newest-first with at most five automatic backups and protects at
least the newest pre-migration snapshot.

## Screenshot scope

Only after the full programmatic journey is green, TestStepHelper may attach:

```text
000-restore-review.png
README.md
```

This frame contains fixed synthetic metadata only. No baseline is recorded by
the isolated scaffold task.
