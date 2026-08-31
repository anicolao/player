# Application remediation plan

**Status:** Implementation and deterministic automated coverage are complete
through R16. The final scheduling candidate is awaiting normal-CI acceptance;
formal exact-SHA R0 qualification and physical-device release acceptance remain
pending.
**Created:** 2026-08-27
**Source:** Report-only application and test-coverage audit completed 2026-08-27

## Objective

Restore confidence in Bookshelf by first proving that its E2E suite is reliable,
deterministic, and diagnostic, then addressing every confirmed defect and
coverage gap in the order reported by the audit.

No product item in this plan should be called complete merely because a test
exists or a single CI attempt passes. Completion requires production behavior,
focused nonvisual verification, an event-driven E2E regression where the
platform permits one, and reviewable evidence from the exact commit being
accepted.

## Delivery rules

1. Complete the R0 harness and focused stabilization before product
   remediation, then perform repeated exact-SHA qualification after R1-R16 are
   integrated so the accepted evidence covers the final implementation.
2. Address R1-R16 in order. A newly discovered data-loss, security, purchase,
   or playback-blocking defect may preempt the sequence, but must be documented
   with the reason.
3. Use a focused commit for each numbered remediation. Keep CI green at every
   commit; do not stack unrelated fixes behind a red predecessor.
4. Never use fixed sleeps in E2E tests. Wait for an observable event or semantic
   state that proves the requested transition occurred.
5. Every E2E condition must resolve within two seconds. A longer timeout is a
   delayed failure, not a stabilization technique.
6. Do not use automatic reruns to convert failures into success. A repeated run
   is a measurement and must retain the result and artifacts from every attempt.
7. Keep production paths and deterministic adapters separated at dependency
   boundaries. E2E-only controls may inject otherwise unavailable platform
   events, but must not bypass the product decision, UI action, persistence, or
   rendering being validated.
8. Use unit/integration tests for parsers, transactions, clocks, StoreKit state
   machines, filesystem changes, and MediaPlayer payloads. Use E2E for the
   listener-visible wiring between controls and those production boundaries.
9. Use physical-device acceptance where Simulator cannot prove the behavior,
   especially Photos, Files, StoreKit sandbox, Share Extension, Bluetooth,
   AirPods, cars, Lock Screen, and Control Center.
10. Record the exact commit SHA, test command, device/runtime, result, and
    artifact location for every acceptance gate.

## Ordered sequence

| Order | Remediation | Exit condition |
| --- | --- | --- |
| R0 | Stabilize and qualify E2E | The complete suite meets the repeated-run reliability gate with no unexplained failure or retry-to-green. |
| R1 | Make cover crop real | A saved crop changes every artwork surface and survives relaunch, undo, and backup/restore. |
| R2 | Replace the global import error alert | Errors retain their domain and present accurate, actionable titles and messages. |
| R3 | Repair search-result identifiers | Every search result exposes a unique, correctly interpolated identifier. |
| R4 | Complete Bookshelf branding | All user-facing app, receiver, extension, permission, backup, and recovery copy says Bookshelf consistently. |
| R5 | Qualify production StoreKit | Purchase, restore, redemption, pending, cancellation, failure, revocation, and relaunch are verified. |
| R6 | Prove permanent Trash deletion | Confirmed deletion removes only the intended managed media and rolls back safely on failure. |
| R7 | Cover committed-book metadata editing | Book Detail editing and every MVP metadata field/lock are wired, persisted, and undoable. |
| R8 | Cover real system ingress and artwork selection | Files, Photos, cover-file selection, and Share Extension paths receive platform and device acceptance. |
| R9 | Cover production backup UI | Both export kinds, Files transfer, confirmations, errors, and automatic restore are validated. |
| R10 | Prove live playback UI progression | Mini-player and Now Playing controls, times, and sliders update while audio advances. |
| R11 | Complete receiver coverage | Native receiver actions and browser pairing/upload/retry/cancel/completion are validated. |
| R12 | Cover every recovery choice | Retry, fresh-library preservation, launch-storage retry, and support export are validated. |
| R13 | Complete search UI coverage | Every sort and filter is exercised through UI and persists correctly. |
| R14 | Cover “Use Library Defaults” | Clearing a per-book override immediately and durably restores global behavior. |
| R15 | Qualify external playback surfaces | Lock Screen, Control Center, AirPods/headsets, Bluetooth cars, and artwork metadata pass device checks. |
| R16 | Close CI selection and test-contract gaps | Every intended UI regression runs in CI and every test name matches what it proves. |

## Current acceptance ledger

This ledger distinguishes implementation and deterministic coverage from gates
that require the exact hosted commit or physical Apple hardware. A row is not a
release pass while its remaining gate is listed as pending.

| Remediation | Implementation / automated evidence | Remaining gate |
| --- | --- | --- |
| R0 | Event-driven two-second waits, fail-closed evidence, the canonical selector manifest, repeated-attempt tooling, five balanced fresh-host dependency chains backed by one immutable build, 130 independently scheduled formal story attempts, and 25 subsequent fresh-host matrix attempts are implemented. The ledger contains 126 unique historical failure signatures and retains 19 formal qualification resets. Run [33289300337](https://github.com/anicolao/player/actions/runs/33289300337) passed exact head `b9dc9a98e61dd2a3f808d98e8bcf7d720b4df02d` without a rerun in 32m32s: all 13 stories, 41 UI selectors, 372 core tests, and the App Store renderer passed. This is 8m24s faster than the expanded-suite reference with identical coverage. Hardened formal run [33318614812](https://github.com/anicolao/player/actions/runs/33318614812) exposed a read-only Story 007 assertion's invalid tap-geometry dependency on attempt 10 and a representation-ambiguous XCTest failure attachment; both were corrected without retrying that run. Normal run [33325350089](https://github.com/anicolao/player/actions/runs/33325350089) exposed a separate Story 008 deadline-edge false negative, run [33328578179](https://github.com/anicolao/player/actions/runs/33328578179) exposed an independently missed Story 011 recovery action, a recurring pre-product Xcode/CoreSimulator launch-channel stall, and rejected attempt-wide log timestamps, run [33330232587](https://github.com/anicolao/player/actions/runs/33330232587) proved the prior single-shot Add coordinate still lacked a delivery receipt, and run [33330908421](https://github.com/anicolao/player/actions/runs/33330908421) proved the bounded preventive kickstart must defer to its independent readiness receipt. Formal run [33336466219](https://github.com/anicolao/player/actions/runs/33336466219) then passed Story 009 attempts 01 through 09 before exposing an arbitrary three-correction framing ceiling on attempt 10; the convergent event-driven replacement is verified. Formal run [33345429470](https://github.com/anicolao/player/actions/runs/33345429470) exposed a separate pre-synthesis delivery-deadline defect in Story 003 attempt 03; the same deadline boundary in Library Add and Backup Export was corrected in the scoped delivery-loop fix. Exact-code run [33349732905](https://github.com/anicolao/player/actions/runs/33349732905) passed all five lanes without a rerun: all 13 stories, all 41 selectors, 372 core tests, fixture gates, and the renderer. Normal finalized-ledger run [33351712764](https://github.com/anicolao/player/actions/runs/33351712764) then exposed a separate unacknowledged Story 008 sort-menu item tap; the replacement correlates menu presentation and the changed production search result independently before proceeding. Normal replacement run [33354131739](https://github.com/anicolao/player/actions/runs/33354131739) verified that correction, then exposed an independent Story 005 lifecycle race: Home completed after app activation and the intended Progress90 touch was dispatched to SpringBoard. The replacement requires separate SpringBoard foreground-ownership and exact app-contained foreground-interactive receipts before bounded synthesis. Fresh-host run [33421395062](https://github.com/anicolao/player/actions/runs/33421395062) passed every current automated gate without a rerun and supplies the deterministic-scheduler baseline. Scheduler run [33426513529](https://github.com/anicolao/player/actions/runs/33426513529) exercised every successor despite two independent pre-product LaunchServices races; both exact signatures are now repaired and retained rather than rerun. | Require the repaired scheduler run to pass with identical coverage, then dispatch its one permitted formal gate and require 10/10 for every story plus 5/5 complete matrices. Publish the generated stability and timing report. |
| R1 | Complete: real crop rendering is covered across save, relaunch, undo, and artwork consumers. | None. |
| R2 | Complete: presentation errors retain their owning domain and actionable copy. | None. |
| R3 | Complete: search-result identifiers are unique, interpolated, navigable, and source-checked. | None. |
| R4 | Complete: Bookshelf branding is verified across app, extension, receiver, generated project, and compatibility-sensitive surfaces. | None. |
| R5 | Production StoreKit state, configuration, purchase, restore, redemption, pending, cancellation, failure, revocation, and relaunch paths have deterministic coverage. | Run the App Store sandbox and physical-device purchase matrix on the release candidate as required by `APP_STORE_SUBMISSION_PLAN.md`. |
| R6 | Complete: permanent Trash deletion is transactional, scoped to the selected book, failure-safe, and covered through production UI. | None. |
| R7 | Complete: committed-book editing covers every MVP field, lock, validation, cancellation, save, persistence, and undo contract. | None. |
| R8 | Files, Photos, cover-file selection, and Share Extension transaction boundaries have deterministic unit and E2E coverage. | Complete SI-01 through SI-14 in [SYSTEM_INGRESS_ACCEPTANCE.md](SYSTEM_INGRESS_ACCEPTANCE.md) on one release candidate. |
| R9 | Portable and settings backups, both export kinds, Files outcomes, durable transactions, error paths, and automatic restore have deterministic production-UI coverage. | Confirm physical-device Files-provider export, transfer, restore, and automatic restore on the release candidate. |
| R10 | Complete: engine events drive live mini-player and Now Playing progress, chapter, time, slider, pause, and restore state. | None. |
| R11 | Complete: browser and native receiver pairing, upload, retry, cancellation, completion, port continuity, and durable import lifecycle are covered. | None. |
| R12 | Complete: every recovery choice, fresh-library preservation, storage retry, and support export path is covered. | Smoke-test launch recovery and support export on the physical release candidate. |
| R13 | Complete: every production sort/filter combination, clear path, rapid preference transition, persistence, and result navigation is covered. | None. |
| R14 | Complete: “Use Library Defaults” clears overrides atomically, updates live behavior, persists across relaunch, and leaves truthful state on failure. | None. |
| R15 | Now Playing metadata/artwork, command registration, durable position, interruptions, and route loss have deterministic adapter and E2E coverage. | Complete EP-01 through EP-07 in [EXTERNAL_PLAYBACK_ACCEPTANCE.md](EXTERNAL_PLAYBACK_ACCEPTANCE.md) on one release candidate. Apple Watch remains explicit post-MVP scope. |
| R16 | Complete: CI selects every canonical regression, names describe the proved behavior, close controls are unambiguous, and reviewed screenshot policies survive baseline recording. | The final branch tip must pass the normal five-lane CI matrix before formal qualification is dispatched. |

## R0 — Stabilize and qualify E2E

### Goal

Make a green E2E result trustworthy before using the suite to validate product
remediation. Until this gate passes, all current E2E results should be treated
as useful evidence but not conclusive release protection.

### Work

1. Inventory every UI test and helper for nondeterministic behavior:
   - fixed sleeps or delayed dispatch;
   - waits longer than two seconds;
   - assertions made before the state transition they purport to prove;
   - unbounded or fixed-count gesture loops without a semantic stop condition;
   - ambiguous element queries and duplicate labels;
   - keyboard, focus, sheet, navigation, process-lifecycle, and system-alert
     races;
   - screenshot capture before layout, scrolling, artwork decoding, or state
     publication has settled;
   - shared fixture directories, simulator defaults, keychain state, receiver
     ports, clocks, IDs, or process state leaking between tests;
   - E2E bridges that report an intended value rather than an independently
     observable production result.
2. Classify each historical or reproducible failure by root cause. Do not group
   failures under “flaky” without evidence that they share a cause.
3. Replace every fixed delay with a domain event or observable semantic state.
   Examples include an acknowledged playback position, committed library
   revision, completed import phase, focused field plus visible keyboard,
   settled geometry, or disappearance of the prior screen.
4. Cap all transition waits at two seconds and fail with the latest semantic
   state, active alert, navigation state, and relevant element geometry.
5. Give every test an isolated persistence root, fixture namespace, deterministic
   clock/ID stream, and explicitly selected initial route. Reset keychain or
   StoreKit test state only inside that test's namespace.
6. Make screenshot capture conditional on the same semantic and geometric state
   used by the assertion. Keep explicit baseline recording separate from normal
   test execution; never update expected images after an unreviewed failure.
7. Add a test-hygiene check that rejects fixed sleeps in UI tests, timeout values
   above two seconds, recording mode in CI, and selectors omitted from the
   canonical story manifest.
8. Ensure every failed attempt uploads its `.xcresult`, expected image, actual
   image, diff, semantic probes, and application/system logs. Retain artifacts
   long enough to investigate repeated-run failures.
9. Remove any CI retry mechanism that hides the first failure. Provide an
   explicit measurement command that runs named tests repeatedly and reports
   attempts, pass/fail counts, and failure signatures without discarding
   artifacts.
10. Before changing the E2E harness, record a runtime baseline for the complete
    canonical suite. Capture total wall-clock time, per-story wall-clock time,
    test execution time, build/setup time, artifact export/materialization, and
    screenshot comparison. Record the machine, load, Xcode/runtime, and exact
    SHA so the measurement can be reproduced.
11. Profile the baseline and remove avoidable duplicated work only when doing so
    preserves story isolation. In particular, quantify simulator creation/boot,
    receiver-web/project generation, one cold `build-for-testing` operation per
    canonical story (13 currently), test execution, `.xcresult` attachment
    export, walkthrough materialization, and pixel comparison.
12. Run focused repetitions while repairing each independent failure class,
    then qualify the complete matrix on clean simulator state.

The reproducible pre-change measurement, phase profile, and R0 comparison
contract are recorded in [E2E_RUNTIME_BASELINE.md](E2E_RUNTIME_BASELINE.md).

### Acceptance

- No E2E source or helper uses a fixed sleep to wait for product behavior.
- No normal product transition waits more than two seconds.
- Every loop terminates because a named condition became true or the two-second
  deadline expired.
- Every screenshot is preceded by semantic and geometric readiness assertions.
- A failure artifact is sufficient to identify the failing condition and see
  expected, actual, and diff images without rerunning the test.
- Running one story cannot change the result of another story.
- No test depends on execution order, a previously booted simulator, a reused
  receiver port, or residual defaults/keychain/files.
- No failure is waived as flaky without a recorded, independently supported
  root cause.

### Reliability exit gate

1. Run each canonical story ten consecutive times from isolated clean test
   state. Require 10/10 passes for every story.
2. Run the complete CI matrix five consecutive times from clean checkouts or
   equivalently isolated hosts. Require 5/5 green matrices.
3. Preserve results and artifacts for every attempt, including successful ones'
   manifests and failed attempts' complete diagnostics.
4. Any unexplained failure resets the affected qualification count after its
   root cause is corrected. Infrastructure outages must be evidenced separately
   and may be excluded only when the app and test process did not begin.
5. Publish a short stability report listing attempts, failures by signature,
   fixes, final pass counts, runtime distribution, and the exact qualifying SHA.
6. Repeat the baseline timing procedure on the qualifying SHA using the same
   machine class and command. Report before/after totals and per-phase deltas.
   The median complete-suite runtime must not regress by more than 10%, and no
   individual story may regress by more than 20%, unless the added coverage is
   intentional, measured, and approved. Reliability fixes should preferentially
   make failures faster rather than increasing success-path timeouts.

## R1 — Make cover crop real

### Work

1. Define one canonical crop renderer that applies unit-space bounds and any
   supported rotation to the retained original image.
2. Use the renderer in the crop preview and every saved artwork consumer:
   shelves, lists, Book Detail, mini-player, Now Playing, MediaPlayer/Lock Screen,
   portable backup, and restored libraries.
3. Decide whether rendered bytes are cached. If cached, make the original plus
   crop metadata authoritative so repeated edits never compound image loss.
4. Validate dimensions and crop bounds when decoding older or malformed data.
5. Extend metadata E2E to open Crop, change controls, Apply, Save, observe a
   visibly different result, relaunch, undo, and observe the original result.

### Acceptance

- Crop preview changes as controls move.
- Apply and Save change every artwork surface consistently.
- Crop survives relaunch and backup/restore.
- Undo restores both original crop metadata and rendered appearance.
- Remove/replace cover, Photos, Files, Bluetooth artwork, and uncropped legacy
  covers do not regress.

## R2 — Replace the global import error alert

### Work

1. Replace `lastErrorMessage` with a typed presentation error containing domain,
   title, message, recovery action, and optional diagnostic detail.
2. Give import, playback/audio session, metadata, bookmark, storage/Trash,
   backup, recovery, sleep timer, smart rewind, and monetization failures
   accurate presentation ownership.
3. Keep errors local to their active screen when possible; reserve root alerts
   for genuinely application-wide failures.
4. Translate raw `OSStatus`, filesystem, and StoreKit errors into actionable
   listener copy while preserving technical detail for sanitized diagnostics.
5. Add regressions proving a non-import error can never be titled as an import
   failure and that startup does not present a stale, harmless alert.

### Acceptance

- Every exercised failure has the correct title and recovery guidance.
- Raw platform codes are not the sole user-facing explanation.
- Dismissing one error cannot clear an unrelated failure.
- Import recovery screens retain their specialized behavior.

## R3 — Repair search-result identifiers

### Work

1. Correct interpolation and expose one stable identifier per book result.
2. Add an assertion that multiple results have distinct identifiers and each
   opens the intended Book Detail.
3. Add a lightweight source/test check for accidental literal interpolation
   patterns in accessibility identifiers.

### Acceptance

- Identifier values contain the expected lowercased book UUID.
- No two visible results share an identifier.
- VoiceOver labels and navigation remain correct.

## R4 — Complete Bookshelf branding

### Work

1. Inventory user-facing `Player` copy in the iOS app, Share Extension, receiver
   web source and built asset, permission descriptions, Bonjour-facing names,
   backup/support filenames and type descriptions, alerts, and documentation.
2. Change visible product copy to Bookshelf while preserving internal bundle
   identifiers, migrations, file extensions, and compatibility contracts unless
   a separately reviewed migration is required.
3. Rebuild the committed receiver web asset and verify generated-project
   reproducibility.
4. Review screenshots, permission prompts, exported filenames, and share-sheet
   messaging for consistent naming.

### Acceptance

- Users see Bookshelf consistently across all supported surfaces.
- Existing libraries, backups, app-group handoffs, and receiver discovery remain
  compatible.
- No internal identifier rename causes data loss or StoreKit incompatibility.

## R5 — Qualify production StoreKit

### Work

1. Add a checked-in StoreKit configuration matching the production non-consumable
   product identifier and Family Sharing behavior.
2. Test the production manager's verified/unverified transactions, product
   loading, purchase success, user cancellation, pending approval, failure,
   restoration with and without ownership, revocation/refund, transaction
   updates, cached offline ownership, and environment-separated allowance data.
3. Extend E2E to activate Restore and Redeem rather than merely asserting their
   presence. Verify feedback, disabled/progress states, sheet completion, and
   entitlement refresh.
4. Verify the 50-hour meter across relaunch and exact limit crossing without
   charging paused/background-stalled time.
5. Qualify the actual configured IAP through TestFlight sandbox, including
   purchase, restore on another device/account state, redemption, relaunch, and
   offline startup after verified ownership.

### Acceptance

- Every StoreKit outcome is normal, actionable, and never deletes or hides the
  library.
- A verified owner remains unlocked across relaunch and temporary storefront
  outages; revoked ownership is handled according to policy.
- Restore and offer-code redemption demonstrably refresh entitlement.
- Test and production environments cannot contaminate one another.

## R6 — Prove permanent Trash deletion

### Work

1. Add model tests for successful Trash purge, missing/nonrecoverable
   transactions, confined filesystem deletion, persistence failure, filesystem
   failure, and rollback.
2. Prove that only app-managed media inside the selected transaction is removed;
   source files and other books remain byte-identical.
3. Extend E2E to choose Delete Forever, confirm, wait for the purged transaction
   state, and verify that the book cannot be restored and storage totals update.
4. Verify relaunch, reimport of the same source, current-book removal, and
   playback/Now Playing cleanup.

### Acceptance

- Confirmed deletion removes exactly the selected managed media and catalog
  recovery data.
- Cancel performs no mutation.
- Any failed deletion restores a coherent recoverable state.
- The source audiobook is never modified.

## R7 — Cover committed-book metadata editing

### Work

1. Add an E2E journey through Book Detail -> Edit, separate from Import Review.
2. Exercise sort title, subtitle, authors, narrators, series name/position,
   description, genres, tags, language, publication year, publisher, edition,
   abridgement, and representative per-field locks/explicit clears.
3. Verify validation and keyboard bindings, contributor/list parsing, disabled
   series position without a series, Save/Cancel, persistence, search/index
   updates, browse projections, and atomic undo.
4. Verify that editing metadata never rewrites audio bytes.

### Acceptance

- Every MVP field can be edited through production UI and survives relaunch.
- Derived Library/Search/Browse displays update immediately and correctly.
- Cancel preserves the prior snapshot; Undo restores all fields atomically.
- Import-proposal editing continues to work independently.

## R8 — Cover real system ingress and artwork selection

### Work

1. Keep deterministic tests for core import semantics, but add platform
   acceptance for the in-app Files importer with single, multiple, folder, and
   ZIP selections plus cancellation and provider failure.
2. Exercise Photos selection and cover-file selection from the production source
   chooser, including cancellation, limited access, unreadable data, and an
   iCloud-backed image where available.
3. Add Share Extension UI/integration coverage from a real share request through
   visible success/failure and app Inbox consumption.
4. Ensure security-scoped access and temporary provider URLs remain valid only
   as long as needed and are released/cleaned after copying.
5. Document Simulator limitations and retain physical-device evidence for each
   system picker/provider path.

### Acceptance

- Each entry point reaches the same durable import or metadata transaction.
- Cancellation leaves no job, partial file, or lost cover draft.
- Provider failures are actionable and preserve originals.
- App restart safely resumes or cleans interrupted ingress as designed.

## R9 — Cover production backup UI

### Work

1. Drive With Audio and Metadata Only selections through the visible Export
   action and verify prepared package kind, progress, success, cancellation, and
   cleanup after the document picker dismisses.
2. Drive Choose Backup through Files, destructive confirmation, successful
   restore, incompatible/tampered package failure, and cancellation.
3. Drive Restore Latest Database Backup through its confirmation and verify
   library replacement while managed audio remains intact.
4. Keep deterministic package-level tests, but remove reliance on hidden E2E
   controls as the sole acceptance evidence for visible production actions.
5. Perform physical-device Files acceptance with local and cloud-backed
   destinations/providers.

### Acceptance

- Both export kinds produce the documented contents.
- No restore changes the current library before complete integrity validation.
- Progress, success, and failure UI accurately reflect the operation.
- Temporary prepared exports are discarded after completion or cancellation.

## R10 — Prove live playback UI progression

### Work

1. Add a deterministic playback engine event that advances acknowledged engine
   time while reporting normal playback progress; do not use wall-clock sleeps.
2. Through E2E, tap the mini-player play/pause control and verify status, elapsed
   label, remaining label, mini-player timeline, full-player slider, chapter
   context, and accessibility values update from the progress event.
3. Verify progress while the app is visible, after opening/closing Now Playing,
   and after returning from background.
4. Cover zero/unknown duration, book completion, track/chapter boundaries,
   scrubbing during progress, and pause without creating journal noise.

### Acceptance

- Every visible playback surface advances from one injected engine-progress
  event within two seconds.
- Pausing freezes the UI at the acknowledged position.
- Relaunch restores at or behind the acknowledged durable position.
- The mini-player control never accidentally opens Now Playing instead of
  changing playback state.

## R11 — Complete receiver coverage

### Work

1. Exercise Copy Address, Choose from Files, Stop Receiving and confirmation,
   Close while active, Open Inbox after needs-review, retry after an import
   failure, restart after listener failure, Receive Another, and Done.
2. Verify cancellation removes only partial receiver files and accepted imports
   survive receiver shutdown.
3. Add browser component/integration tests for pairing success/failure, file and
   folder selection, drag/drop, progress polling, retry/resume, cancel/cleanup,
   importing, needs-review, completion, session expiry, and accessible keyboard
   operation.
4. Add one real local HTTP browser-to-app integration journey, leaving low-level
   transfer edge cases in the existing server tests.
5. Verify receiver port reuse, pairing-code rotation, and cleanup across screen
   reopen and app relaunch.

### Acceptance

- Every visible native and browser action changes the expected production state.
- Retry resumes only from server-confirmed bytes.
- Stop/cancel cannot delete an already accepted import.
- Browser and iPhone agree on transfer state and completion outcome.

## R12 — Cover every recovery choice

### Work

1. Add UI scenarios for Try Opening Again succeeding and remaining failed.
2. Exercise Start with an Empty Library through confirmation and prove that the
   unreadable primary and unrecognized app-owned files remain quarantined.
3. Inject launch-environment storage failure, exercise Try Again, and verify
   recovery once storage becomes available.
4. Exercise support-bundle export from the recovery screen, including picker
   cancellation and preparation failure.
5. Keep corruption, newer-schema, and unavailable-storage explanations distinct.

### Acceptance

- Every recovery action is reachable, truthful, and preserves promised evidence.
- A failed retry never mutates the primary.
- Starting fresh never deletes quarantined recovery material or managed audio.
- Successful retry/recovery reaches a coherent operational library.

## R13 — Complete search UI coverage

### Work

1. Through UI, exercise Title, Author, Series Order, Recently Added, Duration,
   and Progress sorts in both meaningful directions.
2. Exercise Any, Unplayed, In Progress, and Finished listening filters plus M4B
   and Missing Metadata independently and in representative combinations.
3. Verify result order, summary copy, empty-query/filter state, Clear All, result
   navigation, persistence, and reset across relaunch.
4. Keep exhaustive comparison logic in unit tests and use a minimal deterministic
   fixture matrix for UI wiring.

### Acceptance

- Every menu item changes the model and visible results it claims to change.
- Combined filters produce correct, stable ordering.
- Persisted choices and Clear All behave correctly after relaunch.

## R14 — Cover “Use Library Defaults”

### Work

1. Create and persist a per-book override, change global defaults, then tap Use
   Library Defaults through the production editor.
2. Verify immediate control labels, skip behavior, rate, seek context, remote
   command configuration, and relaunch state all resolve to current global
   defaults.
3. Cover failure to persist the clear operation without dismissing into a
   misleading state.

### Acceptance

- The per-book override is removed atomically.
- Current and external controls immediately use global values.
- Relaunch does not resurrect the override.

## R15 — Qualify external playback surfaces

### Work

1. Retain unit coverage for `MPNowPlayingInfoCenter`, artwork resizing,
   `MPRemoteCommandCenter`, interruption, route loss, configured skips, chapters,
   rate, and durable positions.
2. Add a written physical-device matrix covering Lock Screen, Control Center,
   wired/Bluetooth headset or AirPods, and at least one car receiver such as the
   reported Tesla path.
3. Verify title, author, series/album, chapter, duration, elapsed time, rate,
   play/pause, configured forward/back intervals, scrub, interruption recovery,
   and square cover artwork on every applicable surface.
4. Capture iPhone/iOS, accessory/vehicle, connection type, book format, and
   results. Treat Apple Watch Now Playing as post-MVP unless it works
   automatically and can be checked without broadening scope.

### Acceptance

- Supported external controls match in-app semantics and durable state.
- Artwork and metadata appear on Lock Screen and representative Bluetooth/car
  targets.
- Route changes and interruptions do not lose or advance position incorrectly.
- Device evidence is attached to the release candidate, not inferred from
  Simulator E2E.

## R16 — Close CI selection and test-contract gaps

### Work

1. Generate the CI UI-test selector matrix from one reviewed manifest or add a
   check that fails when a test method is not intentionally included or marked
   manual/noncanonical with a reason.
2. Add the zero-duration Now Playing regression to its canonical story.
3. Either add the accessibility-preference test to CI and make it relaunch to
   prove persistence, or rename/restructure it to match the narrower behavior it
   actually verifies.
4. Audit all test names, narratives, and preconditions for claims stronger than
   their assertions, especially “production,” “real,” “persists,” and
   “end-to-end.”
5. Make the complete-suite script and CI consume the same selector source so
   local qualification cannot silently differ from the merge gate.

### Acceptance

- Every intended automated regression runs in both the documented complete
  suite and CI.
- Any intentionally excluded test has an owner, reason, and alternative
  acceptance evidence.
- Test names and walkthrough narratives state exactly what the assertions prove.
- Adding a new UI test without classifying it fails repository validation.

## Final release gate

After R16:

1. Repeat the R0 complete-matrix qualification on the final candidate SHA.
2. Run all core/unit/integration tests plus receiver web tests and static checks.
3. Complete the physical-device matrix for Photos, Files, Share Extension,
   StoreKit sandbox, external playback controls, Bluetooth/car artwork, backup,
   and recovery.
4. Review every changed canonical screenshot and all failure-path copy.
5. Confirm a clean generated project and receiver web build from a fresh
   checkout.
6. Record remaining explicitly deferred work, with Apple Watch integration the
   only anticipated post-MVP item from this audit.

The application is ready for another public-beta candidate only when the final
SHA passes these gates without rerun-to-green or unexplained failure.
