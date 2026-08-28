# R0 E2E qualification

The manual **R0 E2E qualification** workflow is the release gate for declaring
the canonical walkthrough suite deterministic. Dispatch it from the exact
commit being qualified and paste that commit's full 40-character SHA into
`expected_sha`. The workflow rejects a selected ref that does not resolve to
that exact SHA.

The gate deliberately has two phases:

1. Five macOS story lanes run every canonical story ten consecutive times.
   Each measured attempt gets a fresh simulator and complete retained evidence.
2. After every story reaches 10/10, five macOS lanes run five logical copies of
   the production CI matrix. A logical matrix is the union of the same numbered
   attempt from all five lanes. Every matrix attempt uses a fresh detached
   worktree and fresh story simulators; lane 5 also repeats core and fixture
   verification. The lane containing Story 013 also runs the same App Store
   asset renderer as production CI and retains all seven rendered PNGs.

Each macOS lane verifies and generates once, then shares only one compiled test
bundle. The qualification scripts hash every file in the shared build products
after its creation and again after the lane. A changed build invalidates the
qualification. Source SHA and tracked-worktree cleanliness are checked between
attempts.

Test failures never stop later scheduled attempts and are never retried. The
lane records the first supported failure signature and exits unsuccessfully
after completing its measurements. A test phase counts as entered only when
`PhaseTimings.tsv` contains one well-formed `test` phase; merely creating a log
or result directory is not sufficient. Every recorded attempt must retain a
matching `Run.json`, phase timings, a nonempty test log, and a complete result
bundle. A failure before any test phase begins is marked as invalid
infrastructure evidence and is not silently converted into a test result. Any
rerun is a new qualification attempt with distinct immutable
artifact names; evidence from different SHAs or workflow attempts cannot be
combined.

Raw story and matrix-lane artifacts are retained for 30 days. The story gate
and final `STABILITY_REPORT.md`/`QualificationSummary.json` reports are retained
for 90 days, subject to the repository retention ceiling. Shared build products
are intentionally excluded from uploads.

The final `Exact-SHA R0 qualification report` job is the authoritative gate. It
fails closed on a missing lane, missing attempt, duplicate story, wrong SHA,
changed build, infrastructure-invalid run, red test, absent core gate, or any
matrix that does not contain all 13 canonical stories exactly once. It also
fails if renderer evidence is absent, median logical complete-matrix wall time
regresses more than 10%, or any median story time regresses more than 20%.
The report includes minimum, median, p95, and maximum logical wall time plus
before/after per-story and per-phase measurements.
