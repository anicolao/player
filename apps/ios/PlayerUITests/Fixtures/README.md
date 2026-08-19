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
