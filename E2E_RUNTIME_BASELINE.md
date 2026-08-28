# E2E runtime baseline

**Captured:** 2026-08-27  
**Purpose:** Establish the pre-R0 runtime baseline for the canonical E2E matrix  
**Branch:** `remediation/e2e-stabilization`  
**Current-main CI commit:** `6349b14f46ad1673a68eb60b8b24ba5207302acd`

**Local phase-profile commit:** `36b31cbd26d73f16318c7688539db58f0e0cf392`

## Result

The current-main CI workflow passed all 13 canonical E2E stories plus core
tests in **43m30s** wall clock. Its 14 macOS jobs consumed **2h54m22s** of
aggregate runner time and were admitted at an observed maximum of five
concurrent macOS jobs.

Before the App Store listing work reached `main`, all 12 then-current stories
and all 22 selected UI tests also passed on their first measured local attempt.
Running those shards sequentially took **29m09s** wall clock. The story
commands accounted for 29m07s; two seconds were wrapper overhead. That local
run supplies the detailed phase profile below, while the current-main CI run is
the authoritative complete-matrix wall-clock baseline.

These are before-R0 reference measurements, not yet runtime distributions. R0
qualification will produce repeated measurements and compare medians within
the same environment and command shape; local and GitHub-hosted measurements
must not be mixed into one delta.

## First parallel CI comparison

Commit `be102bec0daabdc064ed411c9c1610e866ba1349` ran the same 13 canonical
stories and core gate in five balanced macOS lanes with one shared compiled
test bundle per lane. The [green GitHub Actions run](https://github.com/anicolao/player/actions/runs/33139873579)
started at 03:46:26Z and completed at 04:09:04Z on 2026-08-28.

| Hosted CI measurement | Before | Parallel green run | Delta |
| --- | ---: | ---: | ---: |
| End-to-end workflow wall clock | 43m30s | 22m38s | -20m52s (-48.0%) |
| Canonical stories | 13 | 13 | unchanged |
| Core gate | included | included | unchanged |
| Maximum macOS lanes | 5 | 5 | unchanged |

This is the authoritative before/after result for the CI topology change, but
it is not yet the final R0 reliability distribution. The exact-SHA 10/10 story
and 5/5 matrix qualification must still pass before R0 is complete.

### Machine-readable qualification baseline

The qualification regression gate uses
`apps/ios/scripts/qualification/r0_runtime_baseline.json`, derived from the
retained evidence in run 33139873579. The checkout tested by the workflow was
merge commit `3a349369c4020aef8f5034e48ae1a45223df9796` on a `macos-26` runner
with Xcode 26.6 and iOS 26.5. Its production shared-build critical lane took
1,195 seconds, which is the comparable logical complete-matrix wall-clock
baseline; workflow setup and artifact upload are deliberately excluded.

The same evidence supplies one wall duration for each of the 13 stories and
aggregate story-phase totals. Core fixture verification, core tests, and the
production App Store renderer are recorded as additional phases. Qualification
uses the median of five complete logical matrices, fails above a 10% suite
regression or 20% per-story regression, and reports minimum/median/p95/maximum
plus per-phase before/after values.

## Current-main CI critical path

The successful [GitHub Actions run](https://github.com/anicolao/player/actions/runs/33124661556)
started at 23:00:08Z and completed at 23:43:38Z. Core tests and the 13 E2E
matrix jobs were eligible at once, but only five macOS jobs ran concurrently.
Later shards began as earlier jobs released those slots.

| CI measurement | Time |
| --- | ---: |
| End-to-end workflow wall clock | 43m30s |
| Aggregate macOS job time | 2h54m22s |
| Five-runner scheduling lower bound | 34m52s |
| Longest individual job, Story 005 | 18m22s |
| Story 007 | 15m08s |
| Story 008 | 14m23s |
| Story 013 | 13m23s |
| Core tests | 6m52s |

The final Story 013 job did not start until 30 minutes into the workflow, so
the current critical path is primarily five-runner wave scheduling rather than
one intrinsically 43-minute test. Purely balancing the existing jobs across
five lanes has a computed longest lane of about 37m16s. Removing repeated
per-job setup and build work can lower that further.

A typical shard spends about one minute installing Nix and another minute in
the pinned-environment step before project generation or E2E execution begins.
Every shard then generates the project once in the workflow and again inside
`run-e2e.sh`. More matrix entries without a larger runner allowance would add
this fixed cost and increase queue pressure.

## Local phase-profile environment and method

- macOS 26.5.2 (25F84), arm64
- Mac16,5; 16 logical CPUs; 128 GiB RAM
- Xcode 26.6 (17F113)
- iPhone 17 simulator with iOS 26.5 (23F77)
- `PLAYER_SKIP_SIMULATOR_LAUNCH=1`
- Each story used its selectors from `run-complete-suite.sh` and ran through
  `run-e2e.sh` with a new simulator and fresh story DerivedData.
- The 12 story commands ran sequentially, matching the work in the CI E2E
  matrix but not its parallel scheduling. Therefore 29m09s is total local
  suite work; the idealized CI critical path is the slowest shard, 5m14s,
  before checkout, Nix setup, duplicate project generation, artifact upload,
  and runner contention.
- The workstation was not isolated: a game was using about 63% of one CPU and
  a Nix builder VM was resident after the run. The observed post-run load
  averages were 16.77, 60.56, and 79.82. The exact absolute time consequently
  describes this development workstation under load; the per-phase and
  before/after comparison are the more useful signals.

The measured command shape was:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
PLAYER_SKIP_SIMULATOR_LAUNCH=1 \
apps/ios/scripts/run-e2e.sh <story> <canonical selectors...>
```

The twelve invocations were timed around the complete process. Xcode test
session durations and individual test durations were then read from each
retained `Story.xcresult`.

## Local per-story timing for Stories 001-012

| Story | Wall | Xcode test session | Outside test session | Share of story wall |
| --- | ---: | ---: | ---: | ---: |
| 001 iOS launch | 1m42s | 40.2s | 61.8s | 5.8% |
| 002 import and play | 2m11s | 75.8s | 55.2s | 7.5% |
| 003 multifile grouping | 1m31s | 30.5s | 60.5s | 5.2% |
| 004 metadata repair | 1m16s | 25.9s | 50.1s | 4.4% |
| 005 play and restore | 4m23s | 210.7s | 52.3s | 15.1% |
| 006 safe ZIP import | 2m16s | 78.7s | 57.3s | 7.8% |
| 007 sleep timer | 5m14s | 237.1s | 76.9s | 18.0% |
| 008 library search | 3m22s | 121.2s | 80.8s | 11.6% |
| 009 accessible core journeys | 2m28s | 71.6s | 76.4s | 8.5% |
| 010 library backup | 1m42s | 28.3s | 73.7s | 5.8% |
| 011 offline recovery | 1m37s | 15.6s | 81.4s | 5.6% |
| 012 monetization | 1m25s | 17.6s | 67.4s | 4.9% |
| **Story total** | **29m07s** | **15m53.4s** | **13m13.6s** | **100%** |

Stories 005, 007, and 008 account for 12m59s, or 44.6% of story wall
time. These are the first stories to profile when R0 changes test structure.

## Where the time goes

Xcode test sessions consume 54.6% of story wall time. The remaining 45.4% is
outside the recorded test sessions and is substantially repeated once per
story. Representative isolated measurements on the same workstation were:

| Phase | Representative time | Approximate 12-story cost | Notes |
| --- | ---: | ---: | --- |
| Xcode test sessions | actual 15m53.4s | 15m53.4s | From the twelve result bundles. |
| Simulator create, boot, and configure | 28.0s/story | 5m36s | Fresh iPhone 17, including deterministic UI/status-bar settings. |
| Fresh-DerivedData `build-for-testing` | 19.7s/story | 3m56s | Successful E2E build; system caches were already warm. |
| Receiver web build and Xcode project generation | 7.0s/story | 1m24s | `generate-project.sh` runs receiver `npm ci`, tests/check/build, then XcodeGen. |
| Screenshot pixel comparison | 4.65s/story | 55.8s | Cold invocation of the Swift comparison script. |
| Simulator shutdown and deletion | about 3.3s/story | about 39.6s | Exact simulator ID, clean teardown. |
| `.xcresult` attachment export | 0.09s/story | 1.1s | Measured on Story 007. |
| Walkthrough materialization | 0.03s/story | 0.4s | Measured on Story 007. |
| Remaining process/result overhead | about 3.4s/story | about 40.7s | Residual needed to reconcile the measured wall total. |

These microbenchmarks explain the measured total to within rounding. They are
diagnostic estimates rather than independent full-suite trials, so R0 should
instrument phases directly instead of treating every estimate as invariant.

The most expensive individual UI tests were:

| UI test | Duration |
| --- | ---: |
| Sleep timer | 2m33.0s |
| Library organization | 1m54.0s |
| Smart rewind main journey | 1m33.5s |
| Bookmark journey | 1m17.2s |
| Largest-text accessibility journey | 1m04.8s |

The top three tests consume 6m00.4s, or 41.1% of summed individual-test time.
The difference between the 14m37.0s summed test cases and the 15m53.4s Xcode
sessions is test-runner launch, setup, teardown, and inter-test overhead.

One diagnostic appeared repeatedly across otherwise successful process
launches:

```text
IDELaunchParametersSnapshot: The operation couldn’t be completed.
(DebuggerLLDB.DebuggerVersionStore.StoreError error 0.)
IDELaunchParametersSnapshot: no debugger version
```

R0 should classify that launch warning and determine whether it contributes to
startup cost or instability; its presence must not simply be labeled harmless
because this baseline happened to pass.

## R0 runtime contract

1. Add direct monotonic timing for environment verification, project/receiver
   generation, simulator lifecycle, build, test, result export, walkthrough
   materialization, comparison, and total shard wall time.
2. Preserve story isolation while removing duplicated work. In particular,
   assess whether local full-suite runs can share a compiled test bundle and
   whether receiver/project generation can occur once per checkout. CI
   currently generates the project in the workflow and again inside
   `run-e2e.sh`; measure and remove that duplication safely.
3. Design CI around the observed macOS concurrency allowance. With five slots,
   use balanced lanes or raise runner capacity before adding more jobs. Split
   the long tests in Stories 005 and 007 across lanes, and decompose Story 008
   only when its constituent journeys can retain independent setup, artifacts,
   and failure reporting.
4. Do not trade runtime for permissive waits. Product-state waits remain event
   driven and capped at two seconds.
5. After R0 qualifies at 10/10 per story and 5/5 complete matrices, repeat this
   measurement on a comparable machine and publish median, minimum, maximum,
   and p95 total and per-story times.
6. The median complete-suite runtime may not regress more than 10%, and an
   individual story may not regress more than 20%, unless added coverage is
   intentional, separately measured, and approved.
