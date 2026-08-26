# Next steps

Status: implementation complete; physical-device beta acceptance pending
Created: 2026-08-25
Updated: 2026-08-26
Source: [issues.txt](issues.txt)

## Objective

Resolve the current physical-device beta feedback in risk order, with a focused
regression test and a physical-device acceptance check for behavior that cannot
be proven faithfully in Simulator.

The two cover-art bullets in `issues.txt` describe one issue and are combined
below. Sleep-timer fading and Photos-based cover replacement already exist in
the implementation, so those reports must be reproduced against the shipping
build before deciding whether the defect is presentation, integration, or
playback behavior.

## Implementation record

| Item | Result | Evidence |
| --- | --- | --- |
| External transport semantics | Implemented in `e3db95a`: external previous/next events now use configured intervals across the combined book timeline. | Full CI [32919008481](https://github.com/anicolao/player/actions/runs/32919008481) passed. |
| Repeated Library bounce | Implemented in `7349e69`: the main Library no longer vertically bounces while retaining bottom runway and horizontal shelves. | Full CI [32922414726](https://github.com/anicolao/player/actions/runs/32922414726) passed. |
| Replace Cover from Photos | Implemented in `03fce80`: the production Photos picker is presented after source selection, with explicit cancellation/failure handling and an E2E seam after the real chooser. | Full CI [32926334151](https://github.com/anicolao/player/actions/runs/32926334151) passed. |
| Sleep-timer fade | No repair commit was justified: the existing five-second stepped fade, exact stop, volume restoration, persistence, and dismissal behavior passed focused tests and Story 007. | Full CI [32929302975](https://github.com/anicolao/player/actions/runs/32929302975) passed, including Story 007. |
| Backup explanation | Implemented in `71c4566`: listener-first purpose and clear descriptions of With audio, Metadata only, and automatic on-device copies precede the actions. | Full CI [32929302975](https://github.com/anicolao/player/actions/runs/32929302975) passed, including the verified Story 010 round trip. |

The remaining acceptance work requires physical hardware and must be repeated
against the beta containing these commits: the originally affected car and a
headset/AirPods route; Ellie's phone; the real Photos picker with a local and,
if available, iCloud-backed image; and audible sleep-timer fading on speaker,
Bluetooth, and headphones. Simulator and CI evidence cannot substitute for
those output-route and device-specific checks.

## Priority order

| Priority | Issue | Reason |
| --- | --- | --- |
| P0 | External skip-forward can skip an entire track | A transport control does something materially different from what it promises, especially in a hands-free/car context. |
| P0 | Library can bounce forever after scrolling past the bottom | A persistent device-specific interaction failure can make the main screen unusable and may indicate a layout/scroll feedback loop. |
| P1 | Replace Cover does not successfully choose a photo | This is a promised library-repair action with no equivalent in-app workaround. The two source bullets are one defect. |
| P1 verification | Sleep-timer fade-out | The five-second fade, UI toggle, persistence, and deterministic tests already exist. Confirm whether the reported gap is an inaudible/broken fade, insufficient duration, or discoverability before changing it. |
| P2 | Explain what Backup is for | No data-integrity failure is reported, but the current technically detailed screen does not first explain the user benefit or distinguish exported and automatic backups clearly enough. |

## P0.1 — Correct external transport semantics

### Current lead

`MPRemoteCommandController` registers interval skip commands, but also maps the
system next-track command to next chapter. Some car and headset controls expose
their forward button as next-track rather than skip-forward, which could explain
the reported whole-track jump. This is a lead to verify, not yet a confirmed
root cause.

### Work

1. Record the affected car/head unit, connection type, iPhone model, iOS
   version, configured skip interval, book structure, and observed before/after
   positions.
2. Log or inject the exact `MPRemoteCommand` received and reproduce the same
   event against a multi-track synthetic book.
3. Make external forward/back controls use the configured skip intervals unless
   the surface explicitly presents a chapter action. Keep chapter controls in
   Now Playing distinct from interval skips.
4. Ensure interval skips cross track boundaries on the book timeline without
   jumping to the start of the next track, and clamp only at the beginning/end
   of the book.
5. Persist and publish the resulting position immediately to the app UI and Now
   Playing information.

### Acceptance

- The affected car's forward control advances by the configured interval, not a
  chapter or full track.
- Bluetooth/headset forward and backward controls have the same interval
  semantics.
- Lock Screen and Control Center skip buttons retain their advertised intervals.
- A skip that crosses a track boundary advances by exactly the requested amount
  on the combined book timeline.
- Play/pause, explicit chapter navigation, position persistence, and remote Now
  Playing updates do not regress.

### Evidence

- Unit coverage for every remote-command-to-player-action mapping.
- Integration coverage for forward/back skips within and across tracks.
- Existing Story 005 playback/restore journey remains green.
- Manual pass on the originally affected car plus one headset/AirPods route.

## P0.2 — Stop the Library's repeated bottom bounce

### Work

1. Capture Ellie's exact device model, iOS version, text size, display zoom,
   orientation, Library layout (`Shelf` or `List`), and whether the mini-player
   is visible.
2. Reproduce from a release build with the same library size and scroll gesture;
   screen-record the failure and determine whether the vertical scroll view,
   nested horizontal shelf, bottom runway, or changing geometry is repeatedly
   invalidating its content size.
3. Remove the layout/scroll feedback loop without removing the bottom runway
   needed to move the final Library action fully above the mini-player and tab
   pill.
4. Verify that shelf loading, cover shadows, Dynamic Type, rotation, and
   mini-player appearance/disappearance do not change the user's vertical offset
   continuously.

### Acceptance

- One overscroll gesture decelerates and settles normally; it never enters a
  self-sustaining bounce.
- The last Library item remains fully reachable above both persistent controls.
- Switching Shelf/List, showing/hiding the mini-player, rotating, and returning
  from detail do not restart or trap scrolling.
- The behavior is stable on the reported device and representative compact and
  large iPhone sizes, with default and accessibility text sizes.

### Evidence

- A focused UI regression covering bottom reachability and a stable settled
  scroll position.
- Existing Story 008 Library organization/search and Story 009 accessibility
  journeys remain green.
- Physical-device pass on Ellie's phone.

## P1.1 — Make Replace Cover work with Photos

### Current lead

The editor contains a `PhotosPicker`, but the E2E build substitutes fixture data
as soon as `Replace Cover` is tapped. That proves persistence and undo but
bypasses the real source chooser and Photos picker presentation, so the reported
failure is currently invisible to the regression suite.

### Work

1. Reproduce from both an imported book's detail screen and import review, noting
   whether the source chooser, Photos picker, selection load, preview, or save
   fails.
2. Present a real, reliable Photos selection path from `Replace Cover`; retain
   `Choose File`, crop, and remove as separate actions.
3. Handle cancellation, unreadable assets, iCloud-backed selections, and limited
   Photos access without losing the existing cover or draft edits.
4. Keep imported image bytes local, normalize unsupported image encodings when
   needed, and preserve the saved cover through relaunch and backup/restore.
5. Change the test seam so automation exercises source selection before injecting
   deterministic image bytes rather than bypassing the chooser altogether.

### Acceptance

- `Replace Cover` -> `Choose Photo` presents the system Photos picker.
- Selecting a photo updates the editable preview; Save updates every shelf/list,
  detail, mini-player, and Now Playing artwork surface after relaunch.
- Cancelling or failing selection leaves the previous cover unchanged and shows
  an actionable error when appropriate.
- `Choose File`, crop, remove, undo, and metadata field edits still work.

### Evidence

- Extend Story 004 to cover the source chooser and retained deterministic cover
  assertions.
- Add focused tests for selection cancellation/failure and persistence.
- Manual Photos-picker pass on a physical device, including an iCloud-backed
  photo if available.

## P1.2 — Verify the sleep-timer fade on real playback

### Current state

The timer defaults to `Fade out gently`, documents a final five-second fade,
persists its setting, drives player volume down in steps, and has deterministic
E2E coverage. The terse source issue does not say whether this implementation
is broken, too short, or simply undiscoverable.

### Work

1. Test an elapsed-time timer and end-of-track timer on speaker, Bluetooth, and
   headphones with normal audible playback.
2. Confirm that the fade begins five seconds before the exact stop boundary,
   decreases smoothly, stops exactly once, and restores normal volume for later
   playback or cancellation.
3. If the fade is working, close the issue as already delivered and improve
   discoverability only if observation shows users miss the existing toggle.
4. If it is not perceptible or does not reach external routes, repair the audio
   path and elevate this item to P0. Do not lengthen or make the duration
   configurable without a separate product decision.

### Acceptance

- The fade is clearly audible and smooth on supported output routes.
- Playback stops at the intended timer boundary, not five seconds early or late.
- Cancel/replacement/interruption never leaves subsequent playback muted or at a
  reduced volume.
- With fading disabled, playback remains at normal volume until the exact stop.

### Evidence

- Existing Story 007 and sleep-timer unit/integration tests remain green.
- Add a playback-engine volume regression if physical testing exposes a gap.
- Record the physical output routes and results in the issue/commit notes.

## P2 — Explain Backup in listener terms

### Work

1. Lead the Settings row and Backup screen with the purpose: Player is local, so
   an exported backup protects the library and can move or restore it after loss
   or replacement of a phone.
2. Distinguish the three concepts before presenting actions:
   - `With audio`: a portable, self-contained recovery copy.
   - `Metadata only`: organization, edits, positions, and preferences; original
     audio files are still required.
   - `Automatic database backups`: up to three on-device catalog safety copies;
     they are not portable and do not duplicate audio.
3. State where exported backups go (a Files destination chosen by the listener),
   that Player does not upload them, and that restore verifies a package before
   replacing the current library.
4. Keep destructive restore confirmation concise and explicit about what will be
   replaced.

### Acceptance

- A first-time listener can answer what each backup type protects, where it is
  stored, and which one can recover audio without reading implementation terms.
- Copy does not imply cloud sync, automatic off-device protection, or audio in a
  metadata-only backup.
- VoiceOver order and largest Dynamic Type retain all explanations and actions.

### Evidence

- Update Story 010's reviewed Backup frame and accessibility assertions.
- Existing backup round-trip, corruption, rotation, and offline tests remain
  green; this milestone should not alter backup format or behavior.

## Delivery sequence

Use one independently green commit per item:

1. `fix: keep external skips on the book timeline`
2. `fix: stop repeated Library overscroll bouncing`
3. `fix: choose replacement covers from Photos`
4. Sleep-timer repair commit only if physical verification finds a defect
5. `docs/ui: explain library backup choices` (final wording based on the UI
   change; this is app copy, not a documentation-only release)

After P0 and P1 are green, run the complete unit/E2E suite, create one beta build
containing all confirmed fixes, and repeat the physical car, Library scroll,
Photos selection, and sleep-output checks against that exact build. Backup copy
may ship in the same build if complete; it must not delay verified correctness
fixes.
