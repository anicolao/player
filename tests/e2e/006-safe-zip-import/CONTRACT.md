# Safe ZIP import E2E contract

## Fixture corpus

`PlayerUITests/Fixtures/SyntheticZIPs` contains only generated legal data:

| Case | Archive fact | Expected rejection |
| --- | --- | --- |
| `valid` | Two playable synthetic M4As in one safe relative directory | None |
| `traversal` | Relative parent traversal and absolute-path entries | `path-traversal` (`unsafePath`) |
| `symlink` | Genuine Unix symlink whose target escapes its directory | `symlink` (`linkEntry`) |
| `ratio` | 65,536 zero bytes compressed well beyond 20:1 | `compression-ratio` (`expansionRatio`) |
| `count` | 33 entries when the E2E limit is 32 | `entry-count` (`tooManyEntries`) |
| `size` | One 131,073-byte entry when the limit is 131,072 | `entry-size` (`entryTooLarge`) |

The archives are structurally valid ZIPs, including valid CRCs and central
directories. Hostility is semantic, not file corruption. The symlink uses Unix
mode `0120777`. Generation uses fixed DOS timestamps and strips ZIP extras.
`SyntheticZIPs.sha256` also covers the globally unique
`synthetic-zips-fixture.json` limit map.

## Bootstrap and production boundaries

Each process launches with:

```text
-e2e -e2e-reset -e2e-fixture safe-zip-import
-e2e-zip-case <valid|traversal|symlink|ratio|count|size>
-e2e-zip-limits 32,131072,20
```

Tapping production `add-audiobook` asks the injected document-acquisition source
for the selected checked-in ZIP URL and calls the normal multi-selection import
boundary. The selected source checksum is recorded before acquisition and checked
after every terminal or retry state.

The limit argument configures the same archive-policy dependency as production;
it does not change view logic. The extractor must validate every central-directory
entry's normalized path, type, declared sizes, count, and expansion ratio before
writing the first entry. Extraction is confined to a newly created job directory.
An injected filesystem observer counts attempted successful writes outside that
directory. It observes the production file operations and never simulates success.

For valid only, `-e2e-zip-fail-once inspection` injects one recoverable failure at
the audio-inspector boundary after safe extraction. It is consumed once. Retry
re-enters the production checkpoint/retry path and must not duplicate extracted
files, jobs, or proposals.

All cases use job ID `60000000-0000-0000-0000-000000000001` and open errors with
`view-import-error-<job UUID>`.

## Safety probe

The read-only `zip-safety-probe` exposes one exact value:

```text
zip:<case>:<rejected|failed|ready|cancelled>:<reason-and-neutral-counts>:source-unchanged=true:outside-writes=0
```

Rejected values are:

```text
zip:traversal:rejected:path-traversal:entries=3:extracted=0:source-unchanged=true:outside-writes=0
zip:symlink:rejected:symlink:entries=2:extracted=0:source-unchanged=true:outside-writes=0
zip:ratio:rejected:compression-ratio:entries=1:extracted=0:source-unchanged=true:outside-writes=0
zip:count:rejected:entry-count:entries=33:extracted=0:source-unchanged=true:outside-writes=0
zip:size:rejected:entry-size:entries=1:extracted=0:source-unchanged=true:outside-writes=0
```

Cancelling any rejection deletes only the job's acquired/extraction staging and
reports `zip:<case>:cancelled:extracted=0:staging=0:source-unchanged=true:outside-writes=0`.

The valid transient and successful values are:

```text
zip:valid:failed:inspection-transient:entries=2:extracted=2:source-unchanged=true:outside-writes=0
zip:valid:ready:entries=2:extracted=2:books=1:source-unchanged=true:outside-writes=0
```

## Recovery UI

`import-error-screen` uses:

- `zip-error:<unsafe-reason>:terminal:change-selection` for policy rejection;
- `zip-error:inspection-transient:recoverable:retry` for the injected temporary
  inspector failure.

Action identifiers are `change-import-selection`, `cancel-import`, and
`retry-import`. Unsafe unchanged archives do not offer Retry. The valid transient
offers Retry and Cancel. After retry, `review-import-job-<job UUID>` opens
`review-import-screen` with `proposal:ready:1-book:2-tracks:0-warnings`.

“Terminal” describes retryability of that unchanged archive, not the overall
import journey: choosing a different source is still an actionable recovery.
The UI-facing neutral reasons above deliberately map the production extractor's
error codes without exposing the offending archive path or private metadata.

The two screenshots cover the only materially distinct visual states: actionable
safe rejection and successful recovery. Symlink and limit variants are asserted
programmatically to avoid redundant baselines.
