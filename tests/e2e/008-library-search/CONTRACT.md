# Story 008 daily library organization contract

## Scope

Story 008 covers T09 organization and T10 local search, filters, and sorting.
The test must exercise
production shelves, playback, ordering, persistence, contributor indexes,
collections, and Trash transactions. The E2E bootstrap may seed deterministic
records and files; it must not implement any operation asserted by the test.

No probe may emit a private title, filesystem path, discovered metadata, fixture
branch name, or short fixture alias. Every UUID in an accessibility value is its
lowercase canonical representation. `b1`–`b5` below are documentation aliases
only and never appear in production probe values.

## Generated fixture

`PlayerUITests/Fixtures/SyntheticLibrary` contains one generated AAC M4B, five
distinct generated 32×32 covers, and
`synthetic-populated-library-fixture.json`. All are legal original test material
covered by `SyntheticLibrary.sha256`. The generator copies the existing verified
format fixture, creates PNG bytes without third-party tools or a network, and
validates exact clean reproduction.

Stable book IDs are:

```text
b1 90000000-0000-0000-0000-000000000001  Ember at Daybreak
b2 90000000-0000-0000-0000-000000000002  Tides Between Stars
b3 90000000-0000-0000-0000-000000000003  The Clockwork Orchard
b4 90000000-0000-0000-0000-000000000004  A Lantern for Winter
b5 90000000-0000-0000-0000-000000000005  Quiet Maps
```

Assets are the same suffixes `101`–`105`. Authors are `201`–`203`, narrators
`301`–`303`, and series are `401`–`402`. The production ID source returns:

```text
collection        90000000-0000-0000-0000-000000000501
trash transaction 90000000-0000-0000-0000-000000000601
```

Each managed asset is a separate byte-identical copy of the 8,461-byte,
2.1-second fixture M4B. Sharing test bytes does not share managed URLs or asset
records. The seeded production book timeline is 120 seconds so organization and
progress states have useful deterministic values; the deterministic playback
controller does not decode or advance the tiny file.

## Bootstrap boundary

Launch arguments are:

```text
-e2e -e2e-reset -e2e-fixture synthetic-populated-library
```

The UI-test bundle supplies only checked-in bytes through:

```text
PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64
PLAYER_E2E_LIBRARY_AUDIO_BASE64
PLAYER_E2E_LIBRARY_COVER_B1_BASE64 ... PLAYER_E2E_LIBRARY_COVER_B5_BASE64
```

The fixed clock is `2026-08-18T13:41:00Z`. Bootstrap creates production book,
asset, playback-position, Up Next, and preference records plus five managed
files. On relaunch without `-e2e-reset`, it opens the existing persisted store
and must not reseed or overwrite listener changes.

## Initial shelves and resume

`library-organizer-probe` derives directly from persisted production state:

```text
library:books=5:continue=90000000-0000-0000-0000-000000000001,90000000-0000-0000-0000-000000000003:up-next=90000000-0000-0000-0000-000000000002,90000000-0000-0000-0000-000000000005,90000000-0000-0000-0000-000000000003:finished=90000000-0000-0000-0000-000000000004:collections=0:trash=0:view=shelf:current=90000000-0000-0000-0000-000000000001:position=45000
```

Continue Listening contains progress greater than zero and unfinished books in
last-listened order. Up Next is manually ordered. Recently Added is newest first
and exposes `recent-book-<book UUID>`. Required controls are:

```text
resume-book-<book UUID>
open-up-next
browse-series
browse-authors
browse-narrators
browse-collections
browse-all-books
```

Resuming b1 uses the production playback path. `now-playing-screen` reports
`player:paused:90000000-0000-0000-0000-000000000001:0:45000`; no wall-clock
advance is simulated.

## Up Next and finished state

`up-next-screen` contains `up-next-probe`:

```text
up-next:count=3:order=90000000-0000-0000-0000-000000000002,90000000-0000-0000-0000-000000000005,90000000-0000-0000-0000-000000000003
```

Rows are `up-next-book-<book UUID>`. Accessible ordering alternatives are
`up-next-move-up-<book UUID>`; two b3 moves produce:

```text
up-next:count=3:order=90000000-0000-0000-0000-000000000003,90000000-0000-0000-0000-000000000002,90000000-0000-0000-0000-000000000005
```

No synthetic revision counter is exposed. Ordering persists atomically before
the probe changes.

Book Detail exposes `mark-finished-<book UUID>`. Because b3 has substantial
unlistened content, `confirm-mark-finished` is required. `book-state-probe`
becomes:

```text
book:90000000-0000-0000-0000-000000000003:finished=true:position=120000
```

The same transaction removes the marked book from Continue Listening and Up
Next. Finished books are ordered most-recently-finished first. The resulting
organizer value contains one Continue Listening UUID, two Up Next UUIDs, and two
Finished UUIDs in the exact orders asserted by the UI test.

## Contributor and series browsing

Each browse screen uses normal navigation-bar Back semantics. It exposes one
screen identifier, one exact probe, and row identifiers keyed by lowercase
production IDs:

```text
series-browser-screen / series-browser-probe / series-<series UUID>
browse:series:groups=2:books=4:order=90000000-0000-0000-0000-000000000402,90000000-0000-0000-0000-000000000401

authors-browser-screen / authors-browser-probe / author-<contributor UUID>
browse:authors:groups=3:books=5:order=90000000-0000-0000-0000-000000000201,90000000-0000-0000-0000-000000000202,90000000-0000-0000-0000-000000000203

narrators-browser-screen / narrators-browser-probe / narrator-<contributor UUID>
browse:narrators:groups=3:books=5:order=90000000-0000-0000-0000-000000000303,90000000-0000-0000-0000-000000000301,90000000-0000-0000-0000-000000000302
```

Orders are localized display-name order using the pinned locale. Counts are
association counts, not deduplicated book totals across groups.

## Collections

Collection flow identifiers are:

```text
create-collection
collection-name-input
save-collection
add-collection-books
collection-select-book-<book UUID>
save-collection-books
collection-move-up-<book UUID>
collection-book-<book UUID>
collection-probe
```

Creating `Quiet Evenings`, adding b1 then b2, and moving b2 up produces:

```text
collection:90000000-0000-0000-0000-000000000501:name=Quiet Evenings:count=2:order=90000000-0000-0000-0000-000000000002,90000000-0000-0000-0000-000000000001
```

The model has deterministic order and timestamps but no product revision
counter, so the probe does not invent one.

## Shelf/list persistence

`all-books-screen` contains `all-books-probe`, rows
`all-books-book-<book UUID>`, and `library-view-shelf` / `library-view-list`.
The stored value is now `shelf`; legacy snapshots containing `grid` decode as
`shelf` and are rewritten with the current name. The shelf container is
`all-books-bookshelf`; duplicate
curated appearances use `bookshelf-continue-book-<book UUID>` and
`bookshelf-recent-book-<book UUID>`, while A–Z retains the canonical row ID.
Each shelf exposes E2E-only `<scroll identifier>-left-end`,
`<scroll identifier>-right-end`, and `<scroll identifier>-readiness` elements.
The versioned readiness value is bound to the shelf container and horizontal
axis. It publishes monotonic interaction, completion, and geometry IDs; the
geometry generation associated with a completed phase; the current idle state;
and finite measured offset, range, content, container, and endpoint geometry.
Malformed, duplicate, truncated, unknown-key, zero-generation, and unbound
values fail closed. The journey captures the Recently Added shelf only after its left
endpoint is idle and the left-end marker is fully contained by the shelf
viewport. It then requires a non-empty scrollable range, a new interaction,
directional offset progress, correlated settled geometry at the right endpoint,
and full containment of the final cover and right-end marker. One deliberate
right-end challenge must publish a correlated completion while preserving the
settled offset and final-cover frame within tolerance before capture.
Pinned title order is:

```text
all-books:count=5:view=shelf:order=90000000-0000-0000-0000-000000000004,90000000-0000-0000-0000-000000000001,90000000-0000-0000-0000-000000000005,90000000-0000-0000-0000-000000000003,90000000-0000-0000-0000-000000000002
```

After `library-view-list`, `view=list`. A process termination and relaunch
without reset must retain list mode and the same order.

## Recoverable Trash

Book Detail removal uses `remove-book` and the explicit recoverable option
`remove-book-to-trash`. The latter atomically moves the library record, managed
asset, position, Up Next membership, and organization references into a Trash
manifest. It does not unlink the asset bytes. `open-trash` opens `trash-screen`.

The screen exposes `trash-book-<book UUID>`,
`restore-trash-<transaction UUID>`, and `trash-probe`:

```text
trash:transactions=1:books=90000000-0000-0000-0000-000000000005:assets=1:bytes=8461:restorable=true:managed-checksum-preserved=true
```

The checksum comparison reads the production managed file before removal, the
Trash file after removal, and the restored managed file. It never trusts fixture
metadata. Restore is atomic and reinstates b5 at its previous Up Next index. The
empty probe is:

```text
trash:transactions=0:books=none:assets=0:bytes=0:restorable=false:managed-checksum-preserved=true
```

After restore, the organizer probe reports five books, b2 then b5 in Up Next,
b3 and b4 finished, one collection, zero Trash transactions, and list mode.

Before opening Trash, the journey first establishes a known top endpoint through
one progress-making fast downward swipe, then scrolls the final Library control
fully above the persistent mini-player through a separate progress-making fast
upward swipe. Each transition has its own event deadline capped at two seconds;
neither deadline is reset or extended. `library-root-scroll-readiness` is bound
to the Library vertical scroll container and must prove a non-empty range,
directional offset progress in both transitions, idle top- then bottom-end
geometry, and full containment in the actual viewport region above the player.
A plain SwiftUI scroll phase supplies a
completion tied to its final geometry generation; a List/Form fallback is
accepted only after a new geometry generation is idle and the final semantic
containment condition is true. One deliberate bottom-end challenge must publish
a correlated completion while preserving the settled offset and Trash frame
within tolerance before capture. This proves the required mini-player runway
and settled boundary without a fixed gesture count or timing delay. Settings
rows are likewise revealed through bound, progress-making scroll evidence
before navigation taps.

## Stable visual evidence

Only after the associated programmatic assertions pass, TestStepHelper attaches:

```text
000-populated-library.png
001-curated-collection.png
002-square-cover-bookshelves.png
003-square-cover-bookshelf-right-end.png
004-trash-clear-of-player.png
005-recoverable-trash.png
006-restored-library-list.png
007-metadata-search.png
008-filtered-search.png
009-no-search-matches.png
README.md
```

Screenshots use only fixed synthetic metadata and artwork. No baselines are
recorded by this scaffold task.

## Local search, sort, and filters

`open-library-search` opens the production local index. `library-search-input`
matches normalized title, contributor, narrator, series, chapter, original
filename, collection name, descriptive metadata, and future bookmark-note
fields without network access. Results are `search-result-<book UUID>`.

The Story first searches `Mina Sol` and requires b5 then b3 in title order. It
also programmatically requires `Quiet Evenings` to find the two collection
members and `Full Book` to find all five chapter matches. Stable result state is
exposed by `library-search-results-probe`. The separate `library-search-probe`
also carries the index revision and readiness used by metadata-editing coverage:

```text
query=<normalized query>:count=<n>:sort=<sort>:direction=<direction>:status=<status-or-any>:formats=<csv-or-any>:missing=<bool>:empty=<none|query|filters>:order=<canonical UUID csv-or-none>
```

Sort controls are `search-sort`, `search-sort-title`, `search-sort-author`,
`search-sort-series`, `search-sort-recently-added`, `search-sort-duration`,
`search-sort-progress`, and `search-sort-direction`. Filter controls are
`search-filter`, `search-filter-any-status`, `search-filter-unplayed`,
`search-filter-in-progress`, `search-filter-finished`, `search-filter-m4b`, and
`search-filter-missing-metadata`. `clear-library-search` and
`empty-search-clear-all` expose both production reset paths. Finished plus
recently-added descending yields b4 then b3 and the visible summary
`2 books · Finished · Recently added`. Sort and filter preferences persist
across process termination; the query intentionally does not.

After relaunch, `No Such Audiobook` must expose `library-search-empty` with
`empty=query`, while the library still contains five books and the durable sort
and filter remain explicit. `empty-search-clear-all` restores default title
order and all five results. This state must never reuse the empty-library copy.

The nonvisual R13 journey uses the dedicated `synthetic-search-matrix` fixture.
It retains the five stable identities and covers while varying duration, format,
and metadata completeness so every production menu choice has an observable
result. It proves Title, Author, Series order, Recently added, Duration, and
Progress in both directions; Any, Unplayed, In progress, Finished, M4B, and
Missing metadata independently; and a combined Unplayed + M4B + Missing metadata
empty state. It also opens a result, verifies query-empty and filter-empty copy,
uses both Clear All actions, restores preferences after relaunch, and proves an
E2E fixture reset returns the durable defaults.
