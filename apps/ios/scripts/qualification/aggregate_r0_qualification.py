#!/usr/bin/env python3
import argparse
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def canonical_stories(manifest: Path):
    return [entry["story"] for entry in load_json(manifest)]


def distribution(values):
    if not values:
        return {"count": 0, "minimum": None, "median": None, "maximum": None, "p95": None}
    ordered = sorted(values)
    return {"count": len(ordered), "minimum": ordered[0],
            "median": statistics.median(ordered), "maximum": ordered[-1],
            "p95": ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]}


def discover(root: Path, filename: str):
    return sorted(root.rglob(filename)) if root.exists() else []


def evidence_path(lane_root: Path, relative, label, errors):
    if not isinstance(relative, str) or not relative:
        errors.append(f"{label} has no artifact path")
        return None
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        errors.append(f"{label} has an unsafe artifact path")
        return None
    return lane_root / candidate


def parse_phases(path: Path, label, errors):
    phases = defaultdict(int)
    if not path.is_file():
        errors.append(f"{label} is missing PhaseTimings.tsv")
        return phases
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        fields = line.split("\t")
        if len(fields) != 4:
            errors.append(f"{label} has malformed phase row {line_number}")
            continue
        phase, start, end, status = fields
        try:
            start_value, end_value = int(start), int(end)
        except ValueError:
            errors.append(f"{label} has nonnumeric phase row {line_number}")
            continue
        if not phase or not status or start_value < 0 or end_value < start_value:
            errors.append(f"{label} has invalid phase row {line_number}")
            continue
        if phase in phases:
            errors.append(f"{label} records phase {phase} more than once")
        phases[phase] += end_value - start_value
    return phases


def validate_attempt_evidence(lane_root, record, story, sha, label, errors):
    root = evidence_path(lane_root, record.get("artifact"), label, errors)
    if root is None:
        return {}
    if not root.is_dir():
        errors.append(f"{label} artifact directory is missing")
        return {}
    run_path = root / "Run.json"
    if not run_path.is_file():
        errors.append(f"{label} is missing Run.json")
    else:
        try:
            run = load_json(run_path)
            expected_status = record.get("result", record.get("status"))
            if run.get("story") != story or run.get("commit") != sha or run.get("status") != expected_status:
                errors.append(f"{label} Run.json does not match its summary")
        except (OSError, ValueError, TypeError):
            errors.append(f"{label} has invalid Run.json")
    log = root / "Logs/test.log"
    if not log.is_file() or log.stat().st_size == 0:
        errors.append(f"{label} is missing a nonempty test log")
    result = root / "Results/Story.xcresult"
    if not result.is_dir() or not (result / "Info.plist").is_file():
        errors.append(f"{label} is missing a complete result bundle")
    phases = parse_phases(root / "PhaseTimings.tsv", label, errors)
    entered = "test" in phases
    if record.get("testPhaseEntered") is not entered:
        errors.append(f"{label} testPhaseEntered disagrees with recorded phases")
    return phases


def validate_story(root, expected_stories, sha, requested_attempts):
    errors, durations, signatures = [], [], {}
    pairs = [(path, load_json(path)) for path in discover(root, "StoryLaneSummary.json")]
    lanes = [item.get("lane") for _, item in pairs]
    if len(pairs) != 5 or len(set(lanes)) != 5:
        errors.append(f"expected 5 unique story lane summaries, found {len(pairs)}")
    seen = []
    for path, lane in pairs:
        lane_root = path.parent
        if lane.get("stage") != "story" or lane.get("commit") != sha:
            errors.append(f"story lane {lane.get('lane')} has the wrong stage or SHA")
        if lane.get("requestedAttempts") != requested_attempts:
            errors.append(f"story lane {lane.get('lane')} requested the wrong attempt count")
        if not lane.get("buildUnchanged") or lane.get("infrastructureInvalid"):
            errors.append(f"story lane {lane.get('lane')} failed source/build integrity")
        if lane.get("status") != "passed":
            errors.append(f"story lane {lane.get('lane')} is not green")
        for story in lane.get("stories", []):
            story_id = story.get("story")
            seen.append(story_id)
            attempts = story.get("attempts", [])
            ids = [item.get("attempt") for item in attempts]
            if story.get("commit") != sha or story.get("requestedAttempts") != requested_attempts:
                errors.append(f"{story_id} has the wrong SHA or requested count")
            if story.get("attemptCount") != requested_attempts or ids != list(range(1, requested_attempts + 1)):
                errors.append(f"{story_id} does not contain attempts 1-{requested_attempts}")
            if story.get("passCount") != requested_attempts or story.get("failureCount") != 0:
                errors.append(f"{story_id} did not pass {requested_attempts}/{requested_attempts}")
            for attempt in attempts:
                durations.append(attempt.get("durationSeconds", 0))
                signature = attempt.get("signature", "none")
                if signature != "none": signatures[signature] = signatures.get(signature, 0) + 1
                label = f"{story_id} attempt {attempt.get('attempt')}"
                if attempt.get("result") != "passed" or not attempt.get("testPhaseEntered"):
                    errors.append(f"{label} is not a measured pass")
                validate_attempt_evidence(lane_root, attempt, story_id, sha, label, errors)
    if sorted(seen) != sorted(expected_stories) or len(seen) != len(set(seen)):
        errors.append("story lane coverage does not equal the canonical manifest exactly once")
    return {"lanes": len(pairs), "stories": len(seen), "durations": distribution(durations),
            "signatures": signatures, "errors": errors}


def validate_renderer(lane_root, matrix, index, expected_asset_count, errors):
    renderer = matrix.get("appStoreRenderer", {})
    if not renderer.get("required") or renderer.get("status") != "passed" or renderer.get("exitCode") != 0:
        errors.append(f"logical matrix {index} does not contain a passing App Store renderer")
        return None
    root = evidence_path(lane_root, renderer.get("artifact"), f"matrix {index} renderer", errors)
    expected = renderer.get("expectedAssetCount")
    if root is None or expected != expected_asset_count:
        errors.append(f"matrix {index} renderer has invalid asset evidence")
        return None
    pngs = list((root / "screenshots").glob("*.png")) if root.is_dir() else []
    if len(pngs) != expected or renderer.get("renderedAssetCount") != expected:
        errors.append(f"matrix {index} renderer did not produce exactly {expected} assets")
    renderer_log = root / "renderer.log"
    if not renderer_log.is_file() or renderer_log.stat().st_size == 0:
        errors.append(f"matrix {index} renderer log is missing or empty")
    return renderer.get("durationSeconds")


def validate_core(lane_root, gate, index, errors):
    root = evidence_path(lane_root, gate.get("artifact"), f"logical matrix {index} core", errors)
    if root is None or not root.is_dir():
        errors.append(f"logical matrix {index} core artifact directory is missing")
        return
    for relative in ("Logs/fixtures.log", "Logs/tests.log"):
        path = root / relative
        if not path.is_file() or path.stat().st_size == 0:
            errors.append(f"logical matrix {index} core is missing nonempty {relative}")
    result = root / "Results/Core.xcresult/Info.plist"
    if not result.is_file():
        errors.append(f"logical matrix {index} core result bundle is incomplete")


def validate_matrices(root, expected_stories, sha, requested_matrices, baseline):
    errors, durations, signatures = [], [], {}
    story_values, phase_matrix_values, wall_values = defaultdict(list), defaultdict(list), []
    pairs = [(path, load_json(path)) for path in discover(root, "MatrixLaneSummary.json")]
    lanes = [item.get("lane") for _, item in pairs]
    if len(pairs) != 5 or len(set(lanes)) != 5:
        errors.append(f"expected 5 unique matrix lane summaries, found {len(pairs)}")
    by_attempt = {index: [] for index in range(1, requested_matrices + 1)}
    for path, lane in pairs:
        lane_root = path.parent
        if lane.get("stage") != "matrix" or lane.get("commit") != sha:
            errors.append(f"matrix lane {lane.get('lane')} has the wrong stage or SHA")
        if lane.get("requestedMatrices") != requested_matrices or lane.get("matrixCount") != requested_matrices:
            errors.append(f"matrix lane {lane.get('lane')} does not contain {requested_matrices} matrices")
        if not lane.get("buildUnchanged") or lane.get("infrastructureInvalid") or lane.get("status") != "passed":
            errors.append(f"matrix lane {lane.get('lane')} failed integrity or is not green")
        indices = [item.get("matrixAttempt") for item in lane.get("matrices", [])]
        if indices != list(range(1, requested_matrices + 1)):
            errors.append(f"matrix lane {lane.get('lane')} has noncontiguous matrix attempts")
        for matrix in lane.get("matrices", []):
            index = matrix.get("matrixAttempt")
            if index in by_attempt: by_attempt[index].append((lane_root, matrix))
            if matrix.get("commit") != sha or matrix.get("status") != "passed":
                errors.append(f"matrix {index} lane {lane.get('lane')} is not a measured pass")
            for story in matrix.get("stories", []):
                story_id = story.get("story")
                durations.append(story.get("durationSeconds", 0))
                story_values[story_id].append(story.get("durationSeconds", 0))
                signature = story.get("signature", "none")
                if signature != "none": signatures[signature] = signatures.get(signature, 0) + 1
                label = f"matrix {index} story {story_id}"
                if story.get("commit") != sha or story.get("status") != "passed" or not story.get("testPhaseEntered"):
                    errors.append(f"{label} is not a measured pass")
                story["_phases"] = validate_attempt_evidence(lane_root, story, story_id, sha, label, errors)
    for index, matrices in by_attempt.items():
        stories = [story.get("story") for _, matrix in matrices for story in matrix.get("stories", [])]
        if len(matrices) != 5 or sorted(stories) != sorted(expected_stories) or len(stories) != len(set(stories)):
            errors.append(f"logical matrix {index} does not contain five lanes and every story exactly once")
        core = [matrix.get("core", {}) for _, matrix in matrices if matrix.get("core", {}).get("required")]
        if len(core) != 1 or core[0].get("status") != "passed":
            errors.append(f"logical matrix {index} does not contain one passing core gate")
        else:
            core_lane_root = next(lane_root for lane_root, matrix in matrices
                                  if matrix.get("core", {}).get("required"))
            validate_core(core_lane_root, core[0], index, errors)
            for key, phase in (("fixtureDurationSeconds", "core-fixtures"), ("testDurationSeconds", "core-tests")):
                value = core[0].get(key)
                if not isinstance(value, int) or value < 0: errors.append(f"logical matrix {index} has invalid {phase} timing")
                else: phase_matrix_values[phase].append(value)
        renderers = [(lane_root, matrix) for lane_root, matrix in matrices
                     if matrix.get("appStoreRenderer", {}).get("required")]
        if len(renderers) != 1:
            errors.append(f"logical matrix {index} does not contain exactly one required App Store renderer")
        else:
            if not any(story.get("story") == "013-app-store-listing"
                       for story in renderers[0][1].get("stories", [])):
                errors.append(f"logical matrix {index} renderer is not attached to Story 013")
            value = validate_renderer(renderers[0][0], renderers[0][1], index,
                                      baseline["appStoreAssetCount"], errors)
            if isinstance(value, int) and value >= 0: phase_matrix_values["app-store-renderer"].append(value)
        lane_durations = [matrix.get("durationSeconds") for _, matrix in matrices]
        if len(lane_durations) != 5 or any(not isinstance(value, int) or value < 0 for value in lane_durations):
            errors.append(f"logical matrix {index} has invalid lane wall-clock timings")
        else:
            wall_values.append(max(lane_durations))
        phase_totals = defaultdict(int)
        for _, matrix in matrices:
            for story in matrix.get("stories", []):
                for phase, value in story.pop("_phases", {}).items(): phase_totals[phase] += value
        for phase, value in phase_totals.items(): phase_matrix_values[phase].append(value)

    thresholds = baseline["thresholds"]
    suite_baseline = baseline["suite"]["logicalWallSeconds"]
    wall_distribution = distribution(wall_values)
    suite_delta = None if wall_distribution["median"] is None else wall_distribution["median"] / suite_baseline - 1
    if suite_delta is not None and suite_delta > thresholds["suiteRegression"]:
        errors.append(f"logical matrix wall-clock regressed {suite_delta:.1%}; limit is {thresholds['suiteRegression']:.0%}")
    story_timings = {}
    for story in expected_stories:
        values = story_values[story]
        stats = distribution(values)
        expected = baseline["stories"][story]
        delta = None if stats["median"] is None else stats["median"] / expected - 1
        story_timings[story] = {"baselineSeconds": expected, "current": stats, "delta": delta}
        if len(values) != requested_matrices:
            errors.append(f"{story} does not contain {requested_matrices} timing samples")
        if delta is not None and delta > thresholds["storyRegression"]:
            errors.append(f"{story} regressed {delta:.1%}; limit is {thresholds['storyRegression']:.0%}")
    phase_timings = {}
    for phase, expected in baseline["phases"].items():
        stats = distribution(phase_matrix_values.get(phase, []))
        if stats["count"] != requested_matrices:
            errors.append(f"phase {phase} does not contain {requested_matrices} timing samples")
        delta = None if stats["median"] is None or expected == 0 else stats["median"] / expected - 1
        phase_timings[phase] = {"baselineSeconds": expected, "current": stats, "delta": delta}
    return {"lanes": len(pairs), "matrices": requested_matrices, "durations": distribution(durations),
            "logicalWallClock": {"baselineSeconds": suite_baseline, "current": wall_distribution, "delta": suite_delta},
            "storyTimings": story_timings, "phaseTimings": phase_timings,
            "signatures": signatures, "errors": errors}


def validate_baseline(path, expected_stories):
    baseline = load_json(path)
    if baseline.get("schemaVersion") != 1 or set(baseline.get("stories", {})) != set(expected_stories):
        raise ValueError("runtime baseline does not match schema or canonical stories")
    required = [baseline.get("suite", {}).get("logicalWallSeconds"),
                baseline.get("appStoreAssetCount"), *baseline["stories"].values()]
    thresholds = baseline.get("thresholds", {})
    if any(not isinstance(value, (int, float)) or value <= 0 for value in required):
        raise ValueError("runtime baseline values must be positive")
    if any(not isinstance(value, (int, float)) or value < 0 for value in baseline.get("phases", {}).values()):
        raise ValueError("runtime phase baseline values must be nonnegative")
    if thresholds.get("suiteRegression") != 0.10 or thresholds.get("storyRegression") != 0.20:
        raise ValueError("runtime baseline must enforce 10% suite and 20% story limits")
    return baseline


def render_report(output: Path, sha: str, story, matrices=None):
    all_errors = story["errors"] + ([] if matrices is None else matrices["errors"])
    payload = {"commit": sha, "status": "passed" if not all_errors else "failed",
               "storyQualification": story, "matrixQualification": matrices, "errors": all_errors}
    output.mkdir(parents=True, exist_ok=True)
    (output / "QualificationSummary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    lines = ["# R0 E2E stability report", "", f"- Commit: `{sha}`", f"- Result: **{payload['status'].upper()}**",
             f"- Story gate: {story['stories']} stories; {story['durations']['count']} attempts"]
    if matrices is not None:
        wall = matrices["logicalWallClock"]
        wall_change = "n/a" if wall["delta"] is None else f"{wall['delta']:.1%}"
        lines += [f"- Matrix gate: {matrices['matrices']} logical complete matrices", "", "## Runtime regression gates", "",
                  "| Scope | Baseline (s) | Current median (s) | Change | Limit |", "|---|---:|---:|---:|---:|",
                  f"| Complete matrix wall | {wall['baselineSeconds']} | {wall['current']['median']} | {wall_change} | 10% |"]
        for name, timing in matrices["storyTimings"].items():
            change = "n/a" if timing["delta"] is None else f"{timing['delta']:.1%}"
            lines.append(f"| `{name}` | {timing['baselineSeconds']} | {timing['current']['median']} | {change} | 20% |")
        lines += ["", "## Phase timing", "", "| Phase | Baseline (s) | Current median (s) | Change |", "|---|---:|---:|---:|"]
        for name, timing in matrices["phaseTimings"].items():
            change = "n/a" if timing["delta"] is None else f"{timing['delta']:.1%}"
            lines.append(f"| `{name}` | {timing['baselineSeconds']} | {timing['current']['median']} | {change} |")
    lines += ["", "## Failure signatures", ""]
    signatures = dict(story["signatures"])
    if matrices:
        for key, value in matrices["signatures"].items(): signatures[key] = signatures.get(key, 0) + value
    lines += [f"- `{key}`: {value}" for key, value in sorted(signatures.items())] or ["- None"]
    lines += ["", "## Validation errors", ""]
    lines += [f"- {error}" for error in all_errors] or ["- None"]
    (output / "STABILITY_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0 if not all_errors else 1


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--story-input", type=Path, required=True)
    parser.add_argument("--matrix-input", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--runtime-baseline", type=Path,
                        default=Path(__file__).with_name("r0_runtime_baseline.json"))
    parser.add_argument("--sha", required=True)
    parser.add_argument("--story-attempts", type=int, default=10)
    parser.add_argument("--matrix-attempts", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    stories = canonical_stories(args.manifest)
    try:
        baseline = validate_baseline(args.runtime_baseline, stories)
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
        print(f"Invalid runtime baseline: {error}", file=sys.stderr)
        return 2
    story_result = validate_story(args.story_input, stories, args.sha, args.story_attempts)
    matrix_result = None
    if args.matrix_input is not None:
        matrix_result = validate_matrices(args.matrix_input, stories, args.sha, args.matrix_attempts, baseline)
    return render_report(args.output, args.sha, story_result, matrix_result)


if __name__ == "__main__":
    sys.exit(main())
