#!/usr/bin/env python3
import base64
import json
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

import evidence_manifest as evidence


STORY = "001-test-story"
NAMES = ["000-first.png", "001-second.png"]
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


class EvidenceManifestTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.story = self.root / "canonical" / STORY
        write_json(self.story / "story.json", {
            "id": STORY, "platform": "ios", "screenshots": NAMES
        })
        for name in NAMES:
            path = self.story / "screenshots" / "ios" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"canonical {name}".encode())

    def tearDown(self):
        self.temporary.cleanup()

    def make_attempt(self, failed_test=False):
        attempt = self.root / "attempt"
        write_json(attempt / "Run.json", {
            "story": STORY,
            "commit": "a" * 40,
            "startedAt": "2026-08-28T00:00:00Z",
            "completedAt": "2026-08-28T00:01:00Z",
            "status": "failed" if failed_test else "passed",
            "exitCode": 65 if failed_test else 0,
        })
        (attempt / "PhaseTimings.tsv").write_text(
            f"test\t0\t1\t{65 if failed_test else 0}\n", encoding="utf-8"
        )
        (attempt / "Logs").mkdir(parents=True)
        (attempt / "Logs/test.log").write_text("test executed\n", encoding="utf-8")
        result_info = attempt / "Results/Story.xcresult/Info.plist"
        result_info.parent.mkdir(parents=True)
        result_info.write_text("plist\n", encoding="utf-8")
        write_json(attempt / "Attachments/manifest.json", [{"attachments": []}])
        readme = attempt / "ActualWalkthrough/README.md"
        readme.parent.mkdir(parents=True)
        readme.write_text("# Walkthrough\n", encoding="utf-8")
        for name in NAMES:
            screenshot = attempt / "ActualWalkthrough/screenshots/ios" / name
            screenshot.parent.mkdir(parents=True, exist_ok=True)
            screenshot.write_bytes(f"actual {name}".encode())
        comparison = {
            "failureCount": 0,
            "fileSetMatches": True,
            "expectedNames": NAMES,
            "actualNames": NAMES,
            "images": [{"name": name, "result": "exact"} for name in NAMES],
        }
        write_json(attempt / "Diagnostics/ScreenshotComparison/summary.json", comparison)
        if failed_test:
            source = {
                "schemaVersion": 1,
                "artifact": "Diagnostics/failure-screen.png",
                "source": "live-simulator",
                "simulatorId": "11111111-2222-3333-4444-555555555555",
                "pixelWidth": 1,
                "pixelHeight": 1,
            }
            write_json(attempt / "Diagnostics/FailureEvidence.json", {
                "testExitCode": 65,
                "attachmentExportExitCode": 0,
                "materializationExitCode": 0,
                "screenshotEvidenceExitCode": 1,
                "resultBundleAvailable": True,
                "resultBundle": "Results/Story.xcresult",
                "failureScreenExitCode": 0,
                "failureScreen": source,
            })
            (attempt / "Diagnostics/failure-screen.png").write_bytes(PNG_1X1)
            write_json(attempt / "Diagnostics/failure-screen-source.json", source)
            for relative in evidence.FAILURE_DIAGNOSTICS:
                path = attempt / relative
                if path.name in {
                    "FailureEvidence.json", "failure-screen.png", "failure-screen-source.json"
                }:
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(f"diagnostic {relative}\n".encode())
        return attempt

    def write_and_validate(self, attempt):
        manifest = evidence.write_manifest(attempt, self.story, STORY)
        return manifest, evidence.validate_manifest(attempt, self.story, STORY)

    def test_writes_sorted_unique_complete_content_addressed_manifest(self):
        attempt = self.make_attempt()
        manifest, errors = self.write_and_validate(attempt)
        self.assertEqual(errors, [])
        self.assertTrue(manifest["validation"]["valid"])
        self.assertEqual(manifest["commit"], "a" * 40)
        self.assertEqual(manifest["screenshots"]["canonicalNames"], NAMES)
        self.assertFalse(manifest["diagnostics"]["failureEvidenceRequired"])
        paths = [item["path"] for item in manifest["files"]]
        self.assertEqual(paths, sorted(set(paths)))
        self.assertNotIn(evidence.MANIFEST_NAME, paths)
        actual_paths = sorted(
            path.relative_to(attempt).as_posix()
            for path in attempt.rglob("*")
            if path.is_file() and path.name != evidence.MANIFEST_NAME
        )
        self.assertEqual(paths, actual_paths)
        self.assertTrue(all(item["bytes"] > 0 and len(item["sha256"]) == 64
                            for item in manifest["files"]))

    def test_cli_write_and_validate_use_the_story_root_positional_contract(self):
        attempt = self.make_attempt()
        self.assertEqual(evidence.main([
            "write", str(attempt), str(self.story), "--story", STORY
        ]), 0)
        self.assertEqual(evidence.main([
            "validate", str(attempt), str(self.story), "--story", STORY
        ]), 0)

    def test_detects_changed_added_and_removed_retained_files(self):
        for mutation in ("changed", "added", "removed"):
            with self.subTest(mutation=mutation):
                attempt = self.make_attempt()
                evidence.write_manifest(attempt, self.story, STORY)
                if mutation == "changed":
                    (attempt / "Logs/test.log").write_text("changed\n", encoding="utf-8")
                elif mutation == "added":
                    (attempt / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
                else:
                    (attempt / "Attachments/manifest.json").unlink()
                self.assertTrue(any("every retained evidence file" in error
                                    for error in evidence.validate_manifest(attempt, self.story, STORY)))
                for path in sorted(attempt.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_rejects_unsafe_duplicate_unsorted_and_malformed_entries(self):
        mutations = (
            lambda files: files.insert(0, {"path": "../escape", "bytes": 1, "sha256": "0" * 64}),
            lambda files: files.append(dict(files[0])),
            lambda files: files.reverse(),
            lambda files: files[0].update(bytes=-1, sha256="not-a-digest"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                attempt = self.make_attempt()
                evidence.write_manifest(attempt, self.story, STORY)
                payload = json.loads((attempt / evidence.MANIFEST_NAME).read_text())
                mutate(payload["files"])
                write_json(attempt / evidence.MANIFEST_NAME, payload)
                self.assertNotEqual(evidence.validate_manifest(attempt, self.story, STORY), [])
                for path in sorted(attempt.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_rejects_corrupt_manifest_and_symlink_evidence(self):
        attempt = self.make_attempt()
        evidence.write_manifest(attempt, self.story, STORY)
        (attempt / evidence.MANIFEST_NAME).write_text("{", encoding="utf-8")
        self.assertTrue(any("missing or invalid" in error
                            for error in evidence.validate_manifest(attempt, self.story, STORY)))
        (attempt / "linked-log").symlink_to(attempt / "Logs/test.log")
        manifest = evidence.write_manifest(attempt, self.story, STORY)
        self.assertFalse(manifest["validation"]["valid"])
        self.assertTrue(any("symlink" in error for error in manifest["validation"]["errors"]))

    def test_every_universal_required_file_is_fail_closed(self):
        for relative in evidence.REQUIRED_FILES:
            with self.subTest(relative=relative):
                attempt = self.make_attempt()
                (attempt / relative).unlink()
                manifest = evidence.write_manifest(attempt, self.story, STORY)
                self.assertFalse(manifest["validation"]["valid"])
                self.assertTrue(any(relative in error for error in manifest["validation"]["errors"]))
                for path in sorted(attempt.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_pass_requires_nonempty_walkthrough_readme(self):
        attempt = self.make_attempt()
        (attempt / "ActualWalkthrough/README.md").write_bytes(b"")
        manifest = evidence.build_manifest(attempt, self.story, STORY)
        self.assertFalse(manifest["validation"]["valid"])
        self.assertTrue(any("ActualWalkthrough/README.md" in error
                            for error in manifest["validation"]["errors"]))

    def test_ephemeral_build_products_are_explicitly_excluded_without_hashing(self):
        attempt = self.make_attempt()
        build_file = attempt / "Build/Build/Products/large-product"
        build_file.parent.mkdir(parents=True)
        build_file.write_bytes(b"not retained evidence")
        manifest, errors = self.write_and_validate(attempt)
        self.assertEqual(errors, [])
        self.assertEqual(manifest["excluded"], [{
            "path": "Build",
            "reason": "ephemeral build products are verified by the E2E build-provenance contract",
        }])
        self.assertFalse(any(item["path"].startswith("Build/") for item in manifest["files"]))

    def test_passing_attempt_requires_exact_canonical_names_and_zero_failures(self):
        mutations = (
            lambda summary: summary.update(actualNames=[NAMES[0]], fileSetMatches=False),
            lambda summary: summary["images"].reverse(),
            lambda summary: summary.update(failureCount=1),
            lambda summary: summary["images"][0].update(result="pixel-difference"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                attempt = self.make_attempt()
                summary_path = attempt / "Diagnostics/ScreenshotComparison/summary.json"
                summary = json.loads(summary_path.read_text())
                mutate(summary)
                write_json(summary_path, summary)
                self.assertFalse(evidence.build_manifest(attempt, self.story, STORY)["validation"]["valid"])
                for path in sorted(attempt.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_complete_failed_test_evidence_and_nonexact_paths_validate(self):
        attempt = self.make_attempt(failed_test=True)
        comparison_root = attempt / "Diagnostics/ScreenshotComparison"
        summary_path = comparison_root / "summary.json"
        summary = json.loads(summary_path.read_text())
        summary["failureCount"] = 1
        summary["images"][0] = {
            "name": NAMES[0],
            "result": "pixel-difference",
            "expectedArtifact": "000-first-expected.png",
            "actualArtifact": "000-first-actual.png",
            "diffArtifact": "000-first-diff.png",
        }
        for name in ("000-first-expected.png", "000-first-actual.png", "000-first-diff.png"):
            (comparison_root / name).write_bytes(name.encode())
        write_json(summary_path, summary)
        manifest, errors = self.write_and_validate(attempt)
        self.assertTrue(manifest["validation"]["valid"])
        self.assertEqual(errors, [])

    def test_failure_screen_png_and_live_provenance_fail_closed(self):
        attempt = self.make_attempt(failed_test=True)
        source_path = attempt / "Diagnostics/failure-screen-source.json"
        failure_path = attempt / "Diagnostics/FailureEvidence.json"
        original_png = (attempt / "Diagnostics/failure-screen.png").read_bytes()
        original_source = source_path.read_bytes()
        original_failure = failure_path.read_bytes()
        mutations = (
            lambda: (attempt / "Diagnostics/failure-screen.png").write_bytes(b"not png"),
            lambda: write_json(source_path, {
                **json.loads(source_path.read_text()), "pixelWidth": 2
            }),
            lambda: write_json(failure_path, {
                **json.loads(failure_path.read_text()), "failureScreen": None
            }),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                mutate()
                self.assertFalse(evidence.build_manifest(
                    attempt, self.story, STORY
                )["validation"]["valid"])
                (attempt / "Diagnostics/failure-screen.png").write_bytes(original_png)
                source_path.write_bytes(original_source)
                failure_path.write_bytes(original_failure)

    def test_recording_provenance_requires_unique_newest_nonempty_manifest_attachment(self):
        attempt = self.make_attempt(failed_test=True)
        recording = attempt / "Attachments/recording.mp4"
        recording.write_bytes(b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00")
        empty_newer = attempt / "Attachments/empty.mp4"
        empty_newer.write_bytes(b"")
        attachments = [{
            "testIdentifier": "PlayerUITests/Failure/testExample()",
            "attachments": [
                {
                    "exportedFileName": "recording.mp4",
                    "suggestedHumanReadableName": "Screen Recording 2026-08-28.mp4",
                    "timestamp": 100.0,
                },
                {
                    "exportedFileName": "empty.mp4",
                    "suggestedHumanReadableName": "Screen Recording 2026-08-28.mp4",
                    "timestamp": 200.0,
                },
            ],
        }]
        write_json(attempt / "Attachments/manifest.json", attachments)
        source = {
            "schemaVersion": 1,
            "artifact": "Diagnostics/failure-screen.png",
            "source": "xctest-screen-recording",
            "attachment": "Attachments/recording.mp4",
            "testIdentifier": "PlayerUITests/Failure/testExample()",
            "attachmentTimestamp": 100.0,
            "requestedTimeSeconds": 2.0,
            "actualTimeSeconds": 1.0,
            "pixelWidth": 1,
            "pixelHeight": 1,
        }
        write_json(attempt / "Diagnostics/failure-screen-source.json", source)
        failure_path = attempt / "Diagnostics/FailureEvidence.json"
        failure = json.loads(failure_path.read_text())
        failure["failureScreen"] = source
        write_json(failure_path, failure)
        manifest, errors = self.write_and_validate(attempt)
        self.assertTrue(manifest["validation"]["valid"])
        self.assertEqual(errors, [])

        corrupt_newer = attempt / "Attachments/corrupt-newer.mp4"
        corrupt_newer.write_bytes(b"nonempty but corrupt")
        attachments[0]["attachments"].append({
            "exportedFileName": "corrupt-newer.mp4",
            "suggestedHumanReadableName": "Screen Recording 2026-08-28.mp4",
            "timestamp": 300.0,
        })
        write_json(attempt / "Attachments/manifest.json", attachments)
        self.assertFalse(evidence.build_manifest(
            attempt, self.story, STORY
        )["validation"]["valid"])

    def test_failure_screenshot_provenance_requires_unique_newest_png_attachment(self):
        attempt = self.make_attempt(failed_test=True)
        attachment = attempt / "Attachments/failure.png"
        attachment.write_bytes(PNG_1X1)
        attachments = [{
            "testIdentifier": "PlayerUITests/Failure/testExample()",
            "attachments": [{
                "exportedFileName": "failure.png",
                "suggestedHumanReadableName": "xctest-failure-screen_0_66A67D4C-8F3E-4D49-96B7-BBF13DCF045F.png",
                "timestamp": 200.0,
            }],
        }]
        write_json(attempt / "Attachments/manifest.json", attachments)
        self.assertFalse(evidence.build_manifest(
            attempt, self.story, STORY
        )["validation"]["valid"])
        source = {
            "schemaVersion": 1,
            "artifact": "Diagnostics/failure-screen.png",
            "source": "xctest-failure-screenshot",
            "attachment": "Attachments/failure.png",
            "testIdentifier": "PlayerUITests/Failure/testExample()",
            "attachmentTimestamp": 200.0,
            "pixelWidth": 1,
            "pixelHeight": 1,
        }
        write_json(attempt / "Diagnostics/failure-screen-source.json", source)
        failure_path = attempt / "Diagnostics/FailureEvidence.json"
        failure = json.loads(failure_path.read_text())
        failure["failureScreen"] = source
        write_json(failure_path, failure)
        manifest, errors = self.write_and_validate(attempt)
        self.assertTrue(manifest["validation"]["valid"])
        self.assertEqual(errors, [])

        text_payload = b"Comment\x00content mismatch"
        text_chunk = (
            struct.pack(">I", len(text_payload)) + b"tEXt" + text_payload
            + struct.pack(">I", zlib.crc32(b"tEXt" + text_payload) & 0xffffffff)
        )
        failure_screen = attempt / "Diagnostics/failure-screen.png"
        failure_screen.write_bytes(PNG_1X1[:-12] + text_chunk + PNG_1X1[-12:])
        self.assertFalse(evidence.build_manifest(
            attempt, self.story, STORY
        )["validation"]["valid"])
        failure_screen.write_bytes(PNG_1X1)

        near_miss = attempt / "Attachments/near-miss.png"
        near_miss.write_bytes(PNG_1X1)
        attachments[0]["attachments"].append({
            "exportedFileName": "near-miss.png",
            "suggestedHumanReadableName": "xctest-failure-screen_unrelated.png",
            "timestamp": 300.0,
        })
        write_json(attempt / "Attachments/manifest.json", attachments)
        self.assertTrue(evidence.build_manifest(
            attempt, self.story, STORY
        )["validation"]["valid"])

        duplicate = attempt / "Attachments/duplicate.png"
        duplicate.write_bytes(PNG_1X1)
        attachments[0]["attachments"].append({
            "exportedFileName": "duplicate.png",
            "suggestedHumanReadableName": "xctest-failure-screen_0_1A111111-1111-1111-1111-111111111111.png",
            "timestamp": 200.0,
        })
        write_json(attempt / "Attachments/manifest.json", attachments)
        self.assertFalse(evidence.build_manifest(
            attempt, self.story, STORY
        )["validation"]["valid"])

    def test_jpeg_exported_as_failure_screenshot_cannot_be_waived_by_recording_fallback(self):
        attempt = self.make_attempt(failed_test=True)
        recording = attempt / "Attachments/recording.mp4"
        recording.write_bytes(b"\x00\x00\x00\x14ftypqt  \x00\x00\x00\x00")
        jpeg = attempt / "Attachments/33333333-4444-5555-6666-777777777777.jpeg"
        jpeg.write_bytes(b"\xff\xd8\xff\xd9")
        attachments = [{
            "testIdentifier": "PlayerUITests/Failure/testExample()",
            "attachments": [{
                "exportedFileName": "recording.mp4",
                "suggestedHumanReadableName": "Screen Recording fixture.mp4",
                "timestamp": 300.0,
            }, {
                "exportedFileName": jpeg.name,
                "suggestedHumanReadableName": (
                    "xctest-failure-screen_0_"
                    "33333333-3333-3333-3333-333333333333.png"
                ),
                "timestamp": 200.0,
            }],
        }]
        write_json(attempt / "Attachments/manifest.json", attachments)
        source = {
            "schemaVersion": 1,
            "artifact": "Diagnostics/failure-screen.png",
            "source": "xctest-screen-recording",
            "attachment": "Attachments/recording.mp4",
            "testIdentifier": "PlayerUITests/Failure/testExample()",
            "attachmentTimestamp": 300.0,
            "requestedTimeSeconds": 2.0,
            "actualTimeSeconds": 1.0,
            "pixelWidth": 1,
            "pixelHeight": 1,
        }
        write_json(attempt / "Diagnostics/failure-screen-source.json", source)
        failure_path = attempt / "Diagnostics/FailureEvidence.json"
        failure = json.loads(failure_path.read_text())
        failure["failureScreenExitCode"] = 1
        failure["failureScreen"] = source
        write_json(failure_path, failure)
        manifest = evidence.build_manifest(attempt, self.story, STORY)
        self.assertFalse(manifest["validation"]["valid"])
        self.assertTrue(any(
            "XCTest failure screenshot has an unsafe exported filename" in error
            for error in manifest["validation"]["errors"]
        ))

    def test_failed_test_accepts_canonical_actual_subset_and_truthful_partial_walkthrough(self):
        attempt = self.make_attempt(failed_test=True)
        (attempt / "ActualWalkthrough/README.md").unlink()
        (attempt / "ActualWalkthrough/screenshots/ios" / NAMES[1]).unlink()
        comparison_root = attempt / "Diagnostics/ScreenshotComparison"
        for name in ("001-second-expected.png", "001-second-actual-missing.txt",
                     "001-second-diff-unavailable.txt"):
            (comparison_root / name).write_bytes(name.encode())
        write_json(comparison_root / "summary.json", {
            "failureCount": 1,
            "fileSetMatches": False,
            "expectedNames": NAMES,
            "actualNames": [NAMES[0]],
            "images": [
                {"name": NAMES[0], "result": "exact"},
                {"name": NAMES[1], "result": "missing-actual",
                 "expectedArtifact": "001-second-expected.png",
                 "actualArtifact": "001-second-actual-missing.txt",
                 "diffArtifact": "001-second-diff-unavailable.txt"},
            ],
        })
        failure_path = attempt / "Diagnostics/FailureEvidence.json"
        failure = json.loads(failure_path.read_text())
        failure["materializationExitCode"] = 1
        write_json(failure_path, failure)
        manifest, errors = self.write_and_validate(attempt)
        self.assertTrue(manifest["validation"]["valid"])
        self.assertEqual(errors, [])

    def test_failed_test_requires_every_named_nonempty_diagnostic(self):
        for relative in evidence.FAILURE_DIAGNOSTICS:
            with self.subTest(relative=relative):
                attempt = self.make_attempt(failed_test=True)
                (attempt / relative).write_bytes(b"")
                manifest = evidence.write_manifest(attempt, self.story, STORY)
                self.assertFalse(manifest["validation"]["valid"])
                self.assertTrue(any(relative in error for error in manifest["validation"]["errors"]))
                for path in sorted(attempt.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_nonexact_comparison_requires_safe_nonempty_expected_actual_and_diff(self):
        for bad_value in (None, "not-required", "../escape.png", "missing.png"):
            with self.subTest(bad_value=bad_value):
                attempt = self.make_attempt(failed_test=True)
                summary_path = attempt / "Diagnostics/ScreenshotComparison/summary.json"
                summary = json.loads(summary_path.read_text())
                summary["failureCount"] = 1
                summary["images"][0] = {
                    "name": NAMES[0], "result": "missing-actual",
                    "expectedArtifact": bad_value,
                    "actualArtifact": bad_value,
                    "diffArtifact": bad_value,
                }
                write_json(summary_path, summary)
                manifest = evidence.build_manifest(attempt, self.story, STORY)
                self.assertFalse(manifest["validation"]["valid"])
                for path in sorted(attempt.rglob("*"), reverse=True):
                    if path.is_file() or path.is_symlink():
                        path.unlink()
                    elif path.is_dir():
                        path.rmdir()

    def test_rejects_wrong_story_and_nonfinal_run(self):
        attempt = self.make_attempt()
        run_path = attempt / "Run.json"
        run = json.loads(run_path.read_text())
        run.update(story="wrong-story", status="running")
        write_json(run_path, run)
        manifest = evidence.build_manifest(attempt, self.story, STORY)
        self.assertFalse(manifest["validation"]["valid"])


if __name__ == "__main__":
    unittest.main()
