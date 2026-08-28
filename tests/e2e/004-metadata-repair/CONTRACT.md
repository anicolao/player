# Metadata repair E2E contract

## Fixture and identifiers

`PlayerUITests/Fixtures/SyntheticMetadataRepair` contains only generated legal
test material:

| File | Neutral fact |
| --- | --- |
| `metadata-repair-source.m4b` | 8,461-byte generated AAC M4B; SHA-256 `6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7` |
| `metadata-repair-original-cover.png` | Deterministic 32×32 synthetic cover |
| `metadata-repair-replacement-cover.png` | Distinct deterministic 32×32 synthetic replacement |
| `synthetic-metadata-repair-fixture.json` | Stable IDs, proposed values, provenance, and repair operations |

`SyntheticMetadataRepair.sha256` covers all four files. The clean generator
copies the already-generated M4B and creates PNG bytes without a network, photo
library, private metadata, or copyrighted artwork.

Stable IDs are:

```text
job      80000000-0000-0000-0000-000000000001
proposal 80000000-0000-0000-0000-000000000002
asset    80000000-0000-0000-0000-000000000003
book     80000000-0000-0000-0000-000000000004
```

## Bootstrap boundary

The test launches with:

```text
-e2e -e2e-reset -e2e-fixture synthetic-metadata-repair
```

The UI-test bundle supplies the checked-in bytes through:

```text
PLAYER_E2E_METADATA_AUDIO_BASE64
PLAYER_E2E_METADATA_ORIGINAL_COVER_BASE64
PLAYER_E2E_METADATA_REPLACEMENT_COVER_BASE64
```

The bootstrap writes the audio into the isolated source root and seeds the
production proposal/revision model with deterministic inspection evidence. It
must not implement editing, locking, commit, undo, checksum, or view state.
Replacement-cover injection substitutes only after the production source
chooser is shown and `Choose Photo` is tapped. `Replace Cover` may not bypass
that chooser in E2E. The injected bytes call the same production setter as a
normal picked image and retain photo-library provenance.

## Initial proposal and provenance

`review-import-job-80000000-0000-0000-0000-000000000001` opens the existing
review screen. `edit-metadata` opens `metadata-editor-screen` with:

```text
metadata:proposal:revision=0:dirty=false
```

Metadata field values use this exact schema:

```text
value=<display-or-empty>|source=<embedded-tag|user|user-clear>|confidence=<high|user>|locked=<true|false>|cleared=<true|false>
```

Initial accessibility identifiers and values are:

```text
metadata-field-title
value=The Brass Lantern|source=embedded-tag|confidence=high|locked=false|cleared=false

metadata-field-authors
value=Mira Sol|source=embedded-tag|confidence=high|locked=false|cleared=false

metadata-field-narrators
value=Anika Reed|source=embedded-tag|confidence=high|locked=false|cleared=false

metadata-field-series
value=Night Signals #4|source=embedded-tag|confidence=high|locked=false|cleared=false

metadata-cover-state
cover=original|source=embedded-artwork|locked=false
```

Confidence describes inspected evidence only. User-authored and explicitly
cleared fields use `confidence=user`, never a fabricated percentage.

## Repair and lock semantics

The test performs six editing actions in one editor draft; they resolve to five
field mutations because replacement and cropping are one final cover value:

1. Replace the contents of `metadata-title-input` with `The Amber Signal`, then
   tap `metadata-apply-title`. A user edit automatically locks the title.
2. Tap `metadata-clear-narrators`. Explicit clear is durable provenance, not an
   absent optional value, and is automatically locked.
3. Tap `metadata-lock-series`. This locks the inspected value without changing
   its embedded provenance.
4. Tap `metadata-remove-cover`, producing
   `cover=none|source=user-clear|locked=true`.
5. Tap `metadata-replace-cover`, require the source chooser again, then tap
   `Choose Photo`. This consumes the injected synthetic PNG through the normal
   photo-library cover setter and produces
   `cover=replacement|source=user|locked=true`.
6. Open `Crop`, set the production zoom and horizontal sliders to their
   deterministic end positions, and require
   `preview=x:0.500:y:0.250:width:0.500:height:0.500:rotation:0.0` before
   applying. The preview and saved projection are decoded from the retained
   replacement bytes; the original replacement image is not destructively
   rewritten.

The final changed fields are:

```text
metadata-field-title
value=The Amber Signal|source=user|confidence=user|locked=true|cleared=false

metadata-field-narrators
value=empty|source=user-clear|confidence=user|locked=true|cleared=true

metadata-field-series
value=Night Signals #4|source=embedded-tag|confidence=high|locked=true|cleared=false
```

The editor reports `metadata:proposal:revision=0:dirty=true`: unsaved draft
changes do not advance the persisted proposal revision. Tapping
`save-metadata-repair` submits all five field operations as one atomic metadata
transaction. The proposal review revision advances once per mutation within
that transaction, and Review Import reports
`proposal:ready:1-book:1-tracks:0-warnings:revision-5`.

Locks are metadata-policy state: later scans may refresh unlocked inspected
values, but cannot overwrite a locked user value, explicit clear, cover, or
explicitly locked inspected value without an unlock action.

## Commit, checksum invariants, and undo

`metadata-integrity-probe` reads production source/managed files and exposes:

```text
audio:source=<sha256>:managed=<none|sha256>:source-unchanged=<true|false>
```

Before commit, source is the fixture checksum and managed is `none`. After
`add-import-to-library`, both source and managed equal the fixture checksum.
Metadata and artwork are stored as book/provenance state; no mutation writes
tags into either audio file.

After commit, `metadata-persistence-probe` must report the committed title from
the production `Library.json`. The test terminates the app, constructs and
launches a fresh `XCUIApplication` without reset, and requires the same durable
state before opening Book Detail. There, `book-metadata-probe` reports:

```text
metadata:book:title=The Amber Signal:authors=1:narrators=0:series=Night Signals #4:cover=replacement:locked=title,narrators,series,cover
```

`book-metadata-provenance-probe` reports:

```text
provenance:title=user:authors=embedded-tag:narrators=user-clear:series=embedded-tag:cover=user
```

`book-cover-render-state` also reports the exact persisted crop and confirms
that the displayed cover is a rendered projection. After undo, it reports no
crop and no rendered projection, proving that undo restores the original
embedded cover bytes as well as their metadata.

The commit transaction retains revision 0 as the single available prior
metadata snapshot. `undo-metadata-repair` restores that snapshot atomically but
does not delete the committed book or move/rewrite managed audio. The probes then
report:

```text
metadata:book:title=The Brass Lantern:authors=1:narrators=1:series=Night Signals #4:cover=original:locked=none
provenance:title=embedded-tag:authors=embedded-tag:narrators=embedded-tag:series=embedded-tag:cover=embedded-artwork
audio:source=6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7:managed=6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7:source-unchanged=true
```

The consumed undo control disappears. Persistence must complete before each
observable state changes so process restart cannot expose half-repaired fields.

## Stable visual evidence

After all programmatic assertions for each state, the test attaches exactly:

```text
000-metadata-provenance.png
001-cropped-cover-preview.png
002-repaired-book-detail.png
003-undo-restored-book-detail.png
```

The test also attaches generated `README.md`. Every screenshot contains only
fixed synthetic metadata and art.
