# Import ingress and restart E2E contract

## Scope

This extends Story 002 through two real production ingress boundaries:

1. opening an audiobook document in Bookshelf, followed by process termination at
   deterministic acquisition and inspection checkpoints; and
2. consuming an atomic App Group handoff written by a Share Extension.

The E2E journey does not automate AirDrop discovery, a second Apple device, or
the system share sheet. Those surfaces are nondeterministic and do not change
the receiving extension/main-app durability contract. All checked-in media is
generated tone audio with no private or copyrighted content.

## Fixture corpus

`PlayerUITests/Fixtures/SyntheticImportChannels` is reproduced by
`generate-import-channel-fixtures.sh` from the checksum-verified
`SyntheticAudiobook` source:

| Fixture | Neutral fact | Use |
| --- | --- | --- |
| `document-open-interrupted-acquire.m4a` | 9,350 bytes, generated AAC tone | Actual document-open URL |
| `share-extension-handoff.m4a` | 9,183 bytes, generated AAC tone | Share payload |
| `share-extension-envelope.json` | Stable schema, UUID, size, and checksum | Atomic App Group envelope |
| `synthetic-import-channels-fixture.json` | Stable IDs and expected neutral facts | Human/tooling contract |

`SyntheticImportChannels.sha256` covers all four files. Tests pass bytes only
through the production document-open and App Group consumer boundaries; the
descriptor is not an importer result or metadata shortcut.

## Document-open restart journey

The first process launches with:

```text
-e2e -e2e-reset -e2e-fixture synthetic-import-channels
-e2e-import-channel document-open -e2e-import-pause acquire
```

`XCUIApplication.open(_:)` delivers the checked-in file URL through the app's
registered document-open handler. The handler must converge on the same import
coordinator used by the Files picker. Before acknowledging the source, the app
persists one import job and a durable source reference suitable for relaunch.
The `acquire` test gate pauses after that transaction and before copying bytes.
The gate is injected at the production boundary and is compiled only into E2E;
views and persistence never branch on a fixture filename.

The first process exposes:

```text
ingress:document:acquiring:job=70000000-0000-0000-0000-000000000001:jobs=1:staged=0:inspected=0:duplicates=0:source-unchanged=true
```

The test terminates the process without a completion callback. Relaunch omits
reset and uses `-e2e-import-pause inspect`. Startup recovery resumes the same
nonterminal job. The `inspect` gate pauses after the source copy, checksum, and
durable acquired-asset checkpoint, but before invoking the production audio
inspector:

```text
ingress:document:inspecting:job=70000000-0000-0000-0000-000000000001:jobs=1:staged=1:inspected=0:duplicates=0:source-unchanged=true
```

After a second process termination, relaunch again omits reset and pause. The
same job reaches one reviewable proposal:

```text
ingress:document:ready:job=70000000-0000-0000-0000-000000000001:jobs=1:staged=1:inspected=1:proposals=1:duplicates=0:source-unchanged=true
```

The `import-ingress-probe` accessibility element owns these exact values. Counts
come from the persisted production model and managed staging records, not from a
view-only counter. `source-unchanged` compares the opened source before first
acquisition and after the ready checkpoint. Recovery must be idempotent: it may
resume or safely repeat an incomplete copy/inspection, but cannot create a
second job, staged asset, inspection result, or proposal.

## Share Extension producer contract

The Share Extension and main app use the configured App Group container. For
each accepted item provider, the extension:

1. validates the complete provider selection before creating a handoff; a mixed
   selection with an unsupported filename is rejected rather than partially
   published;
2. requests an in-place representation first, falls back to a temporary file
   representation when unavailable, and preserves the provider's actionable
   error if neither representation can be acquired;
3. cancels the active provider `Progress` when the import task is cancelled and
   copies a provider-owned temporary URL synchronously before its callback
   returns;
4. creates `ImportHandoffs/Incoming/<handoff UUID>/Items/` without following
   symbolic links;
5. streams each valid representation into deterministic
   `Items/00000.<extension>` names while hashing;
6. accepts only the registered M4A, M4B, MP3, and ZIP content types, sanitizes
   the display filename, and preserves a safe filename extension;
7. synchronizes every item, then atomically writes `handoff.json` with
   `ShareImportHandoff { schemaVersion, id, createdAt, items }`;
8. atomically renames the completed request directory from `Incoming` to
   `Pending`, which is the only publication step; and
9. completes the extension request without deleting or mutating the provider's
   source.

Each `ShareImportHandoffItem` contains only `relativePath`, `originalFilename`,
`contentTypeIdentifier`, `byteCount`, and `checksumSHA256`. Fixture item paths
use `Items/00000.m4a`; absolute paths are forbidden. Logs and user-visible
errors must not include discovered metadata, artwork, source paths, or bytes.

The committed `stage-import-channel-fixture.sh share` command reproduces that
on-disk ordering for local diagnostics. It stages only into a new destination
and never claims to test the extension UI itself.

## Main-app handoff consumer contract

On activation, the production consumer scans `ImportHandoffs/Processing` first
to recover an orphaned claim, then `ImportHandoffs/Pending`. It never consumes
an `Incoming` request. It validates the schema, confines every item beneath its
request directory, and verifies its declared size and checksum. Claiming
atomically renames the request from `Pending` to `Processing`. The claimed item
URLs then enter the same durable import coordinator as document-open and Files
picker acquisition.

After durable staging, the app records a receipt keyed by both handoff UUID and
payload checksum, then removes only its claimed App Group directory. The receipt
and import-job transaction must make at-least-once delivery idempotent. A replay
of the identical completed handoff removes the replay but does not create a new
job or stage/inspect the payload again. A UUID collision with different bytes is
rejected rather than deduplicated.

E2E launches use:

```text
-e2e -e2e-reset -e2e-fixture synthetic-import-channels
-e2e-import-channel share-extension
-e2e-stage-share-handoff 70000000-0000-0000-0000-000000000101
```

`PLAYER_E2E_SHARE_PAYLOAD_BASE64` and `PLAYER_E2E_SHARE_ENVELOPE_BASE64` contain
only the small checked-in synthetic files. The E2E bootstrap writes a completed
handoff inside the isolated App Group test root, then invokes the production
consumer. It must not directly create an `ImportJob` or proposal.

`share-handoff-probe` first reports:

```text
handoff:share-extension:consumed:id=70000000-0000-0000-0000-000000000101:job=70000000-0000-0000-0000-000000000102:jobs=1:staged=1:proposals=1:receipt=recorded:pending=0:processing=0:source-unchanged=true
```

The test terminates, stages the same handoff again without reset, and requires:

```text
handoff:share-extension:deduplicated:id=70000000-0000-0000-0000-000000000101:job=70000000-0000-0000-0000-000000000102:jobs=1:staged=1:proposals=1:receipt=retained:pending=0:processing=0:source-unchanged=true
```

## Visual evidence

This extension records no new screenshots. Its user-visible ready state is the
same Review Import surface already covered by `000-review-import.png`; the new
risk is crash consistency and cross-process handoff state, which is asserted
programmatically. Existing screenshot baselines remain unchanged.
