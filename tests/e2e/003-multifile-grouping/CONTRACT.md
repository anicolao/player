# Messy multifile grouping E2E contract

This contract keeps Story 003's acquisition, model, and accessibility hooks
stable while the walkthrough README and reviewed screenshots are regenerated.

## Legal deterministic source

`PlayerUITests/Fixtures/SyntheticMessyMultifile` contains eight generated-tone
M4A files. Their filenames deliberately combine non-ASCII characters, inconsistent
stems, a folder, loose selections, and numeric components including `2` and `10`.
No private book, copied metadata, spoken content, or generated artwork is used.

`SyntheticMessyMultifile.sha256` covers the eight media files and `fixture.json`.
The generator derives unique, valid files from the legal synthetic M4As by adding
a deterministic MP4 `free` box. Clean generation must reproduce exact bytes.

## Acquisition bootstrap

The test launches with:

```text
-e2e -e2e-reset -e2e-fixture messy-multifile-unicode -e2e-acquisition SyntheticMessyMultifile
```

Tapping production `add-audiobook` asks the injected E2E document-acquisition
source for five top-level URLs: the `Signal Δ — Folder` directory plus four files
inside `Loose Files`. The source then calls the normal
`importAudioSelection(from: [URL])` boundary. It must not seed proposals directly
or bypass acquisition, inspection, grouping, ordering, staging, or persistence.

After acquisition:

- `acquisition-probe` is
  `acquisition:folder-plus-multiselect:5-selections:8-files:source-unchanged`;
- `inbox-screen` is `import:1-review:1-processing:0`; and
- `review-import-job-30000000-0000-0000-0000-000000000001` opens review.

## Stable model identifiers

| Role | UUID / alias |
| --- | --- |
| Job | `30000000-0000-0000-0000-000000000001` |
| Proposal A | `30000000-0000-0000-0000-000000000010` / `a` |
| Proposal B | `30000000-0000-0000-0000-000000000020` / `b` |
| Split proposal | `30000000-0000-0000-0000-000000000030` / `c` |
| Final book | `30000000-0000-0000-0000-000000000100` |
| A part 1 | `30000000-0000-0000-0000-000000000101` / `a1` |
| A part 2 | `30000000-0000-0000-0000-000000000102` / `a2` |
| A part 10 | `30000000-0000-0000-0000-000000000110` / `a10` |
| Prelude | `30000000-0000-0000-0000-000000000111` / `ap` |
| B part 3 | `30000000-0000-0000-0000-000000000203` / `b3` |
| B part 4 | `30000000-0000-0000-0000-000000000204` / `b4` |
| B part 5 | `30000000-0000-0000-0000-000000000205` / `b5` |
| B part 6 | `30000000-0000-0000-0000-000000000206` / `b6` |

The inspector returns no grouping tags. The analyzer proposes A from folder name
and filename stem, B from filename stem, and natural order from numeric filename
components. Thus part 2 precedes part 10 without lexical-order mistakes.

## Review semantics

Review Import exposes:

- `review-import-screen` = `proposal:needs-review:2-books:8-tracks:2-warnings`;
- `grouping-probe` =
  `groups|2|tracks|8|folder-name+filename-stem|natural-numeric|review`;
- `grouping-evidence-folder-name` and `grouping-evidence-filename-stem`; and
- `review-order-button`.

Review Order exposes `review-order-screen`, `order-probe`,
`ordering-evidence-natural-numeric`, and the production controls:

- `order-track-<asset UUID>` identifies the row and
  `order-select-<asset UUID>` selects its track;
- `order-move-to-<proposal UUID>` calls `moveAssets` for selected tracks;
- `order-move-up-<asset UUID>` calls `reorderAssets` once;
- `split-selected-tracks` calls `splitProposal` and consumes deterministic C;
- `order-proposal-<proposal UUID>` selects merge participants;
- `merge-proposals` calls `mergeProposals`, treating the first selected proposal
  as destination and appending the second proposal's ordered assets;
- `save-order` validates and saves the draft.

`order-probe` has the exact form
`order|revision|N|alias|comma-separated-asset-aliases...`. Every successful edit
increments revision once. Selection alone never increments it. The test asserts
the full sequence through move, three move-ups, split, merge C into B, then merge
B into A. The final value is:

```text
order|revision|7|a|ap,a1,a2,a10,b4,b5,b6,b3
```

The final root state is `order:valid:1-book:8-tracks:revision-7`. Saving returns
Review Import as `proposal:ready:1-book:8-tracks:0-warnings:revision-7`.

## Atomic commit

Before commit, `commit-probe` is:

```text
transaction:pending:books=0:assets=0:staging=8:source-unchanged=true
```

`add-import-to-library` performs one recoverable transaction for the single
proposal. No partial library book may be observable. Success exposes final book
`recent-book-30000000-0000-0000-0000-000000000100` in the populated Library and:

```text
transaction:committed:books=1:assets=8:staging=0:source-unchanged=true:rollback=available
```

The commit probe reads production library, managed-storage, staging, transaction,
and pre/post source-checksum state. It is read-only and must not synthesize a
success result.
