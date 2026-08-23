# Story 007 — Persistent Sleep Timer contract

Story 007 proves that the sleep timer is a durable listening feature, not a view-local countdown. Every timer is started, replaced, or cancelled through production UI. E2E controls may only move the deterministic clock/playback position and ask the production model to evaluate the timer.

## Deterministic fixture

Launch arguments:

- `-e2e -e2e-reset -e2e-fixture sleep-timer -e2e-sleep-timer-namespace <name>` resets an isolated namespace.
- Omitting `-e2e-reset` reopens that namespace's persisted library.
- Locale is `en_CA`, time zone is `America/Toronto`, and the E2E clock is fixed at Unix time `1700020000` until explicitly advanced.

The synthetic fixture is generated in app-owned E2E storage and contains no private or copyrighted media:

- book `52000000-0000-0000-0000-000000000001`, “The Quiet Hours” by Mara Vale;
- two synthetic 90-second M4B asset records with timeline starts at 0 and 90 seconds;
- three chapters: 0–60, 60–120, and 120–180 seconds;
- one acknowledged paused position at 70,000 ms;
- deterministic generated IDs beginning at suffix `101`, with relaunches deriving the next suffix from the durable store.

At 70 seconds, End of Chapter targets 120,000 ms and End of Track targets 90,000 ms. With fade enabled, the End of Track timer enters `fading` at 85,000 ms, writes no stop/history yet, and completes at exactly 90,000 ms.

## Production accessibility contract

Now Playing:

- `open-sleep-timer` opens the production timer sheet. Its value is `inactive` or `active:<timer UUID>:remaining=<seconds|none>:phase=<phase>`.
- `sleep-resume-context` exposes `history=<UUID>:book=<UUID>:stop=<ms>:until=<epoch seconds>`.
- `resume-sleep-context` invokes the production one-time contextual resume.

Timer sheet:

- `sleep-timer-screen`
- `sleep-timer-fade`
- `sleep-timer-preset-10`, `sleep-timer-preset-15`, `sleep-timer-preset-30`, `sleep-timer-preset-45`, `sleep-timer-preset-60`
- `sleep-timer-custom-picker`, options `sleep-timer-custom-<minutes>`, and `start-custom-sleep-timer`
- `sleep-timer-end-chapter`, `sleep-timer-end-track`
- `active-sleep-timer`
- `cancel-sleep-timer`
- `sleep-history-<lowercase history UUID>`

`sleep-timer-screen` values are:

- inactive: `sleep-timer:active=none:fade=<bool>:history=<count>`
- active: `sleep-timer:active=<UUID>:selection=<token>:remaining=<seconds|none>:target=<ms|none>:fade=<bool>:phase=<phase>:history=<count>`

Selection tokens are `preset-10`, `preset-15`, `preset-30`, `preset-45`, `preset-60`, `custom-1500`, `end-chapter`, and `end-track` for this journey.

History rows expose:

`history=<UUID>:timer=<UUID>:selection=<token>:status=<completed|cancelled|replaced>:stop=<ms>:event=<UUID|none>:context-used=<bool>`

While active, the existing `mini-player` value retains its established player prefix and appends:

`|sleep=<timer UUID>,selection=<token>,remaining=<seconds|none>,fade=<bool>,phase=<phase>`

All UUIDs are lowercase production UUIDs; fixture aliases never appear in accessibility values.

## E2E-only evaluation channel

`sleep-timer-state-probe` serializes the production model as pipe-delimited key/value tokens:

`sleep-timer|active=...|selection=...|fade=...|phase=...|remaining=...|target=...|history=...|latest=...|rewinds=...|history-id=...|history-timer=...|history-selection=...|stop=...|event=...|context-used=...|context=...|context-book=...|context-stop=...|context-until=...|position=...|playback=...|journal=...`

History/context detail tokens are present only when applicable. `journal` contains exact `sequence:reason@position` entries.

Two E2E-only buttons are available only while the deterministic End of Track timer is active:

- `e2e-sleep-enter-fade` seeks through the production model to 85 seconds and calls `evaluateSleepTimer()`.
- `e2e-sleep-complete-boundary` seeks through the production model to 90 seconds, calls `evaluateSleepTimer()`, and hides the E2E controls.

They never create timers, history, stop events, or resume transactions directly.

## Required journey

1. In isolated reset namespaces, open the production sheet and start 10, 15, 30, 45, and 60 minute presets, a 25-minute custom timer, End of Chapter, and End of Track. Assert exact selection, remaining/target, fade, position, and empty history from the production probe. Toggle fade off through the native production Toggle for the 45-minute case.
2. Start 10 minutes, replace it with 15 minutes, and cancel through production UI. Assert a replaced history entry for the first timer and a cancelled entry for the second; relaunch and assert both remain while no timer is active.
3. Start End of Track with fade enabled, terminate, and relaunch. Assert the mini-player and sheet restore the same timer with 20 seconds remaining and offer Cancel.
4. Play normally. At 85 seconds assert phase `fading`, five seconds remaining, playback still playing, and no completion history/event. At 90 seconds assert playback paused, active timer cleared, an acknowledged `.sleepTimer` position event at exactly 90,000 ms, completed history, and an unused ten-minute context expiring at `1700020600`.
5. Terminate and relaunch. Assert the paused 90,000 ms stop and Resume-with-context affordance survived.
6. Tap ordinary Play and assert it appends only `.play`, creates no Smart Rewind transaction, and leaves context available. Pause again.
7. Tap Resume with context. Assert the forced five-second contextual rewind reaches 85,000 ms, appends `.preResumeRewind`, `.resumeRewind`, and `.play`, consumes the history context atomically, and cannot be offered a second time.

## Screenshot policy

Record only after the complete semantic journey passes:

1. `000-persisted-active-sleep-timer.png` — stable timer sheet after process relaunch, showing End of Track, 0:20 remaining, fade behavior, and Cancel.
2. `001-sleep-stop-resume-context.png` — stable paused Now Playing after completed-stop relaunch, showing the saved sleep stop and one-tap Resume context.

Preset setup, moving fade/countdown state, replacement/cancellation, and post-Resume playback remain semantic-only. Synthetic fixture data only; never capture private books or metadata.

---

# T14 — Durable bookmark contract

The same Story 007 package also proves that bookmarks capture an acknowledged audiobook timeline location, remain searchable and editable, jump through the production player, and survive deletion/Undo across process restarts.

## Deterministic bookmark fixture

`-e2e -e2e-reset -e2e-fixture bookmarks` creates one synthetic 120-second book:

- book `53000000-0000-0000-0000-000000000001`, “Mapped Signals” by Mara Vale;
- two synthetic 60-second M4B asset records, `...002` then `...003`;
- “Opening Signal” from 0–60 seconds and “The Crossing” from 60–120 seconds;
- one acknowledged pause at exactly 60,000 ms, where timeline mapping must choose asset `...003`, asset position 0, and chapter `crossing`;
- a fixed clock at Unix time `1700030000`; the E2E clock-only control advances it by exactly 60 seconds before the second bookmark;
- generated UUIDs start at suffix `101` and relaunches derive the next unused suffix from durable state.

The fixture writes only short synthetic placeholder bytes in app-owned E2E storage. It contains no private book, metadata, artwork, or copyrighted audio.

## Production bookmark accessibility

Now Playing:

- `add-bookmark` performs the one-tap production capture.
- `bookmark-saved` exposes `bookmark=<UUID>:book=<UUID>:position=<ms>`.

Book Detail organization:

- `book-detail-content-picker` has value `chapters` or `bookmarks`.
- `chapters-segment` and `bookmarks-segment` have value `selected` or `not-selected`.
- `bookmark-search` and `clear-bookmark-search` control local bookmark search.
- `bookmark-sort` has the selected `BookmarkSort.rawValue`.
- sort choices are `bookmark-sort-position-ascending`, `bookmark-sort-position-descending`, `bookmark-sort-date-newest`, `bookmark-sort-date-oldest`, and `bookmark-sort-label`.
- `bookmarks-screen` exposes `bookmarks:query=<normalized query>:sort=<raw sort>:count=<count>:order=<lowercase UUIDs|none>`.
- `bookmark-row-<lowercase UUID>` exposes `book=<UUID>|asset=<UUID>|chapter=<id|none>|bookMs=<ms>|assetMs=<ms>|label=<label>|note=<note|none>`.
- row actions are `jump-to-bookmark-<UUID>`, `edit-bookmark-<UUID>`, and `delete-bookmark-<UUID>`.
- `bookmark-jump-confirmation` exposes `bookmark=<UUID>:position=<ms>`.
- `bookmark-editor`, `bookmark-label-editor`, `bookmark-note-editor`, and `save-bookmark` edit through the production model; an empty normalized label disables Save, and an empty note clears it.
- `bookmark-delete-undo` contains `undo-delete-bookmark`, whose value is `transaction=<UUID>:bookmark=<UUID>`.

All accessibility UUIDs are lowercase production UUIDs, never fixture aliases. Machine-readable numbers use verbatim, locale-independent strings.

## E2E-only channel

`bookmarks-state-probe` serializes durable production state as:

`bookmarks|count=...|order=...|items=...|transactions=...|deletions=...|position=...|journal=...`

Each `items` entry is `bookmarkUUID~bookMs~assetUUID~assetMs~chapterID~label~note~createdEpoch~updatedEpoch`. Each deletion entry is `transactionUUID~bookmarkUUID~originalIndex~status~undoneAtState`.

`e2e-bookmark-second-position` is available once on Now Playing. It calls the production whole-book seek to 15,000 ms and advances only the injected clock by 60 seconds. It never creates, edits, deletes, restores, or jumps to a bookmark directly.

## Required bookmark journey

1. At exactly 60,000 ms, tap Add Bookmark and assert bookmark `...101` maps to following asset `...003`, asset position 0, chapter `crossing`, and label `The Crossing · 1:00`.
2. Move through the E2E seek/clock channel to 15,000 ms and tap Add Bookmark again. Assert bookmark `...103` maps to first asset `...002`, asset position 15,000, chapter `opening`, and a creation time exactly 60 seconds later.
3. Open Book Detail, switch from Chapters to Bookmarks, and assert exact row state. Prove empty-label validation, then edit the second bookmark to label `Écho marker` and note `Return to the café clue`.
4. Drive every production sort and assert exact order. Search `echo cafe` to prove case/diacritic normalization, then clear search.
5. Jump to the 60,000 ms bookmark. Assert an ordinary acknowledged `.seek` event and exact saved position, with no special bookmark-only journal reason.
6. Delete bookmark `...101` into transaction `...105`, terminate, and relaunch. Assert deletion state persisted, then Undo and assert the original underlying array index and full bookmark snapshot are restored atomically and the transaction becomes `undone`.
7. Open production Library search and query `cafe clue`. Assert the edited bookmark note makes “Mapped Signals” the sole result.

## Bookmark screenshot policy

After all bookmark semantic assertions pass, record exactly one additional stable frame:

3. `002-bookmarks-list.png` — Book Detail with Bookmarks selected after edit and cleared search, showing both bookmark labels, chapter/time context, the Unicode note, and the Chapters/Bookmarks organization.

Sort menus, active search, edit sheets, jump feedback, deletion, Undo, and Library search remain semantic-only.
