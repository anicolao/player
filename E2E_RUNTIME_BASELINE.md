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

Two later exact-code timing checks also passed without reruns while R0 failure
qualification continued. [Run 33357450846](https://github.com/anicolao/player/actions/runs/33357450846)
completed in **39m06s**, and
[run 33359695859](https://github.com/anicolao/player/actions/runs/33359695859)
completed in **40m31s**. Each retained all five lanes, 13 stories, 41 UI-test
selectors, core and fixture gates, and the App Store renderer. The latest run
is 25 seconds faster than the original 40m56s expanded-suite reference and
2m59s faster than the 43m30s pre-parallel workflow despite the increase from
26 to 41 UI selectors. These single runs corroborate the no-regression result;
they do not replace the required repeated formal distribution.

### Fresh-host scheduling comparison baseline

[Run 33421395062](https://github.com/anicolao/player/actions/runs/33421395062)
is the coverage-preserving baseline immediately before deterministic five-chain
scheduling. It passed on commit
`0e52d834427fe9f7ce6ff036ec7af375d7b13e67` without a rerun: all 13 canonical
stories, all 41 UI-test selectors, 372/372 core tests, fixture gates, and the
App Store renderer passed. The workflow was created at 17:46:36Z, its producer
was admitted at 17:48:18Z while its predecessor released the hosted pool, and
the aggregate gate completed at 18:34:52Z. Therefore its exact
created-to-complete wall clock was **48m16s**, including **1m42s** of visible
admission queue, and its first-admission-to-green time was **46m34s**.

The producer and 14 fresh macOS consumers accumulated **2h51m25s** of runner
time; the consumers alone accumulated **2h38m54s**. All 14 consumers became
eligible together after the producer, but GitHub admitted at most five. Their
arbitrary admission order left a 14m46s Story 011 job at the tail even though
shorter work had run earlier. Scheduling alone can remove that avoidable tail
without sharing hosts or changing selection. The measured two-run mean yields
five chains within 12.5 seconds of the ideal average lower bound:

| Chain | Fresh-host work | Estimated mean |
| --- | --- | ---: |
| 1 | 005 play and restore; 004 metadata repair | 32m06.5s |
| 2 | 009 accessible core journeys; 011 offline recovery; core/fixtures | 32m22.0s |
| 3 | 007 sleep timer; 013 App Store listing; 003 multifile grouping | 32m12.5s |
| 4 | 008 library search; 010 library backup; 012 monetization | 32m31.5s |
| 5 | 006 safe ZIP import; 001 iOS launch; 002 import and play | 32m22.5s |

Each item remains a separate reusable-workflow call and therefore receives a
fresh hosted machine. Dependencies only determine admission order. A failed
story does not suppress later coverage in its chain; the final aggregate gate
still requires every story and core result to succeed. The accepted after
measurement must come from a complete green CI run of this scheduler, without
rerunning a failed attempt.

The first scheduler execution,
[run 33426513529](https://github.com/anicolao/player/actions/runs/33426513529),
proved that fail-open successor admission preserved all coverage, but it is not
an accepted after sample because Stories 004 and 011 failed before product UI
on two distinct asynchronous LaunchServices registration races. It completed
in **49m29s** created-to-complete. The run was not rerun; its exact evidence and
repairs are retained in the R0 failure ledger, and the repaired scheduler must
produce a complete green sample for the before/after comparison.

The next scheduler execution,
[run 33432987841](https://github.com/anicolao/player/actions/runs/33432987841),
also preserved every successor and attained the account's five-runner
concurrency ceiling. It ran from 19:53:08Z through 20:42:59Z for **49m51s**
created-to-complete; the producer passed in **10m05s**, all 13 stories ran, and
the complete core/fixture gate passed. Stories 004 and 011 reached product UI,
proving both prior registration repairs. The run is still not an accepted
after sample: Story 011 exposed a redundant recovery-backup scan before support
export, and Story 003 exposed unrelated automatic-backup churn on its
two-second acquisition receipt while its fresh host was severely I/O
constrained. The run was not rerun. Both distinct signatures, retained
artifacts, fixes, and complete local canonical validations are recorded in the
R0 failure ledger; the accepted after measurement still requires the next
complete green execution.

The accepted scheduler execution is
[run 33439248042](https://github.com/anicolao/player/actions/runs/33439248042)
at exact commit `daa062ace6118c5fbc127fe0a8af999488e81896`. It passed without
a rerun from 21:02:34Z through 21:50:49Z: **48m15s**
created-to-complete, one second faster than the 48m16s baseline and therefore
effectively flat. Coverage did not decrease: all 13 canonical stories, all 41
UI selectors, 374/374 core tests, fixture gates, exact walkthroughs, and the
App Store renderer passed. Producer plus consumers used **2h47m23s**, 4m02s
less runner time than the baseline's 2h51m25s.

The five chains saturated the account's five-macOS-runner limit and eliminated
the arbitrary tail admission. The observed critical chain was Story 008,
Story 010, then Story 012. Story 008 took 19m01s in this sample, versus the
14m46s late Story 011 that dominated the unscheduled baseline; that fresh-host
variance consumed the scheduling model's expected wall-clock gain. The result
is still the accepted coverage-preserving before/after measurement: maximal
available parallelism reduced aggregate runner work, did not regress wall
clock, and did not trade coverage or deadlines for speed.

The exact-tip candidate rebalanced those same fresh-host jobs from the observed
durations in run 33479649229. It kept all 13 stories, all 41 selectors,
core/fixture gates, and renderer work, while changing only dependency order.
The measured-input model predicted a longest-chain reduction from **2,233s** to
**1,895s** (-338s, or **5m38s**) and a five-chain spread reduction from **703s**
to **28s**.

[Run 33484894430](https://github.com/anicolao/player/actions/runs/33484894430)
is the complete green hosted result at exact commit
`3f129726c01a825455058b6a23f4e0090d4b0bcc`. It passed without a rerun: all 13
stories, all 41 UI selectors, 375/375 core tests, fixture gates, reviewed
walkthroughs, and the App Store renderer were green. Created-to-complete wall
clock was **50m14s**, versus **48m16s** for the unscheduled fresh-host baseline:
**+1m58s (+4.1%)**. The consumer stage ran from 08:14:23Z through 08:50:56Z,
or **36m33s**, versus the baseline's 35m34s: **+59s (+2.8%)**. Against the
previously accepted scheduler run's 37m22s consumer span, the rebalance saved
**49s (-2.2%)**.

The candidate occupied all five available macOS slots through every dependency
transition. Its one-time producer took **13m27s**, versus 10m51s in the
unscheduled baseline and 10m39s in the prior accepted scheduler run. That
**+2m36s** baseline producer variance is larger than the overall **+1m58s**
workflow delta, so the consumer graph recovered 38 seconds of it while also
paying the clean-boot reliability cost. The measured result replaces the model:
parallelism is maximal and coverage is unchanged or increased, but this sample
does not show a wall-clock speedup over the unscheduled baseline. Its 4.1%
increase remains inside the R0 10% complete-suite runtime contract.

The same candidate adds a clean reboot after each fresh simulator's initial
boot and exact UI configuration. On the local iOS 26.5 host, Story 009's first
boot completed in 16 seconds, its second boot in 2 seconds, and its whole
simulator phase in 25 seconds—about nine seconds above the prior one-boot local
phase. That bounded lifecycle cost replaced observed hosted launch queues of
roughly 34 seconds in Story 009 and 60 seconds for Story 002's document URL.
It is part of the candidate wall-clock measurement and is not excluded as setup
or offset by weaker waits.

### Latest exact-code validation and retained variance

[Run 33508118349](https://github.com/anicolao/player/actions/runs/33508118349)
passed the complete normal matrix on exact code SHA
`1151132f025e77649d5f69d09af64389a407439e` without a rerun: all 13 stories,
all 41 UI selectors, 377/377 core tests, fixture gates, reviewed screenshots,
exact walkthroughs, renderer inputs, and aggregation were green. It ran from
12:31:04Z through 13:39:04Z for **68m00s** created-to-complete. Against the
same-coverage 48m16s fresh-host baseline, this single sample is **+19m44s
(+40.9%)** and is retained rather than discarded.

The added time was not hidden setup. The one shared producer consumed 24m58s,
including 1m26s installing Nix, 5m35s verifying source contracts and generating
the project, and 17m25s building and binding the product. That producer was
14m07s slower than the baseline producer. The consumer stage then spanned
42m48s from producer completion to the final story, versus the baseline's
35m34s (+7m14s); the critical dependency chain accumulated 11m44s of visible
post-dependency GitHub runner admission delay. The formal five-sample matrix
distribution, not this one high-variance normal sample, remains the fail-closed
10% runtime gate.

The same run provides an isolated before/after for the final Story 007 repair.
Its retained failing predecessor spent 22m31s in the canonical story step and
did not finish the second journey. The repaired job completed both journeys in
14m01s on its first fresh hosted attempt, **-8m30s (-37.7%)**; all three
screenshots were canonical and its exact walkthrough and evidence manifest
passed. Coverage was preserved: the eight timer choices now share one real
replacement session, while all six launches that prove teardown and durable
state remain.

### Latest clean-boot normal observation

[Run 33546561891](https://github.com/anicolao/player/actions/runs/33546561891)
passed the complete normal matrix at exact code SHA
`5cfc071854c81d18cbee374e0a31048029c52cea` without a rerun: all 13 stories,
all 41 UI selectors, 377/377 core tests, fixture gates, reviewed screenshots,
exact walkthroughs, renderer inputs, and aggregation were green. It ran from
18:56:10Z through 19:57:47Z for **61m37s** created-to-complete. That is
**+13m21s (+27.7%)** relative to the same-coverage 48m16s fresh-host baseline,
and the sample is retained rather than replaced by a faster run.

The one-time producer took **13m23s**, four seconds faster than the 13m27s
producer in run 33484894430. The consumer stage instead spanned **47m55s**,
versus 35m34s in the fresh-host baseline: **+12m21s (+34.7%)**. All five
available macOS slots were occupied, but fresh-host execution and admission
variance accumulated after the producer. The 13 story jobs consumed
**2h44m18s** in aggregate, the core/fixture job consumed **6m47s**, and all
successful macOS work, including the producer, totalled approximately
**3h04m28s**. These summed runner durations explain resource consumption; they
are not workflow wall clock.

This is a complete, coverage-preserving normal-CI observation, not a formal
runtime distribution. Its producer stability and consumer-stage variance are
additional evidence that a single hosted wall-clock result must not be used to
accept or reject the remediation. The fail-closed five-sample formal matrix
remains the authoritative runtime and reliability gate.

The focused document-ingress correction then passed the complete normal matrix
in [run 33558509980](https://github.com/anicolao/player/actions/runs/33558509980)
at exact branch-head SHA `fa2c47feda2d89baa602fcadf9076bce65e6cedf`,
again without a rerun. All 13 stories, all 41 UI selectors, 377/377 core tests,
fixture gates, reviewed screenshots, exact walkthroughs, and the App Store
renderer passed. Created-to-complete wall clock was **48m23s**, only **+7s
(+0.2%)** versus the same-coverage 48m16s fresh-host baseline. The producer
took **12m25s**; consumers spanned **35m44s**, just ten seconds above the
baseline's 35m34s; and producer plus consumers consumed **2h51m16s** in
aggregate, nine seconds less than the baseline's 2h51m25s. This clean sample
corroborates that maximal five-runner scheduling and reliability hardening did
not regress runtime, while the formal repeated distribution remains the final
acceptance gate.

The accessibility clean-boot correction subsequently passed the complete
normal matrix in
[run 33566621411](https://github.com/anicolao/player/actions/runs/33566621411)
at exact branch-head SHA `277d7e4ae2268cb5c6229b521a269b4b1399e979`,
without a rerun and with identical coverage. Created-to-complete wall clock was
**51m36s**, or **+3m20s (+6.9%)** against the same-coverage 48m16s fresh-host
baseline and still inside the 10% complete-suite contract. The consumer stage
spanned **35m35s**, just **+1s** against the baseline and **-9s** against the
previous clean validation. The one-time producer took **15m46s**, **+4m55s**
against the baseline producer, so producer variance more than explains the
workflow delta while the maximally parallel consumer graph remained stable.

All 13 stories, all 41 UI selectors, 377/377 core tests, fixture gates,
reviewed screenshots, exact walkthroughs, renderer inputs, and aggregation
passed. Story 009's two selectors completed in 155.030 seconds on its first
fresh hosted attempt and all seven screenshots matched canonically. This is a
retained exact-code sample rather than a replacement for the formal five-sample
distribution.

The simulator push-reconnect isolation then passed the complete normal matrix
in [run 33580527061](https://github.com/anicolao/player/actions/runs/33580527061)
at exact branch-head SHA `a4b78e8f8b8c8cbf96848f0c6311a0b80c4ba925`,
without a rerun and with identical coverage. Created-to-complete wall clock was
**45m34s**, or **-2m42s (-5.6%)** against the same-coverage 48m16s fresh-host
baseline. The producer completed in **11m40s**; the consumer and aggregation
stage spanned **33m51s**, **-1m43s (-4.8%)** against the baseline's 35m34s.

All 13 stories, all 41 UI selectors, 377/377 core tests, fixture gates,
reviewed screenshots, exact walkthroughs, renderer inputs, and fail-closed
aggregation passed. Story 005's eight selectors completed in a 5m53s test
phase on the fix's first fresh hosted attempt, including the real Home-button
lifecycle selector in 26.707 seconds; all four screenshots matched canonically.
This clean sample demonstrates that isolating an unrelated post-boot simulator
daemon did not trade coverage, event deadlines, or wall-clock performance for
reliability. It remains a normal-CI observation rather than a replacement for
the formal repeated distribution.

The subsequent compile-only producer correction is independently measured in
[run 33587696675](https://github.com/anicolao/player/actions/runs/33587696675).
Its generic arm64 simulator build completed in **5m31s**, versus **11m40s** for
the preceding accepted producer: **-6m09s (-52.7%)**. All 14 consumers accepted
the resulting provenance-bound artifact, so this measures the intended removal
of producer simulator creation rather than skipped downstream work. The overall
run is not an accepted suite sample because Story 005 reproduced an existing
lifecycle signature; all other stories and the core gate passed.

The retained Story 005 job explains its 19m51s hosted job time precisely. The
canonical story command consumed 17m10s: 4m34s creating and twice booting its
fresh simulator, 56s verifying build provenance, 53s installing and receipting
the app/test runner, 9m18s in XCTest (including the delayed lifecycle failure),
and 44s exporting failure diagnostics. The remaining 2m41s was job checkout,
artifact download, and workflow transitions. It did no image preparation and
no product compilation. This is why a prebuilt Docker image cannot remove the
dominant cost: iOS Simulator and Xcode require a macOS host, while GitHub-hosted
container jobs are Linux. The reusable generic build artifact is the applicable
preconfiguration boundary on hosted macOS.

Local replacement measurements serialize Story 005's four stateful test classes
to prevent shared-process and durable-store corruption while leaving canonical
stories parallel. Both the official recording pass and an independent
verification passed all eight selectors in **240 seconds** of XCTest, versus
**164 seconds** for the last locally successful but unsafe two-worker execution:
**+76 seconds** for deterministic intra-story isolation.

[Run 33592605851](https://github.com/anicolao/player/actions/runs/33592605851)
then passed the complete normal matrix at exact branch-head SHA
`c6057dbe4be4fc602c9bb7e336d6d211f3224260` on its first attempt: all 13
stories, all 41 UI selectors, 377/377 core tests, fixture gates, reviewed
screenshots and walkthroughs, App Store renderer inputs, and fail-closed
aggregation were green. Created-to-complete wall clock was **36m54s**, versus
the same-coverage 48m16s fresh-host baseline: **-11m22s (-23.6%)**. The generic
producer took **4m52s**, and the consumer/aggregation stage spanned **31m57s**,
versus the baseline's 35m34s: **-3m37s (-10.2%)**.

Hosted Story 005 completed in **13m26s** job time. Its canonical phase used
**12m37s**: 3m41s simulator setup, 16s provenance verification, 33s target
installation, 7m07s XCTest, 18s attachment export, and 41s screenshot
comparison. The serialized test phase is 1m14s slower than the preceding green
two-worker sample's 5m53s, closely matching the local +76-second measurement,
but the canonical story remains **2m18s (-15.4%)** faster than its 14m55s
expanded-suite reference. The complete workflow is also 8m40s faster than the
latest preceding green run 33580527061. This is the requested coverage-neutral
before/after normal-CI result; the formal repeated distribution remains the R0
reliability gate.

### Formal qualification topology reference

The pre-isolation formal
[run 33362158118](https://github.com/anicolao/player/actions/runs/33362158118)
ran from 05:54:19Z through 11:09:49Z: **5h15m30s** workflow wall clock.
Its 13 story jobs accumulated **21h50m36s** of macOS runner time, and their
story stage spanned **5h10m27s** from first admission to last completion. Each
long-lived job ran one story ten times. Attempts remained logically distinct,
but all ten shared the same hosted machine and its per-user Xcode service
state; Story 004's eighth attempt failed in Xcode's launch transaction before
the application process existed after the first seven attempts passed.

The replacement formal topology preserves the exact 13 stories x 10 attempts
and five complete matrices x five attempts. It publishes all 130 story attempts
and all 25 matrix-lane attempts as independently attributable jobs, while the
account's five-macOS-runner limit controls actual admission. One producer
installs Nix, verifies and generates the project, compiles the E2E product,
binds its provenance, and publishes a checksum. Fresh measured jobs use the
stock macOS image, verify that checksum and provenance, and run exactly one
attempt. This removes cross-attempt host state without deleting coverage,
retrying failures, or moving measured test execution outside CI.

The current normal lane setup confirms why the shared artifact matters. In
[run 33392110023](https://github.com/anicolao/player/actions/runs/33392110023),
lane 2 spent 61 seconds installing Nix, 51 seconds verifying the pinned
environment, and 8 seconds generating the project; including checkout and
step transitions, canonical execution began about 2m05s after runner admission.
Those costs occur once in the formal producer instead of in each of the 155
fresh measured jobs. GitHub container jobs run on Linux, whereas Xcode and the
iOS Simulator require macOS, so a Docker image cannot replace the macOS runner;
the immutable shared build is the applicable preconfiguration boundary.

The after-isolation formal wall-clock and runner-time measurements will be
recorded from the one permitted exact-SHA qualification dispatch. A normal PR
run is not substituted for that distribution.

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

### Fresh-host formal matrix rebalance

The independently scheduled formal matrix jobs consume one provenance-bound
build, so their relevant lane weights are the checked-in qualification story
and phase times rather than normal-CI job totals that each include fresh-host
checkout and artifact setup. The exact five-bin allocation below includes all
13 stories once, the 11-second renderer with Story 013, and the 208-second
core/fixture gate once.

| Lane | Canonical work | Reference load |
| --- | --- | ---: |
| 1 | 007 sleep timer; 002 import and play | 25m16s |
| 2 | 004 metadata repair; 009 accessible core journeys; core and fixtures | 25m11s |
| 3 | 005 play and restore; 013 App Store listing and renderer; 012 monetization | 25m26s |
| 4 | 001 iOS launch; 006 safe ZIP import; 003 multifile grouping | 25m38s |
| 5 | 008 library search; 010 library backup; 011 offline recovery | 25m26s |

The predicted critical lane falls from the reference allocation's 29m42s to
25m38s (-4m04s, -13.7%), and the new predicted spread is 27 seconds. This is a
coverage-neutral scheduling change; the formal report will publish the actual
five-matrix distribution rather than treating this model as measured fact.

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
3. Normal CI uses five measured dependency chains whose individual stories
   remain fresh-host jobs. The formal ten-attempt story stage exposes all 130
   attempts as independently scheduled jobs, and the five-matrix stage exposes
   all 25 lane attempts independently, so GitHub can keep every available
   macOS slot occupied without coupling one attempt to a long-lived host.
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
