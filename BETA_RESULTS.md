# Beta results

**Status:** Open findings and uncompleted acceptance work as of 2026-09-05  
**Code reviewed:** `main` at `93132efef6253a26e8be2fd98135202a2744c8de`  
**Current candidate:** Bookshelf 1.0 (34), uploaded 2026-09-04

## Conclusion

The beta has produced substantial useful coverage, but it is not accurate to
say that every reported issue is closed.

There are three defects still visible in the current source, one unexplained
catalog-recovery incident, six feedback-originated fixes that still lack the
required physical-device retest, and several release-candidate acceptance
matrices with no recorded result. Apple Watch support remains deliberately
deferred.

No TestFlight crash submission is newer than build 10, and all six submitted
crashes from builds 9–10 map to later fixes. The newest structured TestFlight
feedback is from build 31 on 2026-09-02. Builds 32–34 have no submitted
screenshot feedback or crash feedback as of this review; absence of a report is
not proof that the open items are fixed.

## Sources reviewed

- The complete App Store Connect TestFlight screenshot-feedback and
  crash-feedback collections for Bookshelf: 4 screenshot reports and 6 crash
  reports across the 34 uploaded builds. These are the two structured feedback
  channels exposed by Apple's
  [beta feedback APIs](https://developer.apple.com/documentation/appstoreconnectapi/beta-feedback-screenshot-submissions).
- The feedback and decisions recorded during internal and public-beta work in
  this repository and the product-development conversation.
- [`issues.txt`](issues.txt), [`NEXT_STEPS.md`](NEXT_STEPS.md),
  [`REMEDIATION_PLAN.md`](REMEDIATION_PLAN.md),
  [`SYSTEM_INGRESS_ACCEPTANCE.md`](SYSTEM_INGRESS_ACCEPTANCE.md), and
  [`EXTERNAL_PLAYBACK_ACCEPTANCE.md`](EXTERNAL_PLAYBACK_ACCEPTANCE.md).
- All GitHub issues, pull-request comments, and review comments. The issue
  tracker is empty and there are no unresolved human review comments.
- `r/BookshelfAudiobooks`, which currently contains its welcome/support post
  but no user bug report. Public promotional threads contributed the already
  implemented “no account / no subscription” positioning, not another product
  defect.
- Current production code and regression coverage, plus the latest `main` CI
  run, which passed: [run 33973303188](https://github.com/anicolao/player/actions/runs/33973303188).

## Unaddressed defects and incidents

These need product work or investigation; they are not merely missing manual
test records.

| ID | Priority | Finding | Evidence and current state | Required closure |
| --- | --- | --- | --- | --- |
| BETA-01 | P0 | A finished/current book can show stale progress in **Continue Listening**. | TestFlight build 31 showed the mini-player at the exact 9h52m19s end while the card above still said 99% and 5m left. Current `LibraryOrganizationViews.swift` still calculates the card from `Book.listeningState`, while live engine progress only updates `playbackState`; the two surfaces can therefore disagree until a durable checkpoint. No regression covers this exact cross-surface state. | Render the active book's card from authoritative live progress or update the observable book projection from engine events; remove a completed book promptly; add a regression reproducing the screenshot state. |
| BETA-02 | P2 | Book Detail does not pluralize its media count. | TestFlight build 30 reported “30 file.” Current `ContentView.swift` still renders `"\(book.assets.count) file"` for every count, and tests cover only the singular one-file case. | Render “1 file” and “N files” correctly and test both forms. |
| BETA-03 | P2 | Sleep-fade copy contradicts the implemented duration. | The requested default was changed to 10 seconds and `SleepTimerTests` asserts 10, but `SleepTimerView.swift` still tells listeners that volume fades during the “final five seconds.” `NEXT_STEPS.md` also retains the obsolete five-second description. | Change listener-facing and maintained documentation to 10 seconds and add a copy/behavior consistency assertion. |
| BETA-04 | P0 investigation | A build 30 launch found the primary catalog and three local recovery copies unreadable. | The tester reached **Library Recovery**, reported that **Try Opening Again** recovered successfully, and did not submit a diagnostic bundle. Later remediation proves recovery choices and preservation behavior, but it neither establishes nor removes the cause of this real incident. No recurrence is recorded on builds 31–34. | Treat as unresolved until the cause is identified or sufficient newer-build/upgrade soak evidence supports closure. On recurrence, preserve the sanitized support bundle before recovery and correlate the catalog schema, backup generations, previous build, available storage, and launch logs. |

## Implemented fixes that are not yet closed on hardware

The code and automated tests address each report below, but the repository's
own acceptance rules require a post-fix run on the affected route or device.
Every corresponding record is still `Pending`. These are unresolved beta risks,
not confirmed defects in build 34.

| ID | Original feedback | Implemented response | Missing closure evidence |
| --- | --- | --- | --- |
| BETA-05 | Playback stopped after a few seconds after connecting to a car and then appeared broken on all Bluetooth connections (TestFlight build 30). | R15 serializes audio-session events, handles interruption/route-loss state, and avoids unsafe speaker resume. | Reproduce the original connection sequence and pass EP-04 through EP-07, especially the reported car path. |
| BETA-06 | A car's skip-forward control skipped a whole MP3 track instead of the configured interval. | `34400a5` maps external previous/next controls to configured intervals on the combined book timeline. | Retest in the original car and one headset/AirPods route, including a skip across an MP3 boundary. |
| BETA-07 | Cover art was missing on a Bluetooth/Tesla display. | `7e1b55e` and R15 publish receiver-sized square artwork plus legacy receiver metadata. | Verify artwork presence and refresh on a capable Bluetooth receiver and the reported Tesla path (EP-05 and EP-06). |
| BETA-08 | The Library could bounce forever after overscrolling on Ellie's phone. | `9e8f8b7` removes vertical bounce while preserving horizontal shelves and bottom runway. | Retest on Ellie's phone with the original text size, display zoom, layout, library size, and mini-player state. |
| BETA-09 | Replace Cover / crop appeared to do nothing and did not let the listener choose a photo. | `d04394e` adds the production Photos chooser and `a44dc98` renders a saved crop across artwork consumers, with deterministic regressions. | Complete SI-06 through SI-09 using real full/limited Photos access, a local photo, an iCloud-only photo, and local/cloud Files images. |
| BETA-10 | Sleep-timer fade-out was reported as absent or inadequate; the later explicit product decision was a 10-second default. | `a7c786e` lengthens the implemented fade to 10 seconds and automated timer/volume tests pass. | Hear and record the fade on speaker, headphones, and Bluetooth; verify exact stop, cancel/replacement, volume restoration, and interruption behavior. BETA-03 must also be fixed. |

## Uncompleted internal acceptance

These are coverage gaps rather than observed failures. They remain relevant
because Simulator adapters cannot prove Apple picker, StoreKit, accessory, or
vehicle behavior.

### System ingress: SI-01 through SI-14 are all pending

1. One local M4B through Files, including picker cancellation.
2. Multiple local MP3 files as one transaction with no duplicate job.
3. A local MP3 folder with identity and ordering intact.
4. A local ZIP, plus atomic rejection of a ZIP mixed with sibling audio.
5. An initially undownloaded iCloud Drive item, actionable failure, and retry.
6. A local photo with full Photos access through crop, save, relaunch, and undo.
7. Limited Photos access, including grant, denial, and cancellation.
8. An iCloud-only photo, actionable failure, download, and retry.
9. Local and cloud-backed cover images through Files.
10. One audiobook through the Files share sheet.
11. Multiple audiobooks through the share sheet as one complete handoff.
12. Atomic rejection of supported and unsupported shared siblings.
13. Cancellation of an iCloud-backed share with no residual handoff files.
14. Relaunch during interrupted Files/share ingress with exactly-once cleanup or
    consumption.

### External playback: EP-01 through EP-07 are all pending

1. Lock Screen metadata, artwork, time, rate, controls, scrub, and durable
   restore.
2. Equivalent Control Center behavior.
3. Wired headset/remote controls and safe unplug behavior.
4. AirPods/Bluetooth controls, cross-MP3 skip, disconnect, and no speaker
   resume.
5. Metadata and square artwork on a capable Bluetooth display.
6. The actual reported car/Tesla route, including controls, artwork, metadata,
   disconnect, and position drift.
7. Real interruptions on speaker, headset, and car routes.

### Other release-candidate gates without a recorded pass

- StoreKit sandbox/TestFlight purchase, pending, cancellation, restore,
  redemption, refund/revocation, offline ownership, Family Sharing, and proof
  that beta purchases do not consume or unlock the production allowance.
- Physical Files-provider backup export, transfer to another location/device,
  restore, automatic-catalog recovery, and cancellation/failure behavior.
- A physical launch-recovery and sanitized-support-export smoke test, including
  confirmation that the bundle contains no unintended private data.
- Fresh install and populated-library upgrade testing on the final distributed
  candidate, including a fresh production 50-hour allowance for former beta
  users.
- The release-device checks still unrecorded in
  [`APP_STORE_SUBMISSION_PLAN.md`](APP_STORE_SUBMISSION_PLAN.md): AirDrop and
  document-open import, exact position after termination, airplane-mode launch
  and playback, minimum supported iOS where practical, VoiceOver and largest
  Dynamic Type, low storage/interrupted import, and absence of debug/E2E state
  in Release.
- The final R0 formal qualification required by
  [`REMEDIATION_PLAN.md`](REMEDIATION_PLAN.md): the current `main` tip has green
  normal five-chain CI, but the one permitted final exact-SHA repeated matrix
  and generated stability/timing report have not been recorded as passed.

## Explicitly deferred feedback

- Native Apple Watch validation or a Watch app remains post-MVP. Automatic
  system Now Playing behavior may work, but this project has neither claimed
  nor qualified Watch support.

## Feedback verified as addressed

The following reported problems have an implementation and appropriate
automated or direct post-fix evidence, and are not carried as open findings:

- The six submitted build 9–10 crashes: four Mirroring drop teardown crashes,
  one off-main Now Playing artwork callback crash, and one zero-duration Slider
  crash. They map to `de4fd7a` and `ce18962`; there is no later submitted crash.
- The misleading startup import alert (`OSStatus -50`) and globalized import
  error presentation.
- Mini-player position, bottom runway on scroll screens, inaccessible Trash and
  recovered-import Add actions, missing time labels, live mini-player/Now
  Playing progress, and the persistent Smart Rewind notice.
- Successful imports remaining in Inbox, Add/search placement, the integrated
  Add destination, and the direct computer receiver flow.
- Bookshelf shelf/list naming and the sequence of shelf visual, sizing, spine,
  endpoint, and scrolling refinements.
- Pausing between files in a multi-MP3 audiobook; the reporter subsequently
  confirmed the continuous-playback fix.
- Full Unlock implementation, account-free messaging, App Store screenshots,
  and website/navigation feedback. These are shipped or submitted metadata,
  not remaining beta product defects.

## Recommended order

1. Fix BETA-01 and investigate BETA-04 because they concern playback truth and
   library integrity.
2. Run the external hardware matrix, beginning with the original Bluetooth/car
   failure and Tesla artwork reports (BETA-05 through BETA-07).
3. Fix the small, deterministic BETA-02 and BETA-03 inconsistencies.
4. Complete the affected-device, Photos, sleep-fade, StoreKit, backup, recovery,
   and upgrade checks.
5. Run the final exact-SHA R0 qualification and attach its report before calling
   the beta fully closed.
