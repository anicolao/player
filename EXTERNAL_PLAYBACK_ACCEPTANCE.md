# External playback acceptance

Status: automated adapter and durable-state coverage implemented; physical-device
acceptance pending.

This matrix qualifies the system surfaces that cannot be represented faithfully
by Simulator: Lock Screen, Control Center, headset buttons, Bluetooth metadata,
and vehicle receivers. Simulator tests prove Bookshelf's command mapping,
metadata dictionary, artwork renderer, and durable position behavior. They do
not prove that iOS or a particular accessory displays or sends those values.

No row may be marked Passed from source review, unit tests, Simulator E2E, or a
different build. A named tester must exercise the release candidate on physical
hardware, attach evidence, and a second person must review the record.

## Automated boundary

| Contract | Deterministic evidence |
| --- | --- |
| Now Playing metadata | `PlayerCoreTests/testRealNowPlayingPublisherTransfersCompleteMetadataAndSquareArtwork` verifies title, author, series/album, audiobook media type, duration, elapsed time, active/default rate, chapter number/count, legacy track number/count, stable content ID, and playback state through the production `MPNowPlayingInfoCenter` publisher. |
| Square artwork | The same test begins with a rectangular 1600×800 source and verifies a square, center-cropped 1024×1024 bound plus a square receiver-requested bitmap. Invalid artwork remains omitted. |
| Remote commands | `TransportPreferencesTests` verifies every production `MPRemoteCommandCenter` registration, configured forward/back intervals, previous/next headset mapping, scrub, supported rates, and rejection of malformed values. Multi-asset integration verifies the resulting durable book position. |
| Interruptions and route loss | `PlayerCoreTests` verifies exact durable checkpoints, interruption resume without Smart Rewind, nested interruptions, route-loss pause, and cancellation of pending resume when the old route disappears. `RemoteInterruptionUITests` drives the production adapters with event-driven probes and proves the state survives relaunch. |
| Live metadata position | Playback engine progress tests verify elapsed time, chapter, status, and rate update without adding false durable journal events; pause, seek, background, interruption, and route loss do create the appropriate durable boundary. |

## Required physical-device matrix

Use one release-candidate/TestFlight build for the complete pass. Use an M4B
with embedded chapters and square artwork for metadata-focused rows and a
multi-file MP3 book for cross-track skip rows. Configure non-default intervals
so a fallback to 15/30 seconds is visible.

`N/A` is acceptable only when the system surface has no display or control for
that field. Record it explicitly; do not turn an unobserved field into a pass.

| ID | Surface / route | Required observations | Status |
| --- | --- | --- | --- |
| EP-01 | Lock Screen | Book title, author, series/album, chapter index/title if iOS renders it, square cover, duration, elapsed time, rate, play/pause, configured back/forward, scrub, and chapter/position updates. Pause and relaunch must restore the scrubbed position. | Pending |
| EP-02 | Control Center | The same applicable metadata and artwork as EP-01; play/pause, configured skips, scrub, and rate changes agree with in-app controls and become durable. | Pending |
| EP-03 | Wired headset or wired remote | Play/pause and previous/next buttons use the current book's configured back/forward intervals. Unplugging while playing pauses once at the exact position and does not continue on the speaker. Display-only fields are `N/A`. | Pending |
| EP-04 | AirPods or Bluetooth headset | Play/pause and previous/next use configured intervals, including a skip across an MP3 asset boundary. Removing/disconnecting the active route pauses once and does not auto-resume on the speaker. Record the AirPods model and firmware when applicable. | Pending |
| EP-05 | Bluetooth receiver with a metadata display | Applicable title, author, series/album, chapter/track number, elapsed/duration, and square artwork appear; play/pause and skip buttons match Bookshelf semantics. Record unsupported receiver fields as `N/A`. | Pending |
| EP-06 | Reported car path (Tesla preferred) | Over the actual connection used by the listener, title, author, series/album, chapter/track number, duration/elapsed, and square artwork appear where supported. Steering-wheel/display previous and next use configured intervals rather than whole tracks. Scrub and rate are checked if exposed. Disconnect pauses without position drift. | Pending |
| EP-07 | Interruption while using speaker, headset, and car routes | An incoming-call or equivalent real interruption pauses at the observed position. Declining/ending it follows the system's resume decision without Smart Rewind or position drift. Disconnecting the route during interruption prevents resume onto the speaker. | Pending |

## Evidence record

Create one record per row. The reviewer compares the attached screen recording,
screenshots, or receiver photos with the written observations before signing.

```text
ID:
TestFlight build / app version:
iPhone model / iOS version:
Accessory or vehicle / firmware or software version:
Connection type: wired | Bluetooth | vehicle Bluetooth | USB | other
Book format and structure: M4B chapters | multi-file MP3 | other
Configured rate / backward skip / forward skip:
Book title / author / series or album / chapter used:
UTC start and completion timestamps:
Applicable metadata result:
Artwork result (shape, presence, refresh after chapter/track change):
Play/pause result:
Backward/forward result with before/after positions:
Scrub result with requested/restored positions:
Rate result:
Interruption result:
Route-loss result:
Overall result: Passed | Failed
Evidence path or link:
Tester name:
Reviewer name / review timestamp:
Notes and N/A rationale:
```

A failure reopens R15. Add a deterministic regression test when the failure is
inside Bookshelf, ship a corrected candidate, and repeat the failed row plus any
row sharing the affected adapter. Device-specific unsupported fields may be
`N/A`; incorrect values, missing artwork on a capable receiver, position drift,
or unsafe speaker resume are failures.

## Explicit post-MVP scope

Apple Watch Now Playing is post-MVP. Passive system behavior may be noted during
EP-01–EP-07, but it is not a release gate and this matrix does not claim Watch
support. A future Watch scope needs its own device matrix for command delivery,
metadata/artwork, connectivity transitions, and—if standalone playback is ever
added—watch-local downloads and durable position reconciliation.
