# MVP completion release train

Status: active execution plan
Created: 2026-08-23
Branch: `feat/mvp-completion`
Pull request: one PR, with every product commit independently green before the next commit

## Objective

Close the evidence and product gaps between the current TestFlight product and
the completion gate in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md), without
turning explicitly deferred integrations into accidental MVP scope.

The current product has executable evidence for T00 through T15 in Stories 001
through 008. The remaining formal tracers are T16 through T19. The shipped
computer receiver also has interruption/retry behavior described as unfinished
in [DIRECT_IMPORT_UX.md](DIRECT_IMPORT_UX.md); because that route is already the
primary import action in the product, its reliability gaps are completion work
rather than a future feature.

## Scope audit

### Represented and retained

- T00–T15 production journeys and Stories 001–008.
- Files, document-open/AirDrop, Share Extension, safe ZIP, local web receiver,
  and iPhone Mirroring ingress.
- Metadata repair across every MVP field, grouping/order repair, recoverable
  import/storage failures, Library organization/search, playback integrity,
  transport preferences, Smart Rewind, sleep timer, and bookmarks.
- The existing legal synthetic corpus and opt-in private full-book smoke test.

These areas may receive regression fixes, accessibility corrections, or visual
cleanup, but they are not reimplemented as new tracers.

### Required completion work

1. Close interruption and retry gaps in the already-shipped computer receiver.
2. T16 portable backup/restore plus rotating automatic database backups.
3. T17 largest-Dynamic-Type and accessibility completion evidence.
4. T18 startup recovery, orphan cleanup, offline audit, and sanitized support
   diagnostics.
5. T19 startup/search/import scale evidence and a complete-suite command.
6. Reconcile implementation screenshots with every approved mockup and repair
   remaining missing actions, misleading copy, layout gaps, and product bugs.

### Explicitly deferred after MVP

The following are designs or follow-ups, not incomplete claims for this release:

- Finder/Apple Devices `Import Drop Box` transport;
- Handoff receiver discovery and trusted-computer credentials;
- remotely hosted Mirroring-region policy and remote kill switch;
- watched provider folders, App Intents, Mac companion, and hosted relay;
- cloud/server sync, online metadata, CarPlay, Watch, and other integrations
  already excluded or deferred by the product documents.

The documentation must identify these consistently and must not expose
nonfunctional rows or buttons for them.

## Serial commit and release protocol

For every commit below:

1. Begin from the exact green head of this branch.
2. Implement production behavior, nonvisual tests, E2E semantics, screenshots,
   migrations, and documentation together.
3. Run focused tests and the full Player unit suite locally.
4. Commit and push exactly one milestone.
5. Record the commit SHA and its GitHub Actions run ID in the release ledger.
6. Do not commit the next milestone until CI is green for that exact SHA.
7. For an app-bearing commit, archive the next monotonically increasing build,
   validate signing/entitlements, upload it, wait for `VALID`, and verify
   `IN_BETA_TESTING` in the Internal group.
8. If CI fails, repair the same milestone before advancing. The repair remains
   visibly associated with that milestone in the PR history.

A commit cannot contain its own final SHA or CI result. Each ledger row is
finalized by the following serial commit; C06 is finalized in a documentation-
only release-record commit after its app build is valid. The PR check and PR
description provide the exact green evidence for that last record commit.

Documentation-only planning commits do not create a redundant TestFlight
binary. Every commit that changes the app or its bundled web UI does.

## Commit train

### C00 — Reconcile the completion contract

Commit intent: `docs: define the MVP completion release train`

- Publish this audit and serial gate.
- Update stale “initial scaffold” and “future feature” claims in root/iOS docs.
- Reconcile exact-pixel wording with the comparator’s real 8/255 per-channel
  rounding allowance and zero spatial tolerance.
- Update direct-import documentation through Build 13 and distinguish verified
  behavior from deferred transports.
- Update TestFlight instructions from a one-off Build 1 handoff to the current
  reusable release process without exposing credentials.
- Make every completion-contract document trigger the same required iOS CI
  gate, including later ledger-only closure changes.
- Preserve the aggregate required check while running the eight independent E2E
  stories in parallel, so each serial milestone receives complete evidence
  without a 75-minute critical path.

Gate: documentation links and project generation checks pass; no TestFlight
upload because the app binary is unchanged.

### C01 — Finish shipped direct-import recovery

Commit intent: `fix: finish resumable computer imports`

- Preserve partial files and expose verified per-file offsets while the active
  receiver session remains valid.
- Resume an interrupted file from the server-confirmed offset instead of
  deleting the whole transfer or trusting browser-only progress.
- Keep sealed imports alive when the browser or receiver view disconnects.
- Make cancellation, expiry, retry, and cleanup ownership explicit and
  exactly-once.
- Add receiver-specific native E2E states and browser accessibility/behavior
  tests for reconnect, progress agreement, cancellation, and completion.
- Retain the physically verified synchronous iPhone Mirroring provider path.

Gate: existing import stories plus receiver integration tests are green.
Release: TestFlight Build 14.

### C02 — T16 portable backup and restore

Commit intent: `feat: back up and restore the local library`

- Add a versioned portable manifest with metadata-only and media-inclusive
  exports, artwork/media checksums, and explicit compatibility errors.
- Restore books, metadata, positions, journals, organization, preferences,
  sleep history, and bookmarks atomically without duplicating media.
- Add rotating automatic database backups before migration and after durable
  significant mutation batches.
- Add Settings Backup UI using system import/export destinations.
- Add migration fixtures and Story 010: backup, clear fixture library, restore,
  and verify an identical usable library.

Gate: backup round trips, Stories 001–008, and Story 010 are green (Story 009
belongs to the following accessibility tracer).
Release: TestFlight Build 15.

### C03 — T17 accessible core journeys

Commit intent: `feat: complete accessible core journeys`

- Audit labels, values, hints, reading order, announcements, adjustable
  controls, and non-drag alternatives across import, repair, Library, playback,
  recovery, backup, and direct import.
- Reflow core screens through the largest accessibility content sizes without
  hiding primary actions or requiring horizontal text scrolling.
- Honor Reduce Motion, Increase Contrast, Differentiate Without Color, Bold
  Text, and the app-specific accessibility preferences in Settings.
- Add Story 009 large-text visual evidence and programmatic VoiceOver semantics
  for the core task paths.

Gate: the accessibility task matrix and Stories 001–010 are green at the exact
commit SHA.
Release: TestFlight Build 16.

### C04 — T18 offline recovery and diagnostics

Commit intent: `feat: recover and diagnose the offline library`

- Replace launch-time `fatalError` with truthful database recovery choices.
- Validate and restore rotating backups without overwriting the only recoverable
  copy; quarantine an invalid latest store.
- Reconcile interrupted commits, app-owned orphan staging, and trash manifests
  without guessing from private filenames.
- Export a sanitized support bundle that excludes titles, contributors, notes,
  source filenames, paths, checksums, pairing secrets, and listening history.
- Add a complete Airplane Mode audit for import from local Files, browse,
  search, edit, playback, bookmarks, backup, and recovery.
- Add Story 011 for startup recovery and diagnostic export.

Gate: forbidden-data inspection and Stories 001–011 are green.
Release: TestFlight Build 17.

### C05 — T19 prove the MVP at scale

Commit intent: `perf: prove the complete MVP at scale`

- Measure ready-state startup for 1,000 and 10,000 records against the documented
  one- and two-second budgets.
- Retain the existing sub-100 ms 10,000-book search proof and add deterministic
  scroll/indexing assertions that keep expensive work off the main actor.
- Exercise streamed multi-gigabyte import/backup simulations without allocating
  whole media or archive entries in memory.
- Add fixtures for every shipped schema and complete migration/round-trip
  coverage.
- Provide one command for unit/integration suites and Stories 001–011.
- Publish an evidence-linked MVP acceptance matrix.

Gate: every budget and complete-suite command is green on the pinned toolchain.
Release: TestFlight Build 18.

### C06 — Screenshot comparison and final product cleanup

Commit intent: `fix: complete the MVP product experience`

- Capture fresh native screenshots for every stable production state represented
  by Stories 001–011.
- Compare them side by side with:
  - `docs/ux/mockups/01-library-import.png`;
  - `docs/ux/mockups/02-review-metadata.png`;
  - `docs/ux/mockups/03-listening.png`;
  - `docs/ux/mockups/direct-import/01-iphone-receiver-flow.png`; and
  - `docs/ux/mockups/direct-import/02-computer-uploader-flow.png`.
- Inventory every missing feature, wrong hierarchy, misleading status, clipped
  accessibility layout, dead action, inconsistent progress value, and visual
  regression.
- Fix the inventory in the smallest independently gated cleanup commits needed;
  do not combine an unrelated failure repair with a baseline update.
- Record only intentionally changed baselines, explain each visual decision,
  and rerun without recording.

Gate: all local checks, Stories 001–011, mockup comparison inventory, repository
hygiene, and final acceptance matrix are green.
Release: TestFlight Build 19 or the next build for each additional independently
gated cleanup commit.

### C07 — Close the release record

Commit intent: `docs: record the completed MVP release train`

- Record the C06 SHA, CI run, final TestFlight state, acceptance evidence, and
  intentional visual differences.
- Recheck documentation links, repository hygiene, and the complete-suite
  command without changing the app binary.

Gate: the documentation-triggered CI run is green. No TestFlight upload because
the app binary is identical to the last valid C06 build.

## Release ledger

| Milestone | Commit SHA | CI run | Result | TestFlight build | App Store state |
| --- | --- | --- | --- | --- | --- |
| C00 contract | `8276a5f` | [32678084366](https://github.com/anicolao/player/actions/runs/32678084366) | green | — | — |
| C01 direct import | `21b8d94` | [32679634232](https://github.com/anicolao/player/actions/runs/32679634232) | green | 14 | `VALID` / `IN_BETA_TESTING` |
| C02 backup | pending | pending | pending | 15 | pending |
| C03 accessibility | pending | pending | pending | 16 | pending |
| C04 recovery | pending | pending | pending | 17 | pending |
| C05 scale | pending | pending | pending | 18 | pending |
| C06 cleanup | pending | pending | pending | 19+ | pending |

## Final completion gate

The PR is ready to merge only when:

- every ledger row is complete and every app-bearing SHA has a valid Internal
  TestFlight build;
- Stories 001–011 and all nonvisual suites pass on the pinned environment;
- the opt-in private full-book smoke test reports only neutral facts and passes;
- accessibility, offline, migration, backup, diagnostics-redaction, and scale
  audits are recorded;
- the mockup comparison has no unexplained missing feature or known product bug;
- all documents describe the product that actually ships; and
- the branch contains no secrets, private audiobook content, transient build
  artifacts, or unrelated user files.
