#!/usr/bin/env python3
"""Create and verify a complete, content-addressed E2E attempt manifest."""

import argparse
import hashlib
import json
import math
import os
import re
import stat
import struct
import sys
import tempfile
import zlib
from pathlib import Path, PurePosixPath


MANIFEST_NAME = "EvidenceManifest.json"
REQUIRED_FILES = (
    "Run.json",
    "PhaseTimings.tsv",
    "Logs/test.log",
    "Results/Story.xcresult/Info.plist",
    "Attachments/manifest.json",
    "Diagnostics/ScreenshotComparison/summary.json",
)
FAILURE_DIAGNOSTICS = (
    "Diagnostics/FailureEvidence.json",
    "Diagnostics/failure-screen.png",
    "Diagnostics/failure-screen-source.json",
    "Diagnostics/player.log",
    "Diagnostics/simulator-system.log",
    "Diagnostics/coresimulator-host.log",
    "Diagnostics/simulators.json",
    "Diagnostics/semantic-probes.log",
    "Diagnostics/xcresult-diagnostics-export.log",
)
PASSING_COMPARISON_RESULTS = {"exact", "canonical"}
FAILURE_SCREENSHOT_NAME = re.compile(
    r"xctest-failure-screen_[0-9]+_"
    r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.png"
)


def load_json(path: Path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def safe_relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and ".." not in path.parts and "." not in path.parts


def sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_regular_files(root: Path):
    errors = []
    files = []
    excluded = []
    if not root.is_dir() or root.is_symlink():
        return [], [], ["attempt root is missing, not a directory, or is a symlink"]
    for current, directory_names, file_names in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        if current_path == root and "Build" in directory_names:
            build = root / "Build"
            directory_names.remove("Build")
            if build.is_symlink():
                errors.append("retained evidence contains symlink Build")
            else:
                excluded.append({
                    "path": "Build",
                    "reason": "ephemeral build products are verified by the E2E build-provenance contract",
                })
        for name in list(directory_names):
            path = current_path / name
            if path.is_symlink():
                relative = path.relative_to(root).as_posix()
                errors.append(f"retained evidence contains symlink {relative}")
                directory_names.remove(name)
        for name in file_names:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            try:
                mode = path.lstat().st_mode
            except OSError as error:
                errors.append(f"cannot inspect retained path {relative}: {error}")
                continue
            if stat.S_ISLNK(mode):
                errors.append(f"retained evidence contains symlink {relative}")
                continue
            if not stat.S_ISREG(mode):
                errors.append(f"retained evidence contains non-regular path {relative}")
                continue
            if relative == MANIFEST_NAME:
                continue
            files.append({"path": relative, "bytes": path.stat().st_size, "sha256": sha256(path)})
    files.sort(key=lambda item: item["path"])
    return files, excluded, errors


def canonical_screenshots(story_root: Path, expected_story=None):
    errors = []
    try:
        descriptor = load_json(story_root / "story.json")
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        return [], [f"canonical story descriptor is invalid: {error}"]
    story = descriptor.get("id")
    names = descriptor.get("screenshots")
    if expected_story is not None and story != expected_story:
        errors.append("canonical story identity does not match the attempt")
    if not isinstance(names, list) or not names:
        return [], errors + ["canonical screenshot list is missing or empty"]
    if any(
        not isinstance(name, str)
        or not name.endswith(".png")
        or PurePosixPath(name).name != name
        or not safe_relative_path(name)
        for name in names
    ):
        errors.append("canonical screenshot list contains an unsafe or invalid name")
    if names != sorted(set(names)):
        errors.append("canonical screenshot names are not sorted and unique")
    screenshot_root = story_root / "screenshots" / "ios"
    actual = sorted(path.name for path in screenshot_root.glob("*.png") if path.is_file())
    if actual != names:
        errors.append("canonical story descriptor and baseline screenshot files disagree")
    return names, errors


def parse_phases(path: Path):
    errors = []
    rows = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        return rows, [f"PhaseTimings.tsv is unreadable: {error}"]
    if not lines:
        return rows, ["PhaseTimings.tsv is empty"]
    seen = set()
    for index, line in enumerate(lines, 1):
        fields = line.split("\t")
        if len(fields) != 4:
            errors.append(f"PhaseTimings.tsv row {index} is malformed")
            continue
        phase, start, end, exit_code = fields
        try:
            start_value, end_value, exit_value = int(start), int(end), int(exit_code)
        except ValueError:
            errors.append(f"PhaseTimings.tsv row {index} is nonnumeric")
            continue
        if not phase or start_value < 0 or end_value < start_value:
            errors.append(f"PhaseTimings.tsv row {index} is invalid")
            continue
        if phase in seen:
            errors.append(f"PhaseTimings.tsv records {phase} more than once")
        seen.add(phase)
        rows.append((phase, exit_value))
    return rows, errors


def require_nonempty(root: Path, relative: str, errors):
    path = root / relative
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        errors.append(f"required evidence is missing or empty: {relative}")
        return False
    return True


def png_dimensions(path: Path):
    try:
        if not path.is_file() or path.is_symlink():
            return None
        payload = path.read_bytes()
    except OSError:
        return None
    try:
        if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
            return None
        offset, header, ended, saw_idat = 8, None, False, False
        compressed = bytearray()
        while offset + 12 <= len(payload):
            length = struct.unpack(">I", payload[offset:offset + 4])[0]
            chunk_type = payload[offset + 4:offset + 8]
            end = offset + 12 + length
            if end > len(payload):
                return None
            data = payload[offset + 8:offset + 8 + length]
            checksum = struct.unpack(">I", payload[offset + 8 + length:end])[0]
            if zlib.crc32(chunk_type + data) & 0xffffffff != checksum:
                return None
            if offset == 8:
                if chunk_type != b"IHDR" or length != 13:
                    return None
                header = struct.unpack(">IIBBBBB", data)
            elif chunk_type == b"IHDR":
                return None
            if chunk_type == b"IDAT":
                saw_idat = True
                compressed.extend(data)
            if chunk_type == b"IEND":
                if length != 0 or end != len(payload):
                    return None
                ended = True
                break
            offset = end
        if not ended or not saw_idat or header is None:
            return None
        width, height, bit_depth, color_type, compression, filtering, interlace = header
        legal_depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8},
                        4: {8, 16}, 6: {8, 16}}
        channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
        if width <= 0 or height <= 0 or bit_depth not in legal_depths.get(color_type, set()) \
                or compression != 0 or filtering != 0 or interlace not in (0, 1):
            return None
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
        return (width, height) if len(zlib.decompress(bytes(compressed))) == expected_bytes else None
    except (struct.error, zlib.error):
        return None


def screen_recording_candidates(root: Path, attachments, errors):
    candidates = []
    if not isinstance(attachments, list):
        return candidates
    for group in attachments:
        if not isinstance(group, dict):
            continue
        test_identifier = group.get("testIdentifier")
        for attachment in group.get("attachments", []):
            if not isinstance(attachment, dict):
                continue
            human_name = attachment.get("suggestedHumanReadableName")
            if not isinstance(human_name, str) or not human_name.startswith("Screen Recording ") \
                    or not human_name.endswith(".mp4"):
                continue
            name = attachment.get("exportedFileName")
            timestamp = attachment.get("timestamp")
            if not safe_relative_path(name) or PurePosixPath(name).name != name \
                    or not name.lower().endswith(".mp4"):
                errors.append("XCTest screen recording has an unsafe exported filename")
                continue
            if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool) \
                    or not math.isfinite(timestamp):
                errors.append("XCTest screen recording has an invalid timestamp")
                continue
            path = root / "Attachments" / name
            if path.is_file() and not path.is_symlink() and path.stat().st_size > 0:
                try:
                    with path.open("rb") as handle:
                        header = handle.read(12)
                except OSError:
                    header = b""
                candidates.append({
                    "attachment": f"Attachments/{name}",
                    "testIdentifier": test_identifier,
                    "attachmentTimestamp": timestamp,
                    "validContainer": len(header) == 12 and header[4:8] == b"ftyp",
                })
    return candidates


def failure_screenshot_candidates(root: Path, attachments, errors):
    candidates = []
    if not isinstance(attachments, list):
        return candidates
    for group in attachments:
        if not isinstance(group, dict):
            continue
        test_identifier = group.get("testIdentifier")
        for attachment in group.get("attachments", []):
            if not isinstance(attachment, dict):
                continue
            suggested_name = attachment.get("suggestedHumanReadableName")
            if not isinstance(suggested_name, str) or not (
                    suggested_name == "xctest-failure-screen.png"
                    or FAILURE_SCREENSHOT_NAME.fullmatch(suggested_name)):
                continue
            name = attachment.get("exportedFileName")
            timestamp = attachment.get("timestamp")
            if not safe_relative_path(name) or PurePosixPath(name).name != name \
                    or not name.lower().endswith(".png"):
                errors.append("XCTest failure screenshot has an unsafe exported filename")
                continue
            if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool) \
                    or not math.isfinite(timestamp):
                errors.append("XCTest failure screenshot has an invalid timestamp")
                continue
            path = root / "Attachments" / name
            if path.is_file() and not path.is_symlink() and path.stat().st_size > 0:
                candidates.append({
                    "attachment": f"Attachments/{name}",
                    "testIdentifier": test_identifier,
                    "attachmentTimestamp": timestamp,
                    "dimensions": png_dimensions(path),
                    "sha256": sha256(path),
                })
    return candidates


def validate_failure_screen(root: Path, failure, attachments, errors):
    png_path = root / "Diagnostics" / "failure-screen.png"
    dimensions = png_dimensions(png_path)
    if dimensions is None:
        errors.append("Diagnostics/failure-screen.png is not a valid nonempty PNG with IHDR dimensions")
    try:
        source = load_json(root / "Diagnostics" / "failure-screen-source.json")
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        errors.append(f"failure-screen-source.json is invalid: {error}")
        return
    if not isinstance(source, dict):
        errors.append("failure-screen-source.json is not an object")
        return
    if not isinstance(failure, dict) or failure.get("failureScreen") != source:
        errors.append("FailureEvidence.json does not exactly bind failure-screen provenance")
    common = {"schemaVersion", "artifact", "source", "pixelWidth", "pixelHeight"}
    retained_screenshots = failure_screenshot_candidates(root, attachments, errors)
    if source.get("source") != "xctest-failure-screenshot" and retained_screenshots:
        errors.append(
            "failure-screen provenance ignored an available retained XCTest failure screenshot"
        )
    if source.get("schemaVersion") != 1 \
            or source.get("artifact") != "Diagnostics/failure-screen.png":
        errors.append("failure-screen provenance has an invalid schema or artifact")
    width, height = source.get("pixelWidth"), source.get("pixelHeight")
    if not isinstance(width, int) or isinstance(width, bool) or width <= 0 \
            or not isinstance(height, int) or isinstance(height, bool) or height <= 0 \
            or dimensions != (width, height):
        errors.append("failure-screen provenance dimensions do not match the PNG")

    if source.get("source") == "live-simulator":
        if set(source) != common | {"simulatorId"}:
            errors.append("live-simulator failure-screen provenance has unexpected fields")
        simulator_id = source.get("simulatorId")
        if not isinstance(simulator_id, str) or re.fullmatch(
            r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            simulator_id,
        ) is None:
            errors.append("live-simulator failure-screen provenance has an invalid simulator UDID")
        return

    if source.get("source") == "xctest-failure-screenshot":
        screenshot_fields = {"attachment", "testIdentifier", "attachmentTimestamp"}
        if set(source) != common | screenshot_fields:
            errors.append("XCTest failure-screenshot provenance has unexpected fields")
        attachment = source.get("attachment")
        test_identifier = source.get("testIdentifier")
        timestamp = source.get("attachmentTimestamp")
        if not safe_relative_path(attachment) or not attachment.startswith("Attachments/") \
                or PurePosixPath(attachment).parent != PurePosixPath("Attachments"):
            errors.append("failure-screen provenance has an unsafe attachment path")
        if not isinstance(test_identifier, str) or not test_identifier:
            errors.append("failure-screen provenance has an invalid test identifier")
        if not isinstance(timestamp, (int, float)) or isinstance(timestamp, bool) \
                or not math.isfinite(timestamp):
            errors.append("failure-screen provenance has an invalid attachment timestamp")
        candidates = retained_screenshots
        if not candidates:
            errors.append("failure-screen provenance has no nonempty XCTest failure screenshot")
            return
        newest_timestamp = max(item["attachmentTimestamp"] for item in candidates)
        newest = [
            item for item in candidates if item["attachmentTimestamp"] == newest_timestamp
        ]
        selected = {
            "attachment": attachment,
            "testIdentifier": test_identifier,
            "attachmentTimestamp": timestamp,
        }
        if len(newest) != 1 or {
            key: newest[0].get(key) for key in selected
        } != selected:
            errors.append(
                "failure-screen provenance is not the unique newest nonempty XCTest failure screenshot"
            )
        elif newest[0].get("dimensions") != dimensions:
            errors.append(
                "failure-screen provenance references a corrupt or dimension-mismatched XCTest screenshot"
            )
        elif newest[0].get("sha256") != sha256(png_path):
            errors.append(
                "failure-screen provenance does not retain the exact XCTest screenshot bytes"
            )
        return

    if source.get("source") != "xctest-screen-recording":
        errors.append("failure-screen provenance has an unknown source")
        return
    recording_fields = {
        "attachment", "testIdentifier", "attachmentTimestamp",
        "requestedTimeSeconds", "actualTimeSeconds",
    }
    if set(source) != common | recording_fields:
        errors.append("XCTest recording failure-screen provenance has unexpected fields")
    attachment = source.get("attachment")
    test_identifier = source.get("testIdentifier")
    timestamp = source.get("attachmentTimestamp")
    requested = source.get("requestedTimeSeconds")
    actual = source.get("actualTimeSeconds")
    if not safe_relative_path(attachment) or not attachment.startswith("Attachments/") \
            or PurePosixPath(attachment).parent != PurePosixPath("Attachments"):
        errors.append("failure-screen provenance has an unsafe attachment path")
    if not isinstance(test_identifier, str) or not test_identifier:
        errors.append("failure-screen provenance has an invalid test identifier")
    for label, value in (("attachment timestamp", timestamp), ("requested time", requested),
                         ("actual time", actual)):
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            errors.append(f"failure-screen provenance has an invalid {label}")
    if isinstance(requested, (int, float)) and not isinstance(requested, bool) and requested <= 0:
        errors.append("failure-screen provenance requested time is not positive")
    if isinstance(actual, (int, float)) and not isinstance(actual, bool) \
            and isinstance(requested, (int, float)) and not isinstance(requested, bool) \
            and (actual < 0 or actual > requested):
        errors.append("failure-screen provenance actual time is outside the recording")

    candidates = screen_recording_candidates(root, attachments, errors)
    if not candidates:
        errors.append("failure-screen provenance has no nonempty XCTest recording candidate")
        return
    newest_timestamp = max(item["attachmentTimestamp"] for item in candidates)
    newest = [item for item in candidates if item["attachmentTimestamp"] == newest_timestamp]
    selected = {
        "attachment": attachment,
        "testIdentifier": test_identifier,
        "attachmentTimestamp": timestamp,
    }
    if len(newest) != 1 or {
        key: newest[0].get(key) for key in selected
    } != selected:
        errors.append("failure-screen provenance is not the unique newest nonempty XCTest recording")
    elif newest[0].get("validContainer") is not True:
        errors.append("failure-screen provenance references a corrupt XCTest recording container")


def validate_comparison(root: Path, canonical, run_status, errors):
    details = {
        "canonicalNames": canonical,
        "expectedNames": None,
        "actualNames": None,
        "failureCount": None,
    }
    relative = "Diagnostics/ScreenshotComparison/summary.json"
    if not require_nonempty(root, relative, errors):
        return details
    try:
        summary = load_json(root / relative)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        errors.append(f"screenshot comparison summary is invalid: {error}")
        return details
    names = summary.get("images")
    expected_names = summary.get("expectedNames")
    actual_names = summary.get("actualNames")
    failure_count = summary.get("failureCount")
    details.update(
        expectedNames=expected_names,
        actualNames=actual_names,
        failureCount=failure_count,
    )
    if not isinstance(names, list) or any(not isinstance(item, dict) for item in names):
        errors.append("screenshot comparison images are invalid")
        return details
    image_names = [item.get("name") for item in names]
    if expected_names != canonical:
        errors.append("screenshot comparison expected names do not match the canonical story")
    if not isinstance(actual_names, list) or actual_names != sorted(set(actual_names)) \
            or any(not isinstance(name, str) or PurePosixPath(name).name != name
                   for name in actual_names):
        errors.append("screenshot comparison actual names are not sorted, unique basenames")
        actual_names = []
    if any(name not in canonical for name in actual_names):
        errors.append("screenshot comparison actual names are not a canonical subset")
    if image_names != canonical:
        errors.append("screenshot comparison image rows do not cover every canonical screenshot")
    if run_status == "passed" and actual_names != canonical:
        errors.append("a passing attempt does not contain exactly the canonical screenshots")
    if run_status == "passed" and summary.get("fileSetMatches") is not True:
        errors.append("a passing attempt reports mismatched screenshot file sets")
    failures = [item for item in names if item.get("result") not in PASSING_COMPARISON_RESULTS]
    if not isinstance(failure_count, int) or isinstance(failure_count, bool) \
            or failure_count < 0 or failure_count != len(failures):
        errors.append("screenshot comparison failure count is inconsistent")
    if run_status == "passed" and (failure_count != 0 or failures):
        errors.append("a passing attempt contains screenshot comparison failures")
    comparison_root = root / "Diagnostics" / "ScreenshotComparison"
    for item in failures:
        name = item.get("name", "unknown")
        for key in ("expectedArtifact", "actualArtifact", "diffArtifact"):
            artifact = item.get(key)
            if not safe_relative_path(artifact) or artifact == "not-required":
                errors.append(f"nonexact screenshot {name} has invalid {key}")
                continue
            path = comparison_root / PurePosixPath(artifact)
            if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
                errors.append(f"nonexact screenshot {name} is missing nonempty {key}")
    return details


def semantic_validation(root: Path, story_root: Path, expected_story=None):
    errors = []
    attachments = []
    canonical, canonical_errors = canonical_screenshots(story_root, expected_story)
    errors.extend(canonical_errors)
    for relative in REQUIRED_FILES:
        require_nonempty(root, relative, errors)
    try:
        attachments = load_json(root / "Attachments" / "manifest.json")
        if not isinstance(attachments, list):
            errors.append("Attachments/manifest.json is not an attachment array")
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        errors.append(f"Attachments/manifest.json is invalid: {error}")
    try:
        run = load_json(root / "Run.json")
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        run = {}
        errors.append(f"Run.json is invalid: {error}")
    story = run.get("story")
    commit = run.get("commit")
    status_value = run.get("status")
    if expected_story is not None and story != expected_story:
        errors.append("Run.json story does not match the requested story")
    if story_root.name != story:
        errors.append("Run.json story does not match the canonical story root")
    if status_value not in ("passed", "failed"):
        errors.append("Run.json status is not final")
    if not isinstance(commit, str) or len(commit) != 40 \
            or any(character not in "0123456789abcdef" for character in commit):
        errors.append("Run.json commit is not a full lowercase SHA")
    rows, phase_errors = parse_phases(root / "PhaseTimings.tsv")
    errors.extend(phase_errors)
    tests = [exit_code for phase, exit_code in rows if phase == "test"]
    test_phase_entered = len(tests) == 1
    if len(tests) > 1:
        errors.append("test phase is not recorded exactly once")
    if status_value == "passed" and (not test_phase_entered or tests[0] != 0):
        errors.append("a passing attempt does not contain one successful test phase")
    screenshots = validate_comparison(root, canonical, status_value, errors)
    test_exit_code = tests[0] if test_phase_entered else None
    failed_test_phase = test_phase_entered and test_exit_code != 0
    failure = None
    if failed_test_phase:
        for relative in FAILURE_DIAGNOSTICS:
            require_nonempty(root, relative, errors)
        try:
            failure = load_json(root / "Diagnostics" / "FailureEvidence.json")
            if failure.get("testExitCode") != test_exit_code or failure.get("resultBundle") \
                    != "Results/Story.xcresult" or failure.get("resultBundleAvailable") is not True:
                errors.append("FailureEvidence.json does not corroborate the failed test phase")
        except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
            errors.append(f"FailureEvidence.json is invalid: {error}")
        validate_failure_screen(root, failure, attachments, errors)
    walkthrough = root / "ActualWalkthrough" / "README.md"
    if not walkthrough.is_file() or walkthrough.is_symlink() or walkthrough.stat().st_size == 0:
        partial_is_truthful = failed_test_phase and isinstance(failure, dict) and (
            failure.get("attachmentExportExitCode") not in (None, 0)
            or failure.get("materializationExitCode") not in (None, 0)
        )
        if not partial_is_truthful:
            errors.append("required evidence is missing or empty: ActualWalkthrough/README.md")
    diagnostics = {
        "testPhaseEntered": test_phase_entered,
        "testExitCode": test_exit_code,
        "failureEvidenceRequired": failed_test_phase,
        "requiredFailurePaths": list(FAILURE_DIAGNOSTICS) if failed_test_phase else [],
    }
    validation = {
        "valid": not errors,
        "errors": errors,
    }
    return validation, story, commit, status_value, screenshots, diagnostics


def build_manifest(root: Path, story_root: Path, expected_story=None):
    validation, story, commit, status_value, screenshots, diagnostics = semantic_validation(
        root, story_root, expected_story)
    files, excluded, scan_errors = scan_regular_files(root)
    validation["errors"].extend(scan_errors)
    validation["valid"] = not validation["errors"]
    return {
        "schemaVersion": 1,
        "story": story,
        "commit": commit,
        "status": status_value,
        "files": files,
        "excluded": excluded,
        "screenshots": screenshots,
        "diagnostics": diagnostics,
        "validation": validation,
    }


def write_manifest(root: Path, story_root: Path, expected_story=None):
    manifest = build_manifest(root, story_root, expected_story)
    root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=root.parent, prefix=".EvidenceManifest.", delete=False
    ) as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
        temporary = Path(handle.name)
    os.replace(temporary, root / MANIFEST_NAME)
    return manifest


def validate_manifest(root: Path, story_root: Path, expected_story=None):
    errors = []
    path = root / MANIFEST_NAME
    try:
        manifest = load_json(path)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        return [f"EvidenceManifest.json is missing or invalid: {error}"]
    if not isinstance(manifest, dict) or set(manifest) != {
        "schemaVersion", "story", "commit", "status", "files", "excluded",
        "screenshots", "diagnostics", "validation"
    } or manifest.get("schemaVersion") != 1:
        return ["EvidenceManifest.json has an invalid top-level schema"]
    expected = build_manifest(root, story_root, expected_story)
    entries = manifest.get("files")
    if not isinstance(entries, list):
        errors.append("EvidenceManifest.json files are not an array")
    else:
        paths = []
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
                errors.append("EvidenceManifest.json contains a malformed file entry")
                continue
            relative = entry.get("path")
            if not safe_relative_path(relative) or relative == MANIFEST_NAME:
                errors.append("EvidenceManifest.json contains an unsafe file path")
            paths.append(relative)
            if not isinstance(entry.get("bytes"), int) or isinstance(entry.get("bytes"), bool) \
                    or entry.get("bytes") < 0:
                errors.append("EvidenceManifest.json contains an invalid byte count")
            digest = entry.get("sha256")
            if not isinstance(digest, str) or len(digest) != 64 \
                    or any(character not in "0123456789abcdef" for character in digest):
                errors.append("EvidenceManifest.json contains an invalid SHA-256")
        if paths != sorted(paths) or len(paths) != len(set(paths)):
            errors.append("EvidenceManifest.json paths are not sorted and unique")
    if manifest.get("files") != expected["files"]:
        errors.append("EvidenceManifest.json does not match every retained evidence file")
    if manifest.get("excluded") != expected["excluded"]:
        errors.append("EvidenceManifest.json does not document excluded non-evidence paths")
    if manifest.get("story") != expected["story"] or manifest.get("commit") != expected["commit"] \
            or manifest.get("status") != expected["status"]:
        errors.append("EvidenceManifest.json identity does not match Run.json")
    if manifest.get("screenshots") != expected["screenshots"]:
        errors.append("EvidenceManifest.json screenshot evidence does not match retained evidence")
    if manifest.get("diagnostics") != expected["diagnostics"]:
        errors.append("EvidenceManifest.json diagnostic evidence does not match retained evidence")
    if manifest.get("validation") != expected["validation"]:
        errors.append("EvidenceManifest.json validation does not match retained evidence")
    if not expected["validation"]["valid"]:
        errors.extend(f"evidence contract: {error}" for error in expected["validation"]["errors"])
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("write", "validate"))
    parser.add_argument("attempt", type=Path)
    parser.add_argument("story_root", type=Path, metavar="story-root")
    parser.add_argument("--story")
    args = parser.parse_args(argv)
    if args.mode == "write":
        manifest = write_manifest(args.attempt, args.story_root, args.story)
        errors = [] if manifest["validation"]["valid"] else manifest["validation"]["errors"]
    else:
        errors = validate_manifest(args.attempt, args.story_root, args.story)
    if errors:
        print("Invalid E2E evidence manifest:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
