# E2E runtime baseline

**Captured:** 2026-08-27  
**Purpose:** Record the pre-remediation baseline, initial parallel result, expanded-suite reference, and final qualification comparison
**Branch:** `remediation/e2e-stabilization`  
**Pre-remediation CI commit:** `6349b14f46ad1673a68eb60b8b24ba5207302acd`

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

This is the authoritative same-coverage before/after result for the initial CI
topology change: both measurements selected the then-current 26 UI-test
selectors. It is not the final R0 reliability distribution. R1-R16 expanded
the suite to 41 selectors, so the exact-SHA 10/10 story and 5/5 matrix
qualification must use the expanded-suite comparison below.

### Machine-readable qualification baseline

The qualification regression gate uses the schema-v2
`apps/ios/scripts/qualification/r0_runtime_baseline.json`. Its
`preRemediation` record retains run 33139873579 and its 1,195-second logical
critical lane. Its `qualificationReference` retains the final expanded
41-selector coverage plus an explicit R1-R16 coverage adjustment. Formal
qualification compares five logical matrices with that expanded reference,
fails above a 10% suite regression or 20% per-story regression, and reports
minimum/median/p95/maximum plus per-phase before/after values. Workflow setup
and artifact upload remain visible in workflow wall time but are excluded from
the logical critical-lane threshold.

## Expanded remediation-suite comparison

R1-R16 intentionally increased canonical coverage from 26 to 41 selectors.
Run [33265457941](https://github.com/anicolao/player/actions/runs/33265457941)
is the original expanded-suite reference: it completed in **40m56s**, with a
**2,258-second** logical critical lane. The same 41-selector suite passed on the
final allocation and exact accepted implementation in
[run 33289300337](https://github.com/anicolao/player/actions/runs/33289300337)
without a rerun.

| Expanded-suite measurement | Reference allocation | Final exact-SHA run | Delta |
| --- | ---: | ---: | ---: |
| Workflow wall clock | 40m56s | 32m32s | -8m24s (-20.5%) |
| Logical critical lane | 2,258s | 1,782s | -476s (-21.1%) |
| Canonical stories | 13 | 13 | unchanged |
| UI-test selectors | 41 | 41 | unchanged |
| Core gate / App Store renderer | included | included | unchanged |

The final run passed all 13 stories, all 41 UI-test selectors, 372/372 core
tests, and the seven-image App Store renderer in one attempt. Relative to the
43m30s pre-parallel workflow, wall time is lower by 10m58s (-25.2%) even though
R1-R16 expanded UI coverage from 26 to 41 selectors. The formal repeated
distribution remains the release-qualification gate; a failed run is never
substituted with a rerun-to-green.

The exact story artifacts also retain the aggregate runner work below. These
phase totals are summed across five concurrent lanes, so they explain where
runner time went but must not be added to obtain workflow wall time.

The final control-plane correction was validated without a rerun by
[run 33333159502](https://github.com/anicolao/player/actions/runs/33333159502):
all five lanes passed, with a 1,697-second logical critical lane. The workflow
was created while superseded jobs still occupied the hosted pool, so its 36m26s
created-to-complete wall clock includes roughly four minutes of visible queue
contention. From first runner admission to the final shard completion was
32m51s, and the logical critical lane improved by 85 seconds (-4.8%) versus the
1,782-second accepted scheduling run. This validates the correction but does
not replace the clean 32m32s no-queue measurement above.

| Retained phase | Expanded reference | Final exact-SHA run | Delta |
| --- | ---: | ---: | ---: |
| Simulator create/boot/configure | 1,843s | 1,671s | -172s |
| Five shared builds | 1,182s | 1,009s | -173s |
| Build provenance | 213s | 184s | -29s |
| Target installation | 268s | 292s | +24s |
| UI test execution | 3,773s | 3,755s | -18s |
| Attachment export | 34s | 33s | -1s |
| Screenshot comparison | 385s | 337s | -48s |
| Walkthrough materialization / README comparison | 4s | 4s | unchanged |
| Core fixtures | 20s | 108s | +88s |
| Core tests | 221s | 100s | -121s |
| App Store renderer | 10s | 11s | +1s |

The five shared builds and simulator provisioning remain the largest setup
costs. The critical-path improvement comes from balancing complete stories
across the five-runner concurrency ceiling and reusing one immutable build per
lane, not from deleting tests or hiding setup outside the measurement.

The repaired predecessor also passed without a rerun in
[run 33278492881](https://github.com/anicolao/player/actions/runs/33278492881):
all 13 stories, all 41 UI-test selectors, 371/371 core tests, and the renderer
completed in **33m31s** workflow wall time. That run proves the fixes before
the final scheduling-only change; it is not substituted for the candidate's
own required green timing.

### Robust final lane allocation

The final candidate allocation was selected from the corrected per-story phase
timings in expanded-suite runs 33265457941, 33269183195, 33270906517, and
33272797452, rather than fitting one unusually fast run. Every allocation keeps
all 13 stories exactly once, one core gate, and the App Store renderer in the
listing lane. Across those four samples, the selected allocation reduces the
estimated critical compute lane from 1,549s to 1,428s by mean (-7.9%), from
1,621s to 1,395s by median (-14.0%), and from 1,736s to 1,616s in the worst
observed sample (-6.9%). Including each physical lane's observed cold-build
cost lowers the estimated median critical path by 239s (-13.0%).

| Lane | Canonical work |
| --- | --- |
| 1 | 004 metadata repair; 012 monetization; core and fixture gates |
| 2 | 005 play and restore; 011 offline recovery; 003 multifile grouping |
| 3 | 007 sleep timer; 008 library search |
| 4 | 001 iOS launch; 002 import and play; 010 library backup |
| 5 | 006 safe ZIP import; 009 accessible core journeys; 013 App Store listing and renderer |

This is a scheduling-only change. It does not remove a selector, weaken a
gate, add a test retry, or change the two-second event deadline. The measured
32m32s workflow and 1,782-second logical critical lane above are the actual
before/after result; the allocation model is retained only to document how the
layout was selected.

## Pre-remediation CI critical path

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

A typical shard spent about one minute installing Nix and another minute in the
pinned-environment step before project generation or E2E execution began.
The current workflow generates the project once per lane and reuses one
compiled test bundle across that lane. More matrix entries without a larger
runner allowance would still add fixed setup cost and increase queue pressure.

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
diagnostic estimates rather than independent full-suite trials. Direct
monotonic phase timing is now implemented, so qualification evidence does not
treat these estimates as invariant.

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

The following evidence-based classification determines whether that warning
contributes to startup cost or instability; its presence is not treated as a
waiver merely because the baseline passed.

### Xcode launcher diagnostic classification

Retained green evidence in Stories 005, 007, 008, 009, and 012 contains exactly
43 `Launch com.spnss.player` events and 43 matching
`IDELaunchParametersSnapshot … no debugger version` warning pairs. All 11 test
cases in those retained runs passed. The warning is emitted by host
`xcodebuild[...][MT]` immediately after each `XCUIApplication` launch and before
automation setup; it is not emitted by Bookshelf.

The audited evidence is each story's `Run.json` and `Logs/test.log` beneath
`apps/ios/DerivedData/E2E/`: Story 005 at `10f53e21301c`, Story 007 at
`18ba2730969b`, Story 008 at `918b2d9f1dde`, Story 009 at `0939fbaad3be`, and
Story 012 at `a92994d11d9e`. These paths identify the locally retained inputs to
the classification; the warning remains present in uploaded CI test logs.

The warning is therefore classified as a deterministic Xcode 26.6 UI-test
launcher metadata diagnostic: the optional LLDB debugger-version snapshot is
unavailable during the test launch. It has no observed association with
instability across the 43 successful launches and no separately measurable
stall. Its constant cost is already included in both the baseline and candidate
timings. It remains visible in retained logs for diagnosis, but an application
or test failure must never be waived under this warning's signature.

The same retained runs emit one iOS 26.5
`UIAccessibilityLoaderWebShared` duplicate-bundle warning per test-runner
session. That warning is also emitted by the Apple Simulator runtime rather
than Bookshelf; it remains retained as a distinct platform diagnostic and is
not evidence that an application failure shares this launcher's cause.

## R0 runtime contract

Implemented:

1. Every shard records direct monotonic timing for environment reuse,
   project/receiver generation, simulator lifecycle, build and build reuse,
   target installation, test execution, result export, walkthrough
   materialization, comparison, and total wall time.
2. Story isolation is preserved while each lane reuses one generated project
   and compiled test bundle. Every story still owns a fresh simulator,
   persistence namespace, result bundle, diagnostics, and artifact manifest.
3. Normal CI and the five-matrix qualification stage use five measured,
   coverage-preserving lanes. The ten-attempt story stage exposes each of the
   13 canonical stories as an independently scheduled job, so GitHub can keep
   every available macOS slot occupied without coupling a short story to the
   tail of a longer static bundle. Coverage remains 130 isolated story attempts.
4. Product-state waits remain event driven and capped at two seconds; runtime
   was not traded for permissive waits or retry-to-green.
5. Schema-v2 evidence retains exact CI provenance, all 13 story times, the
   complete phase set, core tests, and App Store rendering. Aggregation fails
   closed on missing, malformed, duplicated, or unattributed evidence.

Pending:

1. On the final exact SHA, require 10/10 for every canonical story and 5/5
   complete logical matrices.
2. Publish that run's median, minimum, maximum, p95, per-story, and per-phase
   distribution against the expanded-suite reference.
3. Require the median complete-suite runtime to remain within 10% and each
   individual story within 20%, except for an explicit, measured, approved
   coverage adjustment.
