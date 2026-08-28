# System ingress acceptance

Status: automated transaction coverage complete; physical-device provider
acceptance pending because the registered iPhone was offline on 2026-08-28.

This matrix separates behavior the repository proves deterministically from
behavior that only Apple's real picker, cloud-provider, and Share Extension
processes can prove. A Simulator or injected provider result is not recorded as
physical-device evidence.

## Automated evidence

| Entry point | Proven behavior | Evidence |
| --- | --- | --- |
| Files import | Single file, multiple files, folder, and ZIP selections enter the same durable coordinator; cancellation and provider failure create no job; mixed archive selections fail atomically; security scope is balanced; restart bookmarks resume or fail without abandoned staging. | `SystemIngressTests` (19/19), including production adapter, acquisition, cancellation, failure, and restart cases. |
| Cover from Photos | Cancellation and provider failure preserve the cover and unrelated draft fields; a successful image is decoded, safety-checked, cropped, committed, survives relaunch, and can be undone. | `SystemIngressTests` plus canonical Story 004 `MetadataRepairUITests` (2/2, four reviewed screenshots exact). |
| Cover from Files | Cancellation and offline-provider failure preserve the draft; security scope is balanced; the actual image type is validated instead of trusting the filename. | `SystemIngressTests` and the Files failure path in canonical Story 004. |
| Share Extension provider | The complete selection is validated as one transaction; in-place acquisition falls back to a temporary representation; the provider's real failure is retained; temporary bytes are copied before the callback returns; task cancellation cancels `Progress`; display names are sanitized. | `ShareProviderImportCoordinatorTests` (5/5) and the complete `PlayerTests` suite (343/343). |
| Share handoff consumption | A published App Group handoff is claimed, validated, durably imported into Inbox, receipted, removed, and deduplicated on replay without changing its source. | Canonical Story 002 `ImportIngressResilienceUITests/testConsumesAndDeduplicatesShareExtensionAppGroupHandoff`. |

The durable producer/consumer ordering and exact semantic probes are specified
in `tests/e2e/002-import-and-play/INGRESS_CONTRACT.md`. Deterministic E2E
injection begins at the provider-result boundary; it does not claim to automate
Apple's picker UI, iCloud download, limited Photos authorization, or extension
host presentation.

## Required physical-device matrix

Record the TestFlight build number, iOS version, provider, UTC timestamp,
result, and a screen recording or screenshot for each row. Retain evidence
under the launch acceptance archive and link it from this document before
changing `Pending` to `Passed`.

| ID | Device route | Acceptance | Status |
| --- | --- | --- | --- |
| SI-01 | Files → On My iPhone, one M4B | Selecting the file creates one visible Inbox issue or one reviewable import; completing it produces one playable book. Cancelling the picker creates nothing. | Pending |
| SI-02 | Files → On My iPhone, multiple MP3s | One selection produces one review transaction with every chosen track and no duplicate job. | Pending |
| SI-03 | Files → local folder | A folder of ordered MP3s reaches review with its folder identity and all tracks intact. | Pending |
| SI-04 | Files → local ZIP | A supported ZIP reaches review; a ZIP mixed with a sibling audio item is rejected without a partial job. | Pending |
| SI-05 | Files → iCloud Drive, item initially not downloaded | Bookshelf either waits for a provider result or presents an actionable Files-owned failure; retry after download succeeds, and cancellation leaves no partial job. | Pending |
| SI-06 | Metadata → Change Cover → Choose Photo with full access | A selected local photo reaches Crop, applies, saves, survives relaunch, and Undo restores the prior cover. | Pending |
| SI-07 | Metadata → Change Cover → Choose Photo with limited access | The limited-library flow can grant/select an allowed photo; denial or cancellation leaves the entire draft unchanged and presents no false success. | Pending |
| SI-08 | Metadata → Change Cover → iCloud-only photo | An unavailable photo produces actionable Photos guidance without losing the draft; after download, retry succeeds. | Pending |
| SI-09 | Metadata → Change Cover → Choose File, local and cloud-backed image | Local selection succeeds; an offline cloud image fails actionably; cancellation and failure preserve the cover and unrelated edits. | Pending |
| SI-10 | Files share sheet → Bookshelf, one supported audiobook | The extension visibly progresses, reports success, closes, and the main app consumes exactly one durable Inbox import. | Pending |
| SI-11 | Files share sheet → Bookshelf, multiple supported audiobooks | Progress identifies the current file, the extension publishes only after every copy finishes, and Inbox receives the complete selection once. | Pending |
| SI-12 | Share sheet with supported and unsupported siblings | The extension shows an actionable failure, publishes no handoff, and Inbox remains unchanged. | Pending |
| SI-13 | Share sheet → iCloud-backed item, then cancellation | Provider failure text remains actionable; dismissing/cancelling leaves neither `Incoming` nor `Pending` residue and a later retry succeeds. | Pending |
| SI-14 | Relaunch after interrupted Files/share ingress | A completed published handoff resumes exactly once; an incomplete provider request is cleaned without an Inbox ghost or source mutation. | Pending |

## Evidence record template

```text
ID:
TestFlight build:
Device / iOS:
Provider and source state:
UTC timestamp:
Result: Passed | Failed
Observed job / Inbox / library result:
Cancellation or cleanup result:
Evidence path or link:
Notes:
```

No row may be marked passed from a unit test, Simulator run, source inspection,
or an earlier build. Any failed row reopens R8 and must receive a focused
regression test before the corrected build is retested on device.
