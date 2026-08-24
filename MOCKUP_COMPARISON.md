# MVP mockup comparison

Status: C06 audit complete; exact CI and TestFlight evidence pending
Audited: 2026-08-24

## Evidence reviewed

The audit inspected all 50 fresh native screenshots materialized by Stories
001–011 and compared the stable product states with the five approved boards:

- `docs/ux/mockups/01-library-import.png`;
- `docs/ux/mockups/02-review-metadata.png`;
- `docs/ux/mockups/03-listening.png`;
- `docs/ux/mockups/direct-import/01-iphone-receiver-flow.png`; and
- `docs/ux/mockups/direct-import/02-computer-uploader-flow.png`.

The screenshots are executable evidence, not hand-built marketing frames. They
use synthetic books, covers, durations, byte counts, IP addresses, and pairing
codes. The browser uploader is bundled in `Player/ReceiverWeb`; its pairing,
file/folder choice, drag and drop, progress, retry, cancellation, import, and
completion states are also covered by receiver unit and browser tests.

## Product issue found and fixed

| Surface | Finding | Resolution |
| --- | --- | --- |
| Presented and overlaid actions | Rust is the approved action color, but SwiftUI presentations outside the tinted `TabView` could fall back to system blue. This was visible in mini-player play actions, playback settings, sleep-resume and Smart Rewind actions, and startup recovery. | Apply `PlayerColor.accent` at the app scene boundary so sheets, full-screen covers, overlays, startup recovery, and the main hierarchy share one tint. Record only the screenshots whose pixels intentionally change, then rerun every story without recording. |

No missing action, clipped required control, dead route, contradictory status,
or inconsistent transfer value remains in the reviewed states.

## Intentional differences

| Approved concept | Shipped decision | Why it is intentional | Evidence |
| --- | --- | --- | --- |
| Fixed custom tab and card chrome | Native iOS navigation, controls, sheets, and Liquid Glass tab presentation carry the warm Player palette. | System interaction behavior, accessibility, and future OS compatibility take precedence over reproducing decorative chrome. Exact committed baselines still have zero spatial tolerance. | Stories 001–011 |
| Library mockup emphasizes Continue Listening and Recently Added | The shipped Library also exposes Up Next and Browse routes for All Books, Series, Authors, Narrators, Collections, and recoverable Trash. | These are required T14–T15 daily-library capabilities, not extra placeholders. | Story 008 |
| Review Import mockup uses a compact provenance card and separate order button | The shipped review shows the complete provenance/evidence list, an explicit warning count, pinned commit state, and direct Review Order route. | The denser hierarchy explains grouping and why commit is blocked without hiding source evidence. | Stories 002, 003, and 006 |
| Book Detail mockup uses compact horizontal actions and a short chapter list | The shipped detail uses large vertical actions, separate Chapters/Bookmarks content, undoable metadata repair, and recoverable removal. | The layout preserves minimum targets and Dynamic Type reflow while exposing all accepted MVP actions. | Stories 002, 004, 007, and 009 |
| Listening mockup includes a cast affordance and a dedicated chapter-list screen | Player relies on the system audio route for output; chapter navigation is available from transport controls and Book Detail. The player adds Smart Rewind, persistent sleep context, transport preferences, and direct bookmarking. | A custom cast destination and CarPlay are not MVP claims. The shipped controls correspond to implemented local playback behavior. | Stories 002, 005, 007, and 009 |
| Sleep timer mockup is a compact bottom sheet | The native sheet shows an active timer, replacement choices, custom duration, end-of-track/chapter boundaries, fade behavior, cancellation, and resume context. | The expanded state makes persistence and replacement semantics explicit. | Story 007 |
| iPhone receiver mockup shows a `.local` hostname and an inline library completion card | The shipped modal displays the reachable local IP URL, copy action, pairing code, Mirroring guidance, verified progress, safe paused/retry state, and a completion screen with Receive Another and Done. | A literal reachable address is more dependable than assuming local-hostname resolution; the modal keeps receiver ownership and repeated transfers explicit. | Stories 001 and 009 |
| Computer uploader mockup shows three idealized desktop frames | The responsive local page implements the same pair/select/send sequence and additionally exposes resumable confirmed offsets, retry, cancellation cleanup, sealed-import completion, and privacy copy. | Reliability states required by C01 are first-class product behavior rather than hidden error handling. | `ComputerReceiverTests`, receiver browser tests, and Story 001 native agreement states |
| Mockups use commercial-looking cover art and long-form durations | Canonical evidence uses committed synthetic artwork, tones, names, sizes, and clocks. | Tests, CI artifacts, and repository history must contain no private or copyrighted audiobook content. | Fixture verification and Stories 001–011 |
| Standard mockups fit each state in one viewport | AX5 evidence scrolls vertically and pins or preserves access to the primary action instead of shrinking text or adding horizontal scrolling. | Full Dynamic Type meaning and touch-target size are accessibility requirements. | Story 009 and `ACCESSIBILITY_AUDIT.md` |

## Final inventory

- Missing MVP features: none.
- Wrong or misleading status: none; imports, receiver progress, backup,
  recovery, and playback states are derived from durable production state.
- Clipped required accessibility actions: none; AX5 routes scroll vertically
  and provide non-drag alternatives.
- Dead actions or placeholder rows: none.
- Known product bugs in the compared scope: none after the scene-wide tint fix.
- Deferred integrations: Finder/Apple Devices Import Drop Box, Handoff trust,
  hosted relay or provider services, cloud sync, CarPlay, Watch, and other
  post-MVP integrations remain absent from the shipped UI.

The reviewed baseline update is limited to the scene-wide accent correction.
All eleven stories passed again without recording before this milestone was
committed for release verification.
