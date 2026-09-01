# Application remediation plan

**Status:** Implementation and deterministic automated coverage are complete
through R16. The five-chain scheduler has passed normal CI with unchanged
coverage and a recorded before/after measurement. Formal exact-SHA R0
qualification is exposing and driving independently diagnosed repairs;
physical-device release acceptance remains pending.
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
| R0 | Event-driven two-second waits, fail-closed evidence, the canonical selector manifest, repeated-attempt tooling, five balanced fresh-host dependency chains backed by one immutable build, 130 independently scheduled formal story attempts, and 25 subsequent fresh-host matrix attempts are implemented. The ledger contains 135 unique historical failure signatures and retains 21 formal qualification resets. Run [33289300337](https://github.com/anicolao/player/actions/runs/33289300337) passed exact head `b9dc9a98e61dd2a3f808d98e8bcf7d720b4df02d` without a rerun in 32m32s: all 13 stories, 41 UI selectors, 372 core tests, and the App Store renderer passed. This is 8m24s faster than the expanded-suite reference with identical coverage. Hardened formal run [33318614812](https://github.com/anicolao/player/actions/runs/33318614812) exposed a read-only Story 007 assertion's invalid tap-geometry dependency on attempt 10 and a representation-ambiguous XCTest failure attachment; both were corrected without retrying that run. Normal run [33325350089](https://github.com/anicolao/player/actions/runs/33325350089) exposed a separate Story 008 deadline-edge false negative, run [33328578179](https://github.com/anicolao/player/actions/runs/33328578179) exposed an independently missed Story 011 recovery action, a recurring pre-product Xcode/CoreSimulator launch-channel stall, and rejected attempt-wide log timestamps, run [33330232587](https://github.com/anicolao/player/actions/runs/33330232587) proved the prior single-shot Add coordinate still lacked a delivery receipt, and run [33330908421](https://github.com/anicolao/player/actions/runs/33330908421) proved the bounded preventive kickstart must defer to its independent readiness receipt. Formal run [33336466219](https://github.com/anicolao/player/actions/runs/33336466219) then passed Story 009 attempts 01 through 09 before exposing an arbitrary three-correction framing ceiling on attempt 10; the convergent event-driven replacement is verified. Formal run [33345429470](https://github.com/anicolao/player/actions/runs/33345429470) exposed a separate pre-synthesis delivery-deadline defect in Story 003 attempt 03; the same deadline boundary in Library Add and Backup Export was corrected in the scoped delivery-loop fix. Exact-code run [33349732905](https://github.com/anicolao/player/actions/runs/33349732905) passed all five lanes without a rerun: all 13 stories, all 41 selectors, 372 core tests, fixture gates, and the renderer. Normal finalized-ledger run [33351712764](https://github.com/anicolao/player/actions/runs/33351712764) then exposed a separate unacknowledged Story 008 sort-menu item tap; the replacement correlates menu presentation and the changed production search result independently before proceeding. Normal replacement run [33354131739](https://github.com/anicolao/player/actions/runs/33354131739) verified that correction, then exposed an independent Story 005 lifecycle race: Home completed after app activation and the intended Progress90 touch was dispatched to SpringBoard. The replacement requires separate SpringBoard foreground-ownership and exact app-contained foreground-interactive receipts before bounded synthesis. Fresh-host run [33421395062](https://github.com/anicolao/player/actions/runs/33421395062) passed every current automated gate without a rerun and supplies the deterministic-scheduler baseline. Scheduler run [33426513529](https://github.com/anicolao/player/actions/runs/33426513529) exercised every successor despite two independent pre-product LaunchServices races; both exact signatures were repaired and retained rather than rerun. Its successor [33432987841](https://github.com/anicolao/player/actions/runs/33432987841) proved both registration repairs and again exercised every story and the core gate, then exposed two separate post-launch latency defects: Story 011 redundantly rescanned already validated recovery backups before support export, while Story 003 coupled its acquisition receipt to unrelated automatic-backup churn on a severely I/O-constrained host. Both signatures have focused regressions and complete canonical local validation. | Require the final branch tip to pass normal five-chain CI, then dispatch its one permitted formal gate and require 10/10 for every story plus 5/5 complete matrices. Publish the generated stability and timing report. |
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

The R0 row summarizes the earlier accepted milestone and the chronology below
retains the signature count at each subsequent checkpoint. The current exact
ledger contains **152 unique signatures** and **21 formal qualification
resets**.

### Current R0 qualification update

Normal [run 33439248042](https://github.com/anicolao/player/actions/runs/33439248042)
accepted the deterministic five-chain scheduler at exact commit
`daa062ace6118c5fbc127fe0a8af999488e81896`: all 13 stories, all 41 UI
selectors, 374/374 core tests, fixtures, exact walkthroughs, and the App Store
renderer passed without a rerun. Created-to-complete wall time was 48m15s,
versus 48m16s for the same-coverage fresh-host baseline; aggregate producer and
consumer time fell by 4m02s. The detailed comparison is in
[E2E_RUNTIME_BASELINE.md](E2E_RUNTIME_BASELINE.md).

The ensuing one-permitted formal dispatch
[33443538076](https://github.com/anicolao/player/actions/runs/33443538076)
exposed three independent failure classes: a transient SwiftUI List
removal layer disagreeing with an already committed multifile-order revision,
Xcode reinstalling the target app because the UI bundle retained
`TEST_TARGET_NAME`, and a legacy Node 20 artifact action reporting a successful
download without materializing the shared archive. Each retained artifact was
diagnosed independently; focused fixes and regressions are committed without
rerunning the failed SHA. Once those retained failures made qualification
impossible, the obsolete remaining queue was cancelled so it could not
monopolize all five hosted runners. Failure evidence also exposed and corrected a fourth
diagnostic defect that named an accepted canonical screenshot instead of the
actual differing image.

Subsequent normal run
[33447485617](https://github.com/anicolao/player/actions/runs/33447485617)
then exposed two separate Story 005 defects: a fully visible SpringBoard never
published the sampled foreground process state, and a returned XCUI slider
adjustment never reached the paused playback model. The replacement uses the
completed Bookshelf background checkpoint for lifecycle causality and exact
production receipts for every E2E slider. Two complete local Story 005 runs
and complete Story 004 crop validation pass. Normal run
[33452975911](https://github.com/anicolao/player/actions/runs/33452975911)
subsequently exposed an independent unacknowledged Files-selection gesture in
Story 006. Its replacement requires the exact terminal ZIP receipt and permits
redelivery only while the foreground empty-Library origin and idle ZIP probe
remain unchanged; two complete local Story 006 runs pass. The ledger at that point contained 134
unique signatures and 21 formal qualification resets. Normal run
[33455191815](https://github.com/anicolao/player/actions/runs/33455191815)
then proved the existing Story 005 Home-transition signature had a narrower
cause: Home-to-inactive and inactive-to-background each completed inside two
seconds, but their combined latency exceeded one shared deadline. The first
split was still incomplete: run
[33457933671](https://github.com/anicolao/player/actions/runs/33457933671)
showed scene-background entry and the subsequent durable playback checkpoint
were also distinct stages. The helper now requires inactive, background entry,
and checkpoint completion under independent two-second budgets before
reactivation; both lifecycle selectors pass a fresh local build. No dispatch is
currently being represented as a qualifying result. Normal run
[33460228354](https://github.com/anicolao/player/actions/runs/33460228354)
then passed the other 12 stories, all 374 core tests, fixtures, and renderer
inputs but exposed a separate pre-product Story 010 deployment race: Xcode
rediscovered and reinstalled `Player.app` from the shared built-products
directory after the harness had already installed and receipted it. XCTest's
resulting Developer testing assertion request arrived only after its internal
deadline. The harness now keeps the receipted simulator installation as the
only visible application during `test-without-building`, restores the exact
source bundle on every exit, and rejects any observed Xcode application
installation. Complete local Story 010 passes both selectors in 86.815 seconds
with no Xcode deployment event, all four reviewed screenshots accepted, and an
exact walkthrough README. The ledger now contains 135 unique signatures; the
failed normal run changed no formal qualification count.

Normal run
[33463264776](https://github.com/anicolao/player/actions/runs/33463264776)
then exercised every successor lane and passed the other ten stories, all 374
core tests, fixtures, and renderer inputs while exposing three independent
missed-action mechanisms. Story 007 cached a SwiftUI menu option whose backing
element was replaced during presentation; the replacement reacquires valid
geometry and requires the changed bookmark order. Story 005 treated return from
a switch tap as delivery; the replacement uses the native switch value as its
synchronous acceptance receipt and the durable settings value as completion.
Story 010 likewise treated return from a backup-fixture trigger tap as delivery;
the replacement observes its synchronous disabled state and exact final backup
probe. Complete local Stories 007, 005, and 010 now pass all 12 combined
selectors, all 11 reviewed screenshots, and all three exact walkthroughs. Story
010 also contains no deferred Xcode installation event. The ledger contains 138
unique signatures and retains 21 formal qualification resets; this failed
normal run changed no formal count.

Exact-tip normal run
[33466372451](https://github.com/anicolao/player/actions/runs/33466372451)
proved the Story 007 sort repair, then exposed a separate Story 005 lifecycle
false negative. After Home completed all three ordered production receipts,
Bookshelf and its exact Progress 90 button were fully rendered, enabled, and
unobstructed, but the helper additionally required a stale sampled
`XCUIApplication.state`. Reactivation now skips unrelated post-event
quiescence, freshly resolves the exact app-owned button, and uses its
enabled/hittable/contained geometry as the completion receipt. The complete
local Story 005 passes all eight selectors in 239.830 seconds, both shared
lifecycle users pass, all four screenshots are pixel-exact, and the walkthrough
is exact. The ledger contains 139 unique signatures and retains 21 formal
qualification resets; this failed normal run changed no formal count.

The same run later exposed a separate pre-product Story 001 launch failure.
The startup-warning selector passed but left Bookshelf running; the next
selector's opaque compound terminate-and-relaunch transaction created a process
without acquiring its automation assertion before XCTest's private deadline.
The startup-warning journey now proves a completed `.notRunning` handoff before
returning. Complete local Story 001 passes all nine selectors in 85.660 seconds;
the formerly failing next selector attaches in 0.1 seconds, all six screenshots
are pixel-exact, and the walkthrough is exact. The ledger contains 140 unique
signatures and retains 21 formal qualification resets.

The run's final independent failure was a pre-product Story 002 accessibility
timeout. The share-extension handoff selector passed its product assertions but
left its replay process running; the next selector's orientation setup then
hung while enumerating active applications through that stale automation
surface. Both ingress journeys now prove completed `.notRunning` handoffs.
Complete local Story 002 passes all seven selectors in 89.470 seconds; five
screenshots are pixel-exact, the sixth is within its existing reviewed channel
allowance, and the walkthrough is exact. Story 012 and every remaining chain in
the diagnostic run passed. The ledger contains 141 unique signatures and
retains 21 formal qualification resets.

Exact-tip normal run
[33469155674](https://github.com/anicolao/player/actions/runs/33469155674)
then passed the shared producer, ten stories, all 374 core tests, fixture gates,
and the renderer inputs while exposing three independent UI-test contracts.
Story 008 treated a valid no-motion drag at an already-clamped shelf endpoint as
missed delivery; the replacement proves a progress-making retreat and exact
restoration. Story 001 collapsed the receiver's importing and committed phases
into one terminal poll; it now waits for independent non-polling production
receipts. Story 011 similarly resumed accessibility polling while an accepted
support-verification task was publishing completion; it now waits for the real
operation-finished event before reading the rendered probe. Complete local
Stories 008 and 001 pass all 12 combined selectors with all 16 screenshots
pixel-exact and both walkthroughs exact. The repaired Story 011 path completes
locally in about one second with its screenshot pixel-exact; its full fresh-host
story remains the next CI gate because the local host exhausted simulator
storage during later relaunches. The ledger contains 146 unique signatures and
retains 21 formal qualification resets; this normal run changed no formal count.

The next exact-tip normal run
[33472901959](https://github.com/anicolao/player/actions/runs/33472901959)
passed the shared producer, all 374 core tests, fixture gates, renderer inputs,
and 11 of 13 stories while exposing two additional, independent UI-test receipt
defects. Story 007's retained recording proves the bookmark search was focused
with its keyboard visible while an indirect accessibility focus probe remained
stale; text input now uses a pre-registered production FocusState event and
avoids unrelated post-event quiescence. Story 011 passed the repaired support
operation and all three pixel-exact screenshots, then exposed a later recovery
screen whose exact text was rendered after its polling boundary; every recovery
launch now has a pre-registered production presentation receipt. The complete
bookmark selector passes locally in 70.700 seconds with its screenshot exact,
and complete Story 011 passes locally in 63.341 seconds with all screenshots and
the walkthrough exact. These normal-run failures changed no formal count.

Exact-tip normal run
[33476262274](https://github.com/anicolao/player/actions/runs/33476262274)
then proved the Story 011 recovery-presentation repair and passed the other ten
unaffected stories, all 374 core tests, fixture gates, walkthrough contracts,
and renderer inputs. Its two failures were independent delivery defects. Story
007's first physical touch left the unchanged bookmark-label editor unfocused;
the helper now redelivers only while the exact editor origin and app-contained
field geometry remain unchanged, stopping on the production FocusState receipt.
Story 005's first slider gesture reached 25 percent instead of the requested 50
percent, but a stale sampled application state suppressed safe redelivery; the
helper now relies on the unchanged, enabled, hittable slider and exact app/field
geometry while retaining the semantic playback value as completion. Complete
local Stories 007 and 005 pass all ten combined selectors in 223.151 and
240.471 seconds respectively, all seven screenshots are pixel-exact, both
walkthroughs are exact, and full E2E hygiene passes. The same Story 005 evidence
also exposed a diagnostic defect: XCTest's synchronous issue-recording hook
blocked for roughly 50 seconds trying to take a failure screenshot. Failure
capture now lives entirely in the outer harness, whose live simulator attempt
has an enforced two-second kill boundary and whose exact recording-frame
fallback already recovered this failure. Source hygiene rejects future
in-process failure capture. The ledger contains 152 unique signatures and
retains 21 formal qualification resets; this normal run changed no formal
count.

Exact-tip normal run
[33479649229](https://github.com/anicolao/player/actions/runs/33479649229)
then proved the Story 005 slider and Story 007 focus redelivery repairs and
passed eleven other stories' reviewed evidence, all 374 core tests, fixture
gates, and renderer inputs. Story 009 exposed a pre-product first-launch stall:
although its newly created simulator had returned from `bootstatus`, one-time
widget, Spotlight, accessibility-asset, and TTS work continued to monopolize
RunningBoard, delaying process creation for roughly 34 seconds. Story 002 later
exposed the same first-boot epoch on a document-URL open; the failed platform
transaction consequently left a non-fixture import for the next worker class.
The harness now completes first-boot configuration, crosses a clean shutdown
and second-boot boundary, and verifies the persisted configuration before
installing either target. No fixed wait, retry-to-green, or deadline increase is
used. Complete local Story 002 test execution passed all seven selectors in
91.673 seconds, and canonical committed-code Story 009 passed both selectors in
112.250 seconds with all seven screenshots and its walkthrough accepted.

The Story 009 diagnostic also exposed a separate product transaction defect:
two accessibility preference writes could overlap an actor suspension, copy the
same stale library, and lose one mutation while optimistic switch state showed
both enabled. Library-organization mutations now enter a FIFO transaction gate,
the switches render durable model state, and a suspended-save regression proves
both concurrent changes persist. The ledger contains 152 unique signatures and
retains 21 formal qualification resets; the failed normal run changed no formal
count.

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
