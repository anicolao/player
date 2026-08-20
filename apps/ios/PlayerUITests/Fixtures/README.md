# Audiobook test fixtures

`SyntheticAudiobook/` is a tiny, generated three-part audiobook. Its tones and
filenames are original test material, so the fixture is safe to commit and use
in CI. The three parts have distinct frequencies and durations so import order,
track transitions, seeking, and playback progress can be verified without
depending on speech or copyrighted media.

Verify and stage it into a new temporary directory with:

```sh
destination="$(mktemp -d)/SyntheticAudiobook"
apps/ios/scripts/fixtures/stage-synthetic-audiobook.sh "${destination}"
```

To reproduce it in a separate existing directory:

```sh
output_root="$(mktemp -d)"
apps/ios/scripts/fixtures/generate-synthetic-audiobook.sh "${output_root}"
```

The checked-in SHA-256 manifest detects accidental fixture changes. Exact
encoded bytes are supported only on the repository's pinned macOS/Xcode toolchain;
AAC encoder updates may intentionally require a reviewed manifest update.

`SyntheticFormats/` adds one original generated MP3 chapter and one original
generated M4B book. Their separate directories are direct production-inspector
fixtures rather than one mixed-format book. Verify every checked-in fixture with:

```sh
apps/ios/scripts/fixtures/verify-generated-fixtures.sh
```

Exact reproduction of the MP3 requires an explicitly supplied LAME 3.100
binary; the generator never downloads or installs tools:

```sh
export PLAYER_LAME_BINARY=/path/to/lame-3.100
output_root="$(mktemp -d)"
apps/ios/scripts/fixtures/generate-format-fixtures.sh "${output_root}"
```

With `PLAYER_LAME_BINARY` set, `verify-generated-fixtures.sh` generates two clean
MP3/M4B format-fixture copies, compares them byte-for-byte, and compares a clean
copy with the checked-in format fixtures. M4A/M4B MP4 timestamps are canonicalized
before hashing.

Stage either format into a new production-import input directory with:

```sh
apps/ios/scripts/fixtures/stage-format-fixture.sh mp3 /absolute/new/mp3-input
apps/ios/scripts/fixtures/stage-format-fixture.sh m4b /absolute/new/m4b-input
```

## Messy multifile and Unicode selection

`SyntheticMessyMultifile/` derives eight unique M4As from the generated tones.
It deliberately combines a selected folder, four loose selected files, accented
and Greek characters, conflicting filename stems, and numeric parts `2` and
`10`. A deterministic MP4 `free` box makes repeated tone sources checksum-unique
without changing their playable audio or adding private metadata.

Verify exact regeneration and Core Audio readability with:

```sh
apps/ios/scripts/fixtures/verify-messy-multifile-fixture.sh
```

Stage the preserved folder tree into a new import input directory with:

```sh
apps/ios/scripts/fixtures/stage-messy-multifile-fixture.sh \
  /absolute/new/messy-multifile-input
```

The E2E acquisition source passes the `Signal Δ — Folder` directory plus each of
the four files in `Loose Files` to the normal multi-selection importer. The
fixture JSON contains only stable synthetic IDs and expected evidence categories;
it is not an importer shortcut.

## Private local fixtures

Large or copyrighted books must stay outside source control. To stage one into
an isolated simulator import directory, opt in explicitly:

```sh
export LOCAL_AUDIOBOOK_FIXTURE=/private/path/to/a/book-directory
apps/ios/scripts/fixtures/stage-local-audiobook.sh \
  /absolute/new/simulator-import-directory
```

The destination must not exist. The runner rejects symlinks and empty files,
copies into that new directory, and compares SHA-256 snapshots before and after
the copy. It never prints the source path, filenames, tag values, or checksums.
If validation fails, it removes only the new directory it created.

Local-book E2E tests must use neutral assertions such as imported part count,
total-duration tolerance, ready state, and playback state. They must not take
screenshots, attach the UI hierarchy, or include discovered titles, authors,
cover art, filenames, metadata, or fixture paths in test names and failure
messages. The system Files-picker journey should use the synthetic fixture;
private staging should enter the same production import pipeline immediately
after file selection.

The known 30-part private sample also has a read-only, non-UI smoke contract:

```sh
export LOCAL_AUDIOBOOK_FIXTURE=/private/path/to/the/book-directory
apps/ios/scripts/fixtures/smoke-private-audiobook.sh
```

This does not stage media. It scans all packets with Core Audio and asserts only
neutral facts: 30 sequential track tags, one consistent grouping key, expected
audio format, aggregate duration tolerance, aggregate storage size, and unchanged
pre/post content hashes. It suppresses paths, filenames, metadata, artwork, and
hashes. It never launches XCTest and therefore cannot record a screenshot or UI
hierarchy attachment.

## Portable backup and restore

`SyntheticBackupRestore/` contains one verified generated M4B, an invented
two-book library descriptor, deterministic metadata-only and including-media
portable backups, and three hostile packages: one checksum mismatch, one `../`
entry, and one unsupported library schema. The manifest shape matches portable
backup format 1, minimum reader 1, and library schema 14. No bytes or metadata
come from `books/`, a local audiobook, user artwork, discovered tags, or a
network source.

Verify clean reproduction, playable media, exact safe entries, and the declared
hostile properties with:

```sh
apps/ios/scripts/fixtures/verify-backup-restore-fixture.sh
```

The verifier never extracts the traversal package. It compares a fresh
reproduction byte-for-byte and proves the checked-in source manifest remains
unchanged. Runtime probes expose only synthetic lowercase UUIDs, counts,
booleans, format/schema numbers, and byte totals—not paths or digest values.
