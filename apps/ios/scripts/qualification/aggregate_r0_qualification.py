#!/usr/bin/env python3
import argparse
import json
import math
import statistics
import sys
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
    return {
        "count": len(ordered),
        "minimum": ordered[0],
        "median": statistics.median(ordered),
        "maximum": ordered[-1],
        "p95": ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)],
    }


def discover(root: Path, filename: str):
    return sorted(root.rglob(filename)) if root.exists() else []


def validate_story(root, expected_stories, sha, requested_attempts):
    errors, durations, signatures = [], [], {}
    paths = discover(root, "StoryLaneSummary.json")
    summaries = [load_json(path) for path in paths]
    lanes = [item.get("lane") for item in summaries]
    if len(summaries) != 5 or len(set(lanes)) != 5:
        errors.append(f"expected 5 unique story lane summaries, found {len(summaries)}")
    seen = []
    for lane in summaries:
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
                if signature != "none":
                    signatures[signature] = signatures.get(signature, 0) + 1
                if attempt.get("result") != "passed" or not attempt.get("testPhaseEntered"):
                    errors.append(f"{story_id} attempt {attempt.get('attempt')} is not a measured pass")
    if sorted(seen) != sorted(expected_stories) or len(seen) != len(set(seen)):
        errors.append("story lane coverage does not equal the canonical manifest exactly once")
    return {"lanes": len(summaries), "stories": len(seen), "durations": distribution(durations),
            "signatures": signatures, "errors": errors}


def validate_matrices(root, expected_stories, sha, requested_matrices):
    errors, durations, signatures = [], [], {}
    paths = discover(root, "MatrixLaneSummary.json")
    summaries = [load_json(path) for path in paths]
    lanes = [item.get("lane") for item in summaries]
    if len(summaries) != 5 or len(set(lanes)) != 5:
        errors.append(f"expected 5 unique matrix lane summaries, found {len(summaries)}")
    by_attempt = {index: [] for index in range(1, requested_matrices + 1)}
    for lane in summaries:
        if lane.get("stage") != "matrix" or lane.get("commit") != sha:
            errors.append(f"matrix lane {lane.get('lane')} has the wrong stage or SHA")
        if lane.get("requestedMatrices") != requested_matrices or lane.get("matrixCount") != requested_matrices:
            errors.append(f"matrix lane {lane.get('lane')} does not contain {requested_matrices} matrices")
        if not lane.get("buildUnchanged") or lane.get("infrastructureInvalid"):
            errors.append(f"matrix lane {lane.get('lane')} failed source/build integrity")
        if lane.get("status") != "passed":
            errors.append(f"matrix lane {lane.get('lane')} is not green")
        indices = [item.get("matrixAttempt") for item in lane.get("matrices", [])]
        if indices != list(range(1, requested_matrices + 1)):
            errors.append(f"matrix lane {lane.get('lane')} has noncontiguous matrix attempts")
        for matrix in lane.get("matrices", []):
            index = matrix.get("matrixAttempt")
            if index in by_attempt:
                by_attempt[index].append(matrix)
            if matrix.get("commit") != sha or matrix.get("status") != "passed":
                errors.append(f"matrix {index} lane {lane.get('lane')} is not a measured pass")
            for story in matrix.get("stories", []):
                durations.append(story.get("durationSeconds", 0))
                signature = story.get("signature", "none")
                if signature != "none":
                    signatures[signature] = signatures.get(signature, 0) + 1
                if story.get("commit") != sha or story.get("status") != "passed" or not story.get("testPhaseEntered"):
                    errors.append(f"matrix {index} story {story.get('story')} is not a measured pass")
    for index, matrices in by_attempt.items():
        stories = [story.get("story") for matrix in matrices for story in matrix.get("stories", [])]
        if len(matrices) != 5 or sorted(stories) != sorted(expected_stories) or len(stories) != len(set(stories)):
            errors.append(f"logical matrix {index} does not contain five lanes and every story exactly once")
        core = [matrix.get("core", {}) for matrix in matrices if matrix.get("core", {}).get("required")]
        if len(core) != 1 or core[0].get("status") != "passed":
            errors.append(f"logical matrix {index} does not contain one passing core gate")
    return {"lanes": len(summaries), "matrices": requested_matrices,
            "durations": distribution(durations), "signatures": signatures, "errors": errors}


def render_report(output: Path, sha: str, story, matrices=None):
    all_errors = story["errors"] + ([] if matrices is None else matrices["errors"])
    payload = {"commit": sha, "status": "passed" if not all_errors else "failed",
               "storyQualification": story, "matrixQualification": matrices, "errors": all_errors}
    output.mkdir(parents=True, exist_ok=True)
    (output / "QualificationSummary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    lines = ["# R0 E2E stability report", "", f"- Commit: `{sha}`",
             f"- Result: **{payload['status'].upper()}**",
             f"- Story gate: {story['stories']} stories; {story['durations']['count']} attempts",
             f"- Story duration (s): min {story['durations']['minimum']}, median {story['durations']['median']}, p95 {story['durations']['p95']}, max {story['durations']['maximum']}"]
    if matrices is not None:
        lines += [f"- Matrix gate: {matrices['matrices']} logical complete matrices",
                  f"- Matrix story duration (s): min {matrices['durations']['minimum']}, median {matrices['durations']['median']}, p95 {matrices['durations']['p95']}, max {matrices['durations']['maximum']}"]
    lines += ["", "## Failure signatures", ""]
    signatures = dict(story["signatures"])
    if matrices:
        for key, value in matrices["signatures"].items():
            signatures[key] = signatures.get(key, 0) + value
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
    parser.add_argument("--sha", required=True)
    parser.add_argument("--story-attempts", type=int, default=10)
    parser.add_argument("--matrix-attempts", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    stories = canonical_stories(args.manifest)
    story_result = validate_story(args.story_input, stories, args.sha, args.story_attempts)
    matrix_result = None
    if args.matrix_input is not None:
        matrix_result = validate_matrices(args.matrix_input, stories, args.sha, args.matrix_attempts)
    return render_report(args.output, args.sha, story_result, matrix_result)


if __name__ == "__main__":
    sys.exit(main())
