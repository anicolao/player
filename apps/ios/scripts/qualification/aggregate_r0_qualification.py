#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import re
import statistics
import struct
import sys
import zlib
from collections import defaultdict
from pathlib import Path

from evidence_manifest import validate_manifest

STORY_PHASES = {
    "attachment-export", "build-provenance", "build-reuse",
    "environment-reuse", "readme-comparison", "screenshot-comparison",
    "simulator", "simulator-control-plane-reset", "target-install",
    "target-source-hiding", "test", "walkthrough-materialization",
}
SHARED_PHASES = {"build"}
GATE_PHASES = {"core-fixtures", "core-tests", "app-store-renderer"}
REQUIRED_PHASES = STORY_PHASES | SHARED_PHASES | GATE_PHASES


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def canonical_stories(manifest: Path):
    return [entry["story"] for entry in load_json(manifest)]


def validate_build_summary(path: Path, sha: str):
    summary = load_json(path)
    if (not isinstance(summary, dict)
            or set(summary) != {"schemaVersion", "commit", "durationSeconds"}
            or summary.get("schemaVersion") != 1
            or summary.get("commit") != sha
            or not nonnegative_integer(summary.get("durationSeconds"))):
        raise ValueError("shared-build summary must bind one nonnegative duration to the exact SHA")
    return summary


def validate_sampling_plan(path: Path, expected_stories):
    plan = load_json(path)
    required = {
        "schemaVersion", "strategy", "source", "successfulFreshHostAttempts",
        "targetStories", "storyAttempts", "fullMatrixAttempts", "coveragePolicy",
    }
    if not isinstance(plan, dict) or set(plan) != required:
        raise ValueError("sampling plan must contain the exact required fields")
    if plan["schemaVersion"] != 1 or plan["strategy"] != "least-sampled-first":
        raise ValueError("sampling plan must use the supported least-sampled-first schema")
    source = plan["source"]
    if not isinstance(source, dict) or set(source) != {"workflowRun", "url", "commit"}:
        raise ValueError("sampling plan source is invalid")
    if (not isinstance(source["workflowRun"], int) or source["workflowRun"] <= 0
            or not isinstance(source["url"], str)
            or not re.fullmatch(r"https://github\.com/[^/]+/[^/]+/actions/runs/[0-9]+", source["url"])
            or not isinstance(source["commit"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", source["commit"])):
        raise ValueError("sampling plan source must identify one retained exact-SHA run")
    counts = plan["successfulFreshHostAttempts"]
    if (not isinstance(counts, dict) or set(counts) != set(expected_stories)
            or any(not nonnegative_integer(value) for value in counts.values())):
        raise ValueError("sampling plan must count every canonical story exactly once")
    targets = plan["targetStories"]
    if (not isinstance(targets, list) or not targets
            or any(not isinstance(story, str) for story in targets)
            or len(targets) != len(set(targets))
            or any(story not in counts for story in targets)):
        raise ValueError("sampling plan targetStories must be a unique canonical subset")
    minimum = min(counts.values())
    expected_targets = [story for story in expected_stories if counts[story] == minimum]
    if targets != expected_targets:
        raise ValueError("sampling plan must target every least-sampled story in canonical order")
    if plan["storyAttempts"] != 10 or plan["fullMatrixAttempts"] != 1:
        raise ValueError("sampling plan must request ten targeted attempts and one full matrix")
    if not isinstance(plan["coveragePolicy"], str) or not plan["coveragePolicy"].strip():
        raise ValueError("sampling plan must explain how full coverage is retained")
    return plan


def distribution(values):
    if not values:
        return {"count": 0, "minimum": None, "median": None, "maximum": None, "p95": None}
    ordered = sorted(values)
    return {"count": len(ordered), "minimum": ordered[0],
            "median": statistics.median(ordered), "maximum": ordered[-1],
            "p95": ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]}


def discover(root: Path, filename: str):
    return sorted(root.rglob(filename)) if root.exists() else []


def summary_pairs(root: Path, filename: str, errors):
    pairs = []
    for path in discover(root, filename):
        try:
            value = load_json(path)
        except (OSError, ValueError, TypeError, UnicodeError) as error:
            errors.append(f"{path} is not valid JSON: {error}")
            continue
        if not isinstance(value, dict):
            errors.append(f"{path} must contain a JSON object")
            continue
        pairs.append((path, value))
    return pairs


def nonnegative_integer(value):
    return type(value) is int and value >= 0


def finite_number(value, minimum):
    return type(value) in (int, float) and math.isfinite(value) and value >= minimum


def validate_measured_record(record, status_key, label, errors):
    duration = record.get("durationSeconds")
    exit_code = record.get("exitCode")
    status = record.get(status_key)
    signature = record.get("signature")
    if not nonnegative_integer(duration):
        errors.append(f"{label} has an invalid durationSeconds")
        duration = None
    if not nonnegative_integer(exit_code):
        errors.append(f"{label} has an invalid exitCode")
    if status == "passed":
        if exit_code != 0:
            errors.append(f"{label} reports passed with a nonzero exitCode")
        if signature != "none":
            errors.append(f"{label} reports passed with a failure signature")
    elif status == "failed":
        if exit_code == 0:
            errors.append(f"{label} reports failed with a zero exitCode")
        if not isinstance(signature, str) or signature == "none":
            errors.append(f"{label} reports failed without a failure signature")
    else:
        errors.append(f"{label} has an invalid {status_key}")
    return duration


def list_field(record, key, label, errors):
    value = record.get(key)
    if not isinstance(value, list):
        errors.append(f"{label} {key} must be an array")
        return []
    return value


def evidence_path(lane_root: Path, relative, label, errors):
    if not isinstance(relative, str) or not relative:
        errors.append(f"{label} has no artifact path")
        return None
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        errors.append(f"{label} has an unsafe artifact path")
        return None
    return lane_root / candidate


def require_canonical_artifact(record, expected, observed, label, errors):
    artifact = record.get("artifact")
    if artifact != expected:
        errors.append(f"{label} artifact must be {expected}")
    if isinstance(artifact, str):
        if artifact in observed:
            errors.append(f"{label} reuses artifact {artifact}")
        else:
            observed.add(artifact)


def validate_integrity_manifest(root: Path, label, errors):
    manifest = root / "EvidenceManifest.sha256"
    if not manifest.is_file():
        errors.append(f"{label} is missing EvidenceManifest.sha256")
        return
    try:
        lines = manifest.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        errors.append(f"{label} has an unreadable integrity manifest: {error}")
        return
    declared = {}
    for line_number, line in enumerate(lines, 1):
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None:
            errors.append(f"{label} has malformed integrity row {line_number}")
            continue
        relative = match.group(2)
        candidate = Path(relative)
        normalized = candidate.as_posix()
        if candidate.is_absolute() or ".." in candidate.parts or normalized in declared:
            errors.append(f"{label} has an unsafe or duplicate integrity path")
            continue
        declared[normalized] = match.group(1)
    actual = {}
    try:
        for path in root.rglob("*"):
            if path == manifest:
                continue
            if path.is_symlink():
                errors.append(f"{label} contains an unattested symbolic link")
            elif path.is_file():
                actual[path.relative_to(root).as_posix()] = path
    except OSError as error:
        errors.append(f"{label} artifacts cannot be inventoried: {error}")
        return
    if set(declared) != set(actual):
        errors.append(f"{label} integrity manifest file set does not match its artifact")
    for relative in set(declared) & set(actual):
        try:
            digest = hashlib.sha256(actual[relative].read_bytes()).hexdigest()
        except OSError as error:
            errors.append(f"{label} cannot hash {relative}: {error}")
            continue
        if digest != declared[relative]:
            errors.append(f"{label} integrity hash mismatch for {relative}")


def png_dimensions(path: Path):
    payload = path.read_bytes()
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("invalid PNG signature")
    offset, dimensions, header = 8, None, None
    ended, saw_idat = False, False
    compressed = bytearray()
    while offset + 12 <= len(payload):
        length = struct.unpack(">I", payload[offset:offset + 4])[0]
        chunk_type = payload[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(payload):
            raise ValueError("truncated PNG chunk")
        chunk_data = payload[offset + 8:offset + 8 + length]
        expected_crc = struct.unpack(">I", payload[offset + 8 + length:end])[0]
        if zlib.crc32(chunk_type + chunk_data) & 0xffffffff != expected_crc:
            raise ValueError("invalid PNG checksum")
        if offset == 8:
            if chunk_type != b"IHDR" or length != 13:
                raise ValueError("missing PNG IHDR")
            dimensions = struct.unpack(">II", chunk_data[:8])
            header = struct.unpack(">IIBBBBB", chunk_data)
        elif chunk_type == b"IHDR":
            raise ValueError("duplicate PNG IHDR")
        if chunk_type == b"IDAT":
            saw_idat = True
            compressed.extend(chunk_data)
        if chunk_type == b"IEND":
            if length != 0:
                raise ValueError("invalid PNG IEND")
            ended = True
            if end != len(payload):
                raise ValueError("data follows PNG IEND")
            break
        offset = end
    if not ended or dimensions is None or header is None or min(dimensions) <= 0:
        raise ValueError("incomplete PNG")
    if not saw_idat:
        raise ValueError("missing PNG image data")
    width, height, bit_depth, color_type, compression, filtering, interlace = header
    legal_depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8},
                    4: {8, 16}, 6: {8, 16}}
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
    if bit_depth not in legal_depths.get(color_type, set()) \
            or compression != 0 or filtering != 0 or interlace not in (0, 1):
        raise ValueError("unsupported PNG header")
    bits_per_pixel = bit_depth * channels[color_type]
    if interlace == 0:
        expected_bytes = height * (1 + (width * bits_per_pixel + 7) // 8)
    else:
        expected_bytes = 0
        for x_start, y_start, x_step, y_step in (
                (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
                (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)):
            pass_width = max(0, (width - x_start + x_step - 1) // x_step)
            pass_height = max(0, (height - y_start + y_step - 1) // y_step)
            if pass_width and pass_height:
                expected_bytes += pass_height * (1 + (pass_width * bits_per_pixel + 7) // 8)
    try:
        pixels = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        raise ValueError(f"invalid PNG image data: {error}") from error
    if len(pixels) != expected_bytes:
        raise ValueError("PNG image data has an invalid decoded size")
    return dimensions


def parse_phases(path: Path, label, errors):
    phases = defaultdict(int)
    statuses = {}
    if not path.is_file():
        errors.append(f"{label} is missing PhaseTimings.tsv")
        return {"durations": phases, "statuses": statuses}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        errors.append(f"{label} has unreadable PhaseTimings.tsv: {error}")
        return {"durations": phases, "statuses": statuses}
    for line_number, line in enumerate(lines, 1):
        fields = line.split("\t")
        if len(fields) != 4:
            errors.append(f"{label} has malformed phase row {line_number}")
            continue
        phase, start, end, status = fields
        try:
            start_value, end_value, status_value = int(start), int(end), int(status)
        except ValueError:
            errors.append(f"{label} has nonnumeric phase row {line_number}")
            continue
        if not phase or start_value < 0 or end_value < start_value or status_value < 0:
            errors.append(f"{label} has invalid phase row {line_number}")
            continue
        if phase in phases:
            errors.append(f"{label} records phase {phase} more than once")
        phases[phase] += end_value - start_value
        statuses[phase] = status_value
    return {"durations": phases, "statuses": statuses}


def validate_attempt_evidence(lane_root, canonical_root, record, story, sha, label, errors):
    root = evidence_path(lane_root, record.get("artifact"), label, errors)
    if root is None:
        return {}
    if not root.is_dir():
        errors.append(f"{label} artifact directory is missing")
        return {}
    if record.get("evidenceValid") is not True:
        errors.append(f"{label} summary does not attest valid evidence")
    try:
        manifest_errors = validate_manifest(root, canonical_root / story, story)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        manifest_errors = [f"manifest validation raised an error: {error}"]
    errors.extend(f"{label} {error}" for error in manifest_errors)
    run_path = root / "Run.json"
    if not run_path.is_file():
        errors.append(f"{label} is missing Run.json")
    else:
        try:
            run = load_json(run_path)
            expected_status = record.get("result", record.get("status"))
            if (run.get("story") != story or run.get("commit") != sha
                    or run.get("status") != expected_status
                    or run.get("exitCode") != record.get("exitCode")):
                errors.append(f"{label} Run.json does not match its summary")
        except (OSError, ValueError, TypeError):
            errors.append(f"{label} has invalid Run.json")
    log = root / "Logs/test.log"
    if not log.is_file() or log.stat().st_size == 0:
        errors.append(f"{label} is missing a nonempty test log")
    result = root / "Results/Story.xcresult"
    if not result.is_dir() or not (result / "Info.plist").is_file():
        errors.append(f"{label} is missing a complete result bundle")
    phase_evidence = parse_phases(root / "PhaseTimings.tsv", label, errors)
    phases = phase_evidence["durations"]
    statuses = phase_evidence["statuses"]
    entered = "test" in phases
    if record.get("testPhaseEntered") is not entered:
        errors.append(f"{label} testPhaseEntered disagrees with recorded phases")
    if statuses.get("test") != record.get("exitCode"):
        errors.append(f"{label} test phase exit disagrees with its summary")
    if record.get("result", record.get("status")) == "passed" \
            and any(value != 0 for value in statuses.values()):
        errors.append(f"{label} reports passed with a failed phase")
    return phase_evidence


def validate_story(root, canonical_root, expected_stories, sha, requested_attempts):
    errors, durations, signatures, failures = [], [], {}, []
    observed_artifacts = set()
    pairs = summary_pairs(root, "StoryLaneSummary.json", errors)
    lanes = [item.get("lane") for _, item in pairs]
    expected_lane_count = len(expected_stories)
    fragmented = len(pairs) > expected_lane_count \
        or any(item.get("requestedAttempts") == 1 for _, item in pairs)
    expected_summary_count = expected_lane_count * requested_attempts \
        if fragmented else expected_lane_count
    if any(not isinstance(lane, str) for lane in lanes):
        errors.append("story lane summaries contain an invalid lane identifier")
    if len(pairs) != expected_summary_count or len(
            set(lane for lane in lanes if isinstance(lane, str))) != expected_lane_count:
        errors.append(
            f"expected {expected_summary_count} story summaries across "
            f"{expected_lane_count} unique lanes, found {len(pairs)}")
    seen, seen_attempts = [], set()
    for path, lane in pairs:
        lane_root = path.parent
        lane_label = f"story lane {lane.get('lane')}"
        if lane.get("stage") != "story" or lane.get("commit") != sha:
            errors.append(f"story lane {lane.get('lane')} has the wrong stage or SHA")
        lane_attempt_count = 1 if fragmented else requested_attempts
        if lane.get("requestedAttempts") != lane_attempt_count:
            errors.append(f"story lane {lane.get('lane')} requested the wrong attempt count")
        if not lane.get("buildUnchanged") or lane.get("infrastructureInvalid"):
            errors.append(f"story lane {lane.get('lane')} failed source/build integrity")
        if lane.get("status") != "passed":
            errors.append(f"story lane {lane.get('lane')} is not green")
        lane_stories = list_field(lane, "stories", lane_label, errors)
        if len(lane_stories) != 1:
            errors.append(f"{lane_label} must contain exactly one canonical story")
        for story in lane_stories:
            if not isinstance(story, dict):
                errors.append(f"{lane_label} contains a non-object story")
                continue
            story_id = story.get("story")
            if not isinstance(story_id, str):
                errors.append(f"{lane_label} contains a story with an invalid identifier")
                continue
            seen.append(story_id)
            raw_attempts = list_field(story, "attempts", story_id, errors)
            if any(not isinstance(attempt, dict) for attempt in raw_attempts):
                errors.append(f"{story_id} contains a non-object attempt")
            attempts = [attempt for attempt in raw_attempts if isinstance(attempt, dict)]
            ids = [item.get("attempt") for item in attempts]
            if story.get("commit") != sha or story.get("requestedAttempts") != lane_attempt_count:
                errors.append(f"{story_id} has the wrong SHA or requested count")
            expected_ids = ids if fragmented else list(range(1, requested_attempts + 1))
            valid_fragment_id = len(ids) == 1 and type(ids[0]) is int \
                and 1 <= ids[0] <= requested_attempts
            if story.get("attemptCount") != lane_attempt_count \
                    or (fragmented and not valid_fragment_id) \
                    or (not fragmented and ids != expected_ids):
                errors.append(f"{story_id} does not contain the required attempt set")
            if story.get("passCount") != lane_attempt_count or story.get("failureCount") != 0:
                errors.append(f"{story_id} did not pass its requested attempts")
            for attempt in attempts:
                label = f"{story_id} attempt {attempt.get('attempt')}"
                attempt_id = attempt.get("attempt")
                if type(attempt_id) is int and attempt_id > 0:
                    attempt_key = (story_id, attempt_id)
                    if attempt_key in seen_attempts:
                        errors.append(f"{label} is duplicated across hosted summaries")
                    seen_attempts.add(attempt_key)
                    expected_artifact = f"Stories/{story_id}/attempt-{attempt_id:02d}"
                    require_canonical_artifact(
                        attempt, expected_artifact, observed_artifacts, label, errors)
                duration = validate_measured_record(attempt, "result", label, errors)
                if duration is not None:
                    durations.append(duration)
                signature = attempt.get("signature", "none")
                if signature != "none":
                    signatures[signature] = signatures.get(signature, 0) + 1
                    failures.append({"stage": "story", "lane": lane.get("lane"),
                                     "story": story_id, "attempt": attempt.get("attempt"),
                                     "signature": signature})
                if attempt.get("result") != "passed" or not attempt.get("testPhaseEntered"):
                    errors.append(f"{label} is not a measured pass")
                validate_attempt_evidence(
                    lane_root, canonical_root, attempt, story_id, sha, label, errors)
    expected_attempts = {
        (story, attempt) for story in expected_stories
        for attempt in range(1, requested_attempts + 1)
    }
    if fragmented:
        if seen_attempts != expected_attempts:
            errors.append("fragmented story coverage is not the complete story-attempt product")
    elif sorted(seen) != sorted(expected_stories) or len(seen) != len(set(seen)):
        errors.append("story lane coverage does not equal the canonical manifest exactly once")
    return {"lanes": len(pairs), "stories": len(set(seen)), "durations": distribution(durations),
            "signatures": signatures, "failures": failures, "errors": errors}


def validate_renderer(lane_root, matrix, index, expected_asset_count,
                      expected_width, expected_height, errors):
    renderer = matrix.get("appStoreRenderer", {})
    if not renderer.get("required") or renderer.get("status") != "passed" or renderer.get("exitCode") != 0:
        errors.append(f"logical matrix {index} does not contain a passing App Store renderer")
        return None
    root = evidence_path(lane_root, renderer.get("artifact"), f"matrix {index} renderer", errors)
    expected = renderer.get("expectedAssetCount")
    if root is None or expected != expected_asset_count:
        errors.append(f"matrix {index} renderer has invalid asset evidence")
        return None
    validate_integrity_manifest(root, f"matrix {index} renderer", errors)
    try:
        retained_summary = load_json(root / "AppStoreRendererSummary.json")
        if retained_summary != renderer:
            errors.append(f"matrix {index} renderer summary disagrees with its lane")
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        errors.append(f"matrix {index} renderer summary is invalid: {error}")
    pngs = list((root / "screenshots").glob("*.png")) if root.is_dir() else []
    if len(pngs) != expected or renderer.get("renderedAssetCount") != expected:
        errors.append(f"matrix {index} renderer did not produce exactly {expected} assets")
    renderer_log = root / "renderer.log"
    if not renderer_log.is_file() or renderer_log.stat().st_size == 0:
        errors.append(f"matrix {index} renderer log is missing or empty")
    for png in pngs:
        try:
            dimensions = png_dimensions(png)
        except (OSError, ValueError, struct.error) as error:
            errors.append(f"matrix {index} renderer has invalid {png.name}: {error}")
            continue
        if dimensions != (expected_width, expected_height):
            errors.append(
                f"matrix {index} renderer {png.name} has dimensions "
                f"{dimensions[0]}x{dimensions[1]}, expected {expected_width}x{expected_height}")
    return renderer.get("durationSeconds")


def validate_core(lane_root, gate, index, errors):
    root = evidence_path(lane_root, gate.get("artifact"), f"logical matrix {index} core", errors)
    if root is None or not root.is_dir():
        errors.append(f"logical matrix {index} core artifact directory is missing")
        return
    validate_integrity_manifest(root, f"logical matrix {index} core", errors)
    try:
        retained_summary = load_json(root / "CoreSummary.json")
        if retained_summary != gate:
            errors.append(f"logical matrix {index} core summary disagrees with its lane")
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        errors.append(f"logical matrix {index} core summary is invalid: {error}")
    for relative in ("Logs/fixtures.log", "Logs/tests.log"):
        path = root / relative
        if not path.is_file() or path.stat().st_size == 0:
            errors.append(f"logical matrix {index} core is missing nonempty {relative}")
    result = root / "Results/Core.xcresult/Info.plist"
    if not result.is_file():
        errors.append(f"logical matrix {index} core result bundle is incomplete")
    summary_path = root / "Results/CoreTestSummary.json"
    try:
        summary = load_json(summary_path)
    except (OSError, ValueError, TypeError, UnicodeError) as error:
        errors.append(f"logical matrix {index} core test summary is invalid: {error}")
        return
    total = summary.get("totalTestCount")
    if (summary.get("result") != "Passed" or not nonnegative_integer(total) or total == 0
            or summary.get("passedTests") != total or summary.get("failedTests") != 0
            or summary.get("skippedTests") != 0
            or summary.get("expectedFailures") != 0):
        errors.append(f"logical matrix {index} does not prove a fully passing PlayerTests run")


def validate_matrices(root, canonical_root, expected_stories, sha, requested_matrices,
                      baseline, build_summary):
    errors, durations, signatures, failures = [], [], {}, []
    observed_artifacts = set()
    story_values, phase_matrix_values, wall_values = defaultdict(list), defaultdict(list), []
    original = baseline["preRemediation"]
    reference = baseline["qualificationReference"]
    pairs = summary_pairs(root, "MatrixLaneSummary.json", errors)
    lanes = [item.get("lane") for _, item in pairs]
    fragmented = len(pairs) > 5 or any(
        item.get("requestedMatrices") == 1 for _, item in pairs
    )
    expected_summary_count = 5 * requested_matrices if fragmented else 5
    if any(not isinstance(lane, str) for lane in lanes):
        errors.append("matrix lane summaries contain an invalid lane identifier")
    if len(pairs) != expected_summary_count \
            or len(set(lane for lane in lanes if isinstance(lane, str))) != 5:
        errors.append(
            f"expected {expected_summary_count} matrix summaries across 5 unique lanes, "
            f"found {len(pairs)}")
    by_attempt = {index: [] for index in range(1, requested_matrices + 1)}
    seen_lane_attempts = set()
    for path, lane in pairs:
        lane_root = path.parent
        lane_label = f"matrix lane {lane.get('lane')}"
        if lane.get("stage") != "matrix" or lane.get("commit") != sha:
            errors.append(f"matrix lane {lane.get('lane')} has the wrong stage or SHA")
        lane_matrix_count = 1 if fragmented else requested_matrices
        if lane.get("requestedMatrices") != lane_matrix_count \
                or lane.get("matrixCount") != lane_matrix_count:
            errors.append(f"matrix lane {lane.get('lane')} has the wrong matrix count")
        if not lane.get("buildUnchanged") or lane.get("infrastructureInvalid") or lane.get("status") != "passed":
            errors.append(f"matrix lane {lane.get('lane')} failed integrity or is not green")
        raw_matrices = list_field(lane, "matrices", lane_label, errors)
        if any(not isinstance(item, dict) for item in raw_matrices):
            errors.append(f"{lane_label} contains a non-object matrix")
        lane_matrices = [item for item in raw_matrices if isinstance(item, dict)]
        indices = [item.get("matrixAttempt") for item in lane_matrices]
        valid_fragment_index = len(indices) == 1 and type(indices[0]) is int \
            and 1 <= indices[0] <= requested_matrices
        if (fragmented and not valid_fragment_index) \
                or (not fragmented and indices != list(range(1, requested_matrices + 1))):
            errors.append(f"matrix lane {lane.get('lane')} has noncontiguous matrix attempts")
        for matrix in lane_matrices:
            index = matrix.get("matrixAttempt")
            lane_attempt_key = (lane.get("lane"), index)
            if lane_attempt_key in seen_lane_attempts:
                errors.append(f"matrix lane {lane.get('lane')} attempt {index} is duplicated")
            seen_lane_attempts.add(lane_attempt_key)
            if index in by_attempt: by_attempt[index].append((lane_root, matrix))
            if matrix.get("commit") != sha or matrix.get("status") != "passed":
                errors.append(f"matrix {index} lane {lane.get('lane')} is not a measured pass")
            matrix_stories = list_field(matrix, "stories", f"matrix {index}", errors)
            matrix["stories"] = [story for story in matrix_stories
                                 if isinstance(story, dict)
                                 and isinstance(story.get("story"), str)]
            if not isinstance(matrix.get("core"), dict):
                errors.append(f"matrix {index} core must be an object")
                matrix["core"] = {}
            if not isinstance(matrix.get("appStoreRenderer"), dict):
                errors.append(f"matrix {index} appStoreRenderer must be an object")
                matrix["appStoreRenderer"] = {}
            for story in matrix_stories:
                if not isinstance(story, dict):
                    errors.append(f"matrix {index} contains a non-object story")
                    continue
                story_id = story.get("story")
                if not isinstance(story_id, str):
                    errors.append(f"matrix {index} contains a story with an invalid identifier")
                    continue
                label = f"matrix {index} story {story_id}"
                if type(index) is int and index > 0:
                    expected_artifact = f"Matrices/matrix-{index:02d}/Stories/{story_id}"
                    require_canonical_artifact(
                        story, expected_artifact, observed_artifacts, label, errors)
                duration = validate_measured_record(story, "status", label, errors)
                if duration is not None:
                    durations.append(duration)
                    if story_id in expected_stories:
                        story_values[story_id].append(duration)
                signature = story.get("signature", "none")
                if signature != "none":
                    signatures[signature] = signatures.get(signature, 0) + 1
                    failures.append({"stage": "matrix", "lane": lane.get("lane"),
                                     "story": story_id, "matrixAttempt": index,
                                     "signature": signature})
                if story.get("commit") != sha or story.get("status") != "passed" or not story.get("testPhaseEntered"):
                    errors.append(f"{label} is not a measured pass")
                story["_phases"] = validate_attempt_evidence(
                    lane_root, canonical_root, story, story_id, sha, label, errors)
    if fragmented:
        expected_lane_attempts = {
            (f"lane-{lane}", attempt) for lane in range(1, 6)
            for attempt in range(1, requested_matrices + 1)
        }
        if seen_lane_attempts != expected_lane_attempts:
            errors.append("fragmented matrix coverage is not the complete lane-attempt product")
    for index, matrices in by_attempt.items():
        stories = [story.get("story") for _, matrix in matrices for story in matrix.get("stories", [])]
        if len(matrices) != 5 or sorted(stories) != sorted(expected_stories) or len(stories) != len(set(stories)):
            errors.append(f"logical matrix {index} does not contain five lanes and every story exactly once")
        core = [matrix.get("core", {}) for _, matrix in matrices if matrix.get("core", {}).get("required")]
        if len(core) != 1:
            errors.append(f"logical matrix {index} does not contain exactly one core gate")
        else:
            core_lane_root = next(lane_root for lane_root, matrix in matrices
                                  if matrix.get("core", {}).get("required"))
            gate = core[0]
            require_canonical_artifact(
                gate, f"Matrices/matrix-{index:02d}/Core", observed_artifacts,
                f"logical matrix {index} core", errors)
            signature = gate.get("signature", "none")
            fixture_exit = gate.get("fixtureExitCode")
            fixture_log_exit = gate.get("fixtureLogExitCode")
            failed_fixture = gate.get("failedFixture")
            test_ran = gate.get("testRan")
            test_exit = gate.get("testExitCode")
            test_log_exit = gate.get("testLogExitCode")
            result_summary_exit = gate.get("resultSummaryExitCode")
            cleanup_exit = gate.get("cleanupExitCode")
            if (not nonnegative_integer(fixture_exit)
                    or not nonnegative_integer(fixture_log_exit)
                    or type(test_ran) is not bool
                    or (test_ran and not nonnegative_integer(test_exit))
                    or (not test_ran and test_exit is not None)
                    or not nonnegative_integer(test_log_exit)
                    or not nonnegative_integer(result_summary_exit)
                    or not nonnegative_integer(cleanup_exit)):
                errors.append(f"logical matrix {index} core gate has invalid exit codes")
            if fixture_exit != 0 and (test_ran or test_exit is not None):
                errors.append(f"logical matrix {index} core tests ran after a fixture failure")
            if fixture_exit != 0 and (not isinstance(failed_fixture, str) or not failed_fixture):
                errors.append(f"logical matrix {index} fixture failure has no command identity")
            if fixture_exit == 0 and failed_fixture is not None:
                errors.append(f"logical matrix {index} passing fixtures report a failed command")
            commands_passed = (fixture_exit == 0 and fixture_log_exit == 0
                               and test_ran is True and test_exit == 0
                               and test_log_exit == 0 and result_summary_exit == 0
                               and cleanup_exit == 0)
            if gate.get("status") != "passed":
                errors.append(f"logical matrix {index} core gate is not green")
                if commands_passed:
                    errors.append(f"logical matrix {index} failed core gate reports successful commands")
                if not isinstance(signature, str) or signature == "none":
                    errors.append(f"logical matrix {index} core failure has no signature")
                else:
                    signatures[signature] = signatures.get(signature, 0) + 1
                    failures.append({"stage": "matrix", "lane": "core", "story": "core",
                                     "matrixAttempt": index, "signature": signature})
            else:
                if not commands_passed:
                    errors.append(f"logical matrix {index} passing core gate masks a command failure")
                if signature != "none":
                    errors.append(f"logical matrix {index} passing core gate has a failure signature")
            validate_core(core_lane_root, gate, index, errors)
            for key, phase in (("fixtureDurationSeconds", "core-fixtures"),
                               ("testDurationSeconds", "core-tests")):
                value = gate.get(key)
                if not nonnegative_integer(value):
                    errors.append(f"logical matrix {index} has invalid {phase} timing")
                elif phase != "core-tests" or test_ran:
                    phase_matrix_values[phase].append(value)
        renderers = [(lane_root, matrix) for lane_root, matrix in matrices
                     if matrix.get("appStoreRenderer", {}).get("required")]
        if len(renderers) != 1:
            errors.append(f"logical matrix {index} does not contain exactly one required App Store renderer")
        else:
            require_canonical_artifact(
                renderers[0][1]["appStoreRenderer"],
                f"Matrices/matrix-{index:02d}/AppStoreListing", observed_artifacts,
                f"logical matrix {index} renderer", errors)
            if not any(story.get("story") == "013-app-store-listing"
                       for story in renderers[0][1].get("stories", [])):
                errors.append(f"logical matrix {index} renderer is not attached to Story 013")
            value = validate_renderer(renderers[0][0], renderers[0][1], index,
                                      baseline["appStoreAssetCount"],
                                      baseline["appStorePixelWidth"],
                                      baseline["appStorePixelHeight"], errors)
            if nonnegative_integer(value):
                phase_matrix_values["app-store-renderer"].append(value)
            else:
                errors.append(f"logical matrix {index} has invalid app-store-renderer timing")
        lane_durations = [matrix.get("durationSeconds") for _, matrix in matrices]
        if len(lane_durations) != 5 or any(not nonnegative_integer(value) for value in lane_durations):
            errors.append(f"logical matrix {index} has invalid lane wall-clock timings")
        else:
            # The shared build is a predecessor of every matrix lane. Count it
            # once on the critical path rather than demanding a stale build row
            # from one arbitrary story.
            wall_values.append(max(lane_durations) + build_summary["durationSeconds"])
        phase_matrix_values["build"].append(build_summary["durationSeconds"])
        phase_totals = defaultdict(int)
        observed_phases = set()
        for _, matrix in matrices:
            for story in matrix.get("stories", []):
                phase_evidence = story.pop("_phases", {})
                for phase, value in phase_evidence.get("durations", {}).items():
                    observed_phases.add(phase)
                    phase_totals[phase] += value
        unexpected_phases = observed_phases - STORY_PHASES
        if unexpected_phases:
            errors.append(
                f"logical matrix {index} records unreferenced phases: "
                + ", ".join(sorted(unexpected_phases)))
        missing_phases = STORY_PHASES - observed_phases
        if missing_phases:
            errors.append(
                f"logical matrix {index} is missing required phases: "
                + ", ".join(sorted(missing_phases)))
        # Explicit zero-duration reuse rows are evidence. An absent row is not.
        for phase in STORY_PHASES & observed_phases:
            phase_matrix_values[phase].append(phase_totals[phase])

    thresholds = baseline["thresholds"]
    suite_baseline = reference["suite"]["logicalWallSeconds"]
    wall_distribution = distribution(wall_values)
    suite_delta = None if wall_distribution["median"] is None else wall_distribution["median"] / suite_baseline - 1
    if suite_delta is not None and suite_delta > thresholds["suiteRegression"]:
        errors.append(f"logical matrix wall-clock regressed {suite_delta:.1%}; limit is {thresholds['suiteRegression']:.0%}")
    story_timings = {}
    for story in expected_stories:
        values = story_values[story]
        stats = distribution(values)
        expected = reference["stories"][story]
        delta = None if stats["median"] is None else stats["median"] / expected - 1
        story_timings[story] = {
            "preRemediationSeconds": original["stories"][story],
            "referenceSeconds": expected,
            "current": stats,
            "delta": delta,
        }
        if len(values) != requested_matrices:
            errors.append(f"{story} does not contain {requested_matrices} timing samples")
        if delta is not None and delta > thresholds["storyRegression"]:
            errors.append(f"{story} regressed {delta:.1%}; limit is {thresholds['storyRegression']:.0%}")
    phase_timings = {}
    for phase, expected in reference["phases"].items():
        stats = distribution(phase_matrix_values.get(phase, []))
        if stats["count"] != requested_matrices:
            errors.append(f"phase {phase} does not contain {requested_matrices} timing samples")
        delta = None if stats["median"] is None or expected == 0 else stats["median"] / expected - 1
        phase_timings[phase] = {
            "preRemediationSeconds": original["phases"][phase],
            "referenceSeconds": expected,
            "current": stats,
            "delta": delta,
        }
    return {"lanes": len(pairs), "matrices": requested_matrices, "durations": distribution(durations),
            "logicalWallClock": {
                "preRemediationSeconds": original["suite"]["logicalWallSeconds"],
                "referenceSeconds": suite_baseline,
                "current": wall_distribution,
                "delta": suite_delta,
            },
            "storyTimings": story_timings, "phaseTimings": phase_timings,
            "signatures": signatures, "failures": failures, "errors": errors}


def validate_baseline(path, expected_stories):
    baseline = load_json(path)
    if baseline.get("schemaVersion") != 2:
        raise ValueError("runtime baseline must use schema version 2")
    original = baseline.get("preRemediation", {})
    reference = baseline.get("qualificationReference", {})
    if any(set(item.get("stories", {})) != set(expected_stories)
           for item in (original, reference)):
        raise ValueError("runtime baseline does not match canonical stories")
    if (set(original.get("phases", {})) != REQUIRED_PHASES
            or set(reference.get("phases", {})) != REQUIRED_PHASES):
        raise ValueError("runtime references must contain the exact required phase set")
    for label, item in (("pre-remediation", original), ("qualification", reference)):
        source = item.get("source", {})
        source_text = (source.get("url"), source.get("headCommit"),
                       source.get("checkoutCommit"), source.get("runner"),
                       source.get("xcode"), source.get("runtime"))
        if (not isinstance(source.get("workflowRun"), int) or source["workflowRun"] <= 0
                or any(not isinstance(value, str) or not value for value in source_text)
                or any(re.fullmatch(r"[0-9a-f]{40}", source[key]) is None
                       for key in ("headCommit", "checkoutCommit"))):
            raise ValueError(f"{label} runtime reference requires exact CI provenance")
    coverage = reference.get("coverageAdjustment", {})
    if (not isinstance(coverage.get("reason"), str) or not coverage["reason"]
            or not isinstance(coverage.get("approvedBy"), str) or not coverage["approvedBy"]
            or coverage.get("remediationItems") != [f"R{index}" for index in range(17)]):
        raise ValueError("qualification reference requires an explicit coverage adjustment")
    required = [baseline.get("appStoreAssetCount"), baseline.get("appStorePixelWidth"),
                baseline.get("appStorePixelHeight")]
    for item in (original, reference):
        required += [item.get("suite", {}).get("logicalWallSeconds"), *item["stories"].values()]
    thresholds = baseline.get("thresholds", {})
    if any(not finite_number(value, 0) or value == 0 for value in required):
        raise ValueError("runtime baseline values must be positive")
    if any(value is not None and not finite_number(value, 0)
           for value in original.get("phases", {}).values()):
        raise ValueError("pre-remediation phase values must be nonnegative or null when unmeasured")
    if any(not finite_number(value, 0)
           for value in reference.get("phases", {}).values()):
        raise ValueError("qualification phase reference values must be nonnegative")
    if thresholds.get("suiteRegression") != 0.10 or thresholds.get("storyRegression") != 0.20:
        raise ValueError("runtime baseline must enforce 10% suite and 20% story limits")
    return baseline


def validate_failure_history(path, expected_stories):
    history = load_json(path)
    entries = history.get("entries")
    if history.get("schemaVersion") != 1 or not isinstance(entries, list):
        raise ValueError("failure history must use schema version 1")
    signatures = set()
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("fix"), dict) \
                or not isinstance(entry.get("evidence"), dict):
            raise ValueError("failure history entries must be objects")
        required_text = (entry.get("signature"), entry.get("story"), entry.get("rootCause"),
                         entry.get("resetEvidence"), entry.get("fix", {}).get("summary"),
                         entry.get("fix", {}).get("validation"), entry.get("evidence", {}).get("url"),
                         entry.get("evidence", {}).get("observation"))
        commits = entry.get("fix", {}).get("commits")
        reset_count = entry.get("qualificationResetCount")
        if any(not isinstance(value, str) or not value for value in required_text):
            raise ValueError("failure history entries require signature, evidence, cause, fix, and reset evidence")
        if entry["story"] not in {*expected_stories, "core"} or entry["signature"] in signatures:
            raise ValueError("failure history stories and signatures must be canonical and unique")
        if not isinstance(commits, list) or not commits or any(
                not isinstance(commit, str)
                or re.fullmatch(r"[0-9a-f]{40}", commit) is None for commit in commits):
            raise ValueError("failure history fixes require full commit SHAs")
        if not isinstance(reset_count, int) or reset_count < 0:
            raise ValueError("failure history reset counts must be nonnegative")
        if entry.get("diagnosisStatus") not in ("confirmed", "supported-hypothesis"):
            raise ValueError("failure history diagnosis status must be explicit")
        if entry.get("fix", {}).get("status") not in ("verified", "pending-focused-validation"):
            raise ValueError("failure history fix validation status must be explicit")
        signatures.add(entry["signature"])
    return history


def build_failure_accounting(history, story, matrices):
    historical = history["entries"]
    pending_history = [entry for entry in historical
                       if entry["diagnosisStatus"] != "confirmed"
                       or entry["fix"]["status"] != "verified"]
    known = {entry["signature"]: entry for entry in historical}
    failures = list(story["failures"])
    if matrices is not None: failures += matrices["failures"]
    grouped = defaultdict(list)
    for failure in failures: grouped[failure["signature"]].append(failure)
    observed, unexplained = [], 0
    for signature, occurrences in sorted(grouped.items()):
        prior = known.get(signature)
        if prior is None:
            classification = "unexplained"
            root_cause = None
            fix = None
        else:
            classification = "historical-signature-recurrence-unconfirmed"
            root_cause = prior["rootCause"]
            fix = prior["fix"]
        # A matching string is evidence of the same symptom, not proof that the
        # historical cause recurred. Every qualification failure remains
        # unexplained until its retained artifacts independently support a cause.
        unexplained += len(occurrences)
        observed.append({"signature": signature, "classification": classification,
                         "occurrenceCount": len(occurrences), "occurrences": occurrences,
                         "historicalRootCause": root_cause, "historicalFix": fix,
                         "qualificationResetCount": len(occurrences),
                         "resetEvidence": "Each listed failed measurement invalidates the affected consecutive-pass count."})
    return {"historical": historical, "pendingHistorical": pending_history,
            "observed": observed,
            "unexplainedFailureCount": unexplained,
            "rootCauseAccountingComplete": unexplained == 0 and not pending_history}


def render_report(output: Path, sha: str, story, matrices, failure_accounting):
    all_errors = story["errors"] + ([] if matrices is None else matrices["errors"])
    payload = {"commit": sha, "status": "passed" if not all_errors else "failed",
               "storyQualification": story, "matrixQualification": matrices,
               "failureAccounting": failure_accounting, "errors": all_errors}
    output.mkdir(parents=True, exist_ok=True)
    (output / "QualificationSummary.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    lines = ["# R0 E2E stability report", "", f"- Commit: `{sha}`", f"- Result: **{payload['status'].upper()}**",
             f"- Story gate: {story['stories']} stories; {story['durations']['count']} attempts"]
    if matrices is not None:
        wall = matrices["logicalWallClock"]
        wall_change = "n/a" if wall["delta"] is None else f"{wall['delta']:.1%}"
        lines += [f"- Matrix gate: {matrices['matrices']} logical complete matrices", "", "## Runtime regression gates", "",
                  "The enforced reference includes the separately measured, approved coverage added during remediation; the pre-remediation measurement remains visible for an honest end-to-end comparison.",
                  "", "| Scope | Pre-remediation (s) | Expanded-coverage reference (s) | Current median (s) | Change vs reference | Limit |",
                  "|---|---:|---:|---:|---:|---:|",
                  f"| Complete matrix wall | {wall['preRemediationSeconds']} | {wall['referenceSeconds']} | {wall['current']['median']} | {wall_change} | 10% |"]
        for name, timing in matrices["storyTimings"].items():
            change = "n/a" if timing["delta"] is None else f"{timing['delta']:.1%}"
            lines.append(f"| `{name}` | {timing['preRemediationSeconds']} | {timing['referenceSeconds']} | {timing['current']['median']} | {change} | 20% |")
        lines += ["", "## Phase timing", "", "| Phase | Pre-remediation (s) | Expanded-coverage reference (s) | Current median (s) | Change vs reference |", "|---|---:|---:|---:|---:|"]
        for name, timing in matrices["phaseTimings"].items():
            change = "n/a" if timing["delta"] is None else f"{timing['delta']:.1%}"
            original = "n/a" if timing["preRemediationSeconds"] is None else timing["preRemediationSeconds"]
            lines.append(f"| `{name}` | {original} | {timing['referenceSeconds']} | {timing['current']['median']} | {change} |")
    lines += ["", "## Failure signatures", ""]
    signatures = dict(story["signatures"])
    if matrices:
        for key, value in matrices["signatures"].items(): signatures[key] = signatures.get(key, 0) + value
    lines += [f"- `{key}`: {value}" for key, value in sorted(signatures.items())] or ["- None"]
    lines += ["", "## Root-cause and qualification-reset accounting", "",
              "### Historical failures", "",
              "| Signature | Diagnosis | Root cause | Fix | Qualification resets | Reset evidence |",
              "|---|---|---|---|---:|---|"]
    for entry in failure_accounting["historical"]:
        commits = ", ".join(f"`{commit[:7]}`" for commit in entry["fix"]["commits"])
        lines.append(f"| `{entry['signature']}` | {entry['diagnosisStatus']} | {entry['rootCause']} | {entry['fix']['summary']} ({commits}; {entry['fix']['status']}) | {entry['qualificationResetCount']} | {entry['resetEvidence']} |")
    lines += ["", "### Failures observed in this qualification", ""]
    if failure_accounting["observed"]:
        lines += ["| Signature | Occurrences | Classification | Count resets |",
                  "|---|---:|---|---:|"]
        for entry in failure_accounting["observed"]:
            lines.append(f"| `{entry['signature']}` | {entry['occurrenceCount']} | {entry['classification']} | {entry['qualificationResetCount']} |")
    else:
        lines.append("- None; no qualifying count was reset.")
    if failure_accounting["pendingHistorical"]:
        lines += ["", "### Pending historical validation", ""]
        lines += [f"- `{entry['signature']}`: {entry['fix']['validation']}"
                  for entry in failure_accounting["pendingHistorical"]]
    lines += ["", "## Validation errors", ""]
    lines += [f"- {error}" for error in all_errors] or ["- None"]
    (output / "STABILITY_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0 if not all_errors else 1


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--story-input", type=Path, required=True)
    parser.add_argument("--matrix-input", type=Path)
    parser.add_argument("--build-summary", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--sampling-plan", type=Path)
    parser.add_argument("--runtime-baseline", type=Path,
                        default=Path(__file__).with_name("r0_runtime_baseline.json"))
    parser.add_argument("--failure-history", type=Path,
                        default=Path(__file__).with_name("r0_failure_history.json"))
    parser.add_argument("--sha", required=True)
    parser.add_argument("--story-attempts", type=int, default=10)
    parser.add_argument("--matrix-attempts", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        stories = canonical_stories(args.manifest)
        if (not isinstance(stories, list) or not stories
                or any(not isinstance(story, str) or not story for story in stories)
                or len(stories) != len(set(stories))):
            raise ValueError("canonical manifest must contain unique story identifiers")
        baseline = validate_baseline(args.runtime_baseline, stories)
        failure_history = validate_failure_history(args.failure_history, stories)
        sampling_plan = None
        build_summary = None
        qualified_stories = stories
        if args.sampling_plan is not None:
            sampling_plan = validate_sampling_plan(args.sampling_plan, stories)
            qualified_stories = sampling_plan["targetStories"]
            if args.story_attempts != sampling_plan["storyAttempts"]:
                raise ValueError("requested story attempts disagree with the sampling plan")
            if (args.matrix_input is not None
                    and args.matrix_attempts != sampling_plan["fullMatrixAttempts"]):
                raise ValueError("requested matrix attempts disagree with the sampling plan")
        if args.matrix_input is not None:
            if args.build_summary is None:
                raise ValueError("matrix qualification requires shared-build timing evidence")
            build_summary = validate_build_summary(args.build_summary, args.sha)
        elif args.build_summary is not None:
            raise ValueError("shared-build timing evidence requires matrix qualification")
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
        print(f"Invalid qualification contract: {error}", file=sys.stderr)
        return 2
    canonical_root = args.manifest.parent
    story_result = validate_story(
        args.story_input, canonical_root, qualified_stories, args.sha, args.story_attempts)
    story_result["samplingPlan"] = sampling_plan
    matrix_result = None
    if args.matrix_input is not None:
        matrix_result = validate_matrices(
            args.matrix_input, canonical_root, stories, args.sha, args.matrix_attempts,
            baseline, build_summary)
    failure_accounting = build_failure_accounting(failure_history, story_result, matrix_result)
    if not failure_accounting["rootCauseAccountingComplete"]:
        story_result["errors"].append(
            "root-cause accounting is incomplete; resolve current failures and pending historical validation")
    return render_report(args.output, args.sha, story_result, matrix_result, failure_accounting)


if __name__ == "__main__":
    sys.exit(main())
