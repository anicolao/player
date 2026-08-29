#!/usr/bin/env python3
import json
import hashlib
import os
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

import aggregate_r0_qualification as aggregate
import evidence_manifest as evidence_module


SHA = "a" * 40
STORIES = ["001-ios-launch", "002-import-and-play", "003-multifile-grouping",
           "004-metadata-repair", "005-play-and-restore", "006-safe-zip-import",
           "007-sleep-timer", "008-library-search", "009-accessible-core-journeys",
           "010-library-backup", "011-offline-recovery", "012-monetization",
           "013-app-store-listing"]
STORY_QUALIFICATION_LANES = [
    ["004-metadata-repair", "001-ios-launch"],
    ["005-play-and-restore", "006-safe-zip-import"],
    ["007-sleep-timer", "010-library-backup", "012-monetization"],
    ["008-library-search", "009-accessible-core-journeys", "003-multifile-grouping"],
    ["011-offline-recovery", "002-import-and-play", "013-app-store-listing"],
]
MATRIX_QUALIFICATION_LANES = [
    ["004-metadata-repair", "012-monetization"],
    ["005-play-and-restore", "011-offline-recovery", "003-multifile-grouping"],
    ["007-sleep-timer", "008-library-search"],
    ["001-ios-launch", "002-import-and-play", "010-library-backup"],
    ["006-safe-zip-import", "009-accessible-core-journeys", "013-app-store-listing"],
]


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def write_png(path, width=1, height=1):
    def chunk(name, data):
        checksum = zlib.crc32(name + data) & 0xffffffff
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", checksum)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    pixels = b"".join(b"\0" + b"\0\0\0" * width for _ in range(height))
    payload = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
               + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def png_chunk(name, data):
    checksum = zlib.crc32(name + data) & 0xffffffff
    return struct.pack(">I", len(data)) + name + data + struct.pack(">I", checksum)


def write_integrity_manifest(root):
    paths = sorted(path for path in root.rglob("*")
                   if path.is_file() and path.name != "EvidenceManifest.sha256")
    lines = [f"{hashlib.sha256(path.read_bytes()).hexdigest()}  "
             f"{path.relative_to(root).as_posix()}" for path in paths]
    (root / "EvidenceManifest.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_story_evidence(root, canonical_root, story, artifact, duration=5, phases=None):
    evidence = root / artifact
    write_json(evidence / "Run.json", {
        "story": story, "commit": SHA, "status": "passed", "exitCode": 0
    })
    (evidence / "Logs").mkdir(parents=True, exist_ok=True)
    (evidence / "Logs/test.log").write_text("test entered\n", encoding="utf-8")
    (evidence / "Results/Story.xcresult").mkdir(parents=True, exist_ok=True)
    (evidence / "Results/Story.xcresult/Info.plist").write_text("plist", encoding="utf-8")
    phase_rows = [f"test\t0\t{duration}\t0"]
    for name, value in (phases or {}).items():
        phase_rows.append(f"{name}\t0\t{value}\t0")
    (evidence / "PhaseTimings.tsv").write_text(
        "\n".join(phase_rows) + "\n", encoding="utf-8")
    write_json(evidence / "Attachments/manifest.json", [{"attachments": []}])
    (evidence / "ActualWalkthrough").mkdir(parents=True, exist_ok=True)
    (evidence / "ActualWalkthrough/README.md").write_text("# Walkthrough\n", encoding="utf-8")
    screenshot = evidence / "ActualWalkthrough/screenshots/ios/000-screen.png"
    screenshot.parent.mkdir(parents=True, exist_ok=True)
    screenshot.write_text("png", encoding="utf-8")
    write_json(evidence / "Diagnostics/ScreenshotComparison/summary.json", {
        "failureCount": 0,
        "fileSetMatches": True,
        "expectedNames": ["000-screen.png"],
        "actualNames": ["000-screen.png"],
        "images": [{"name": "000-screen.png", "result": "exact"}],
    })
    manifest = evidence_module.write_manifest(evidence, canonical_root / story, story)
    if not manifest["validation"]["valid"]:
        raise AssertionError(manifest["validation"]["errors"])


class QualificationAggregatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest = self.root / "manifest.json"
        write_json(self.manifest, [{"story": story, "tests": ["test"]} for story in STORIES])
        for story in STORIES:
            write_json(self.root / story / "story.json", {
                "id": story, "platform": "ios", "screenshots": ["000-screen.png"]
            })
            screenshot = self.root / story / "screenshots/ios/000-screen.png"
            screenshot.parent.mkdir(parents=True, exist_ok=True)
            screenshot.write_text("png", encoding="utf-8")
        self.baseline = self.root / "baseline.json"
        source = {"workflowRun": 1, "url": "https://example.test/run/1",
                  "headCommit": SHA, "checkoutCommit": SHA,
                  "runner": "macos-26", "xcode": "26.6", "runtime": "iOS 26.5"}
        phase_reference = {
            "attachment-export": 0, "build": 100, "build-provenance": 0,
            "build-reuse": 0, "environment-reuse": 0,
            "readme-comparison": 0, "screenshot-comparison": 0,
            "simulator": 0, "target-install": 0, "test": 65,
            "walkthrough-materialization": 0, "core-fixtures": 2,
            "core-tests": 3, "app-store-renderer": 1,
        }
        timing = {"source": source,
                  "suite": {"logicalWallSeconds": 100},
                  "stories": {story: 10 for story in STORIES},
                  "phases": phase_reference}
        write_json(self.baseline, {"schemaVersion": 2,
                                  "thresholds": {"suiteRegression": .1, "storyRegression": .2},
                                  "appStoreAssetCount": 2,
                                  "appStorePixelWidth": 1,
                                  "appStorePixelHeight": 1,
                                  "preRemediation": timing,
                                  "qualificationReference": {
                                      **timing,
                                      "coverageAdjustment": {
                                          "reason": "Intentional remediation coverage.",
                                          "approvedBy": "The remediation plan.",
                                          "remediationItems": [
                                              f"R{index}" for index in range(1, 17)
                                          ]}}})
        self.history = self.root / "history.json"
        write_json(self.history, {"schemaVersion": 1, "entries": [{
            "signature": "screenshot:pixel-difference:003-smart-rewind-applied.png",
            "story": "005-play-and-restore",
            "evidence": {"url": "https://example.test/run/1", "observation": "Exact mismatch."},
            "rootCause": "Capture preceded semantic readiness.",
            "diagnosisStatus": "confirmed",
            "fix": {"status": "verified", "summary": "Gate capture on semantic readiness.", "commits": ["b" * 40],
                    "validation": "Focused story passed."},
            "qualificationResetCount": 0,
            "resetEvidence": "Failure preceded formal qualification."
        }]})
        self.story_root = self.root / "stories"
        self.matrix_root = self.root / "matrices"
        for lane_index, lane_stories in enumerate(MATRIX_QUALIFICATION_LANES, 1):
            lane_root = self.story_root / f"artifact-{lane_index}"
            summaries = []
            for story in STORY_QUALIFICATION_LANES[lane_index - 1]:
                attempts = []
                for index in range(1, 11):
                    artifact = f"Stories/{story}/attempt-{index:02d}"
                    write_story_evidence(lane_root, self.root, story, artifact)
                    attempts.append({"attempt": index, "result": "passed", "durationSeconds": 5,
                                     "exitCode": 0, "testPhaseEntered": True,
                                     "evidenceValid": True, "signature": "none",
                                     "artifact": artifact})
                summaries.append({"story": story, "commit": SHA, "requestedAttempts": 10,
                                  "attemptCount": 10, "passCount": 10, "failureCount": 0,
                                  "attempts": attempts})
            write_json(lane_root / "StoryLaneSummary.json",
                       {"stage": "story", "lane": f"lane-{lane_index}", "commit": SHA,
                        "requestedAttempts": 10, "buildUnchanged": True,
                        "infrastructureInvalid": False, "status": "passed", "stories": summaries})

            matrix_lane_root = self.matrix_root / f"artifact-{lane_index}"
            matrices = []
            for matrix_index in range(1, 6):
                matrix_name = f"matrix-{matrix_index:02d}"
                story_results = []
                for story in lane_stories:
                    artifact = f"Matrices/{matrix_name}/Stories/{story}"
                    phases = None
                    if story == lane_stories[0]:
                        phases = {phase: 0 for phase in aggregate.STORY_PHASES - {"test"}}
                        phases["build"] = 20
                    write_story_evidence(
                        matrix_lane_root, self.root, story, artifact,
                        phases=phases)
                    story_results.append({"story": story, "commit": SHA, "status": "passed",
                                          "signature": "none", "durationSeconds": 5,
                                          "exitCode": 0,
                                          "testPhaseEntered": True, "evidenceValid": True,
                                          "artifact": artifact})
                renderer = {"required": False, "status": "not-required"}
                if lane_index == 5:
                    renderer_artifact = f"Matrices/{matrix_name}/AppStoreListing"
                    renderer_root = matrix_lane_root / renderer_artifact
                    (renderer_root / "screenshots").mkdir(parents=True)
                    for asset in range(1, 3):
                        write_png(renderer_root / f"screenshots/{asset}.png")
                    (renderer_root / "renderer.log").write_text("rendered\n", encoding="utf-8")
                    renderer = {"required": True, "status": "passed", "exitCode": 0,
                                "durationSeconds": 1, "renderedAssetCount": 2,
                                "expectedAssetCount": 2, "artifact": renderer_artifact}
                    write_json(renderer_root / "AppStoreRendererSummary.json", renderer)
                    write_integrity_manifest(renderer_root)
                core_artifact = None
                core = {"required": False, "status": "not-required"}
                if lane_index == 3:
                    core_artifact = f"Matrices/{matrix_name}/Core"
                    core_root = matrix_lane_root / core_artifact
                    (core_root / "Logs").mkdir(parents=True)
                    (core_root / "Logs/fixtures.log").write_text("fixtures\n", encoding="utf-8")
                    (core_root / "Logs/tests.log").write_text("tests\n", encoding="utf-8")
                    (core_root / "Results/Core.xcresult").mkdir(parents=True)
                    (core_root / "Results/Core.xcresult/Info.plist").write_text("plist", encoding="utf-8")
                    write_json(core_root / "Results/CoreTestSummary.json", {
                        "result": "Passed", "totalTestCount": 371, "passedTests": 371,
                        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                    })
                    core = {"required": True, "status": "passed", "signature": "none",
                            "fixtureExitCode": 0, "fixtureLogExitCode": 0,
                            "failedFixture": None, "testRan": True, "testExitCode": 0,
                            "testLogExitCode": 0, "resultSummaryExitCode": 0,
                            "cleanupExitCode": 0, "fixtureDurationSeconds": 2,
                            "testDurationSeconds": 3, "artifact": core_artifact}
                    write_json(core_root / "CoreSummary.json", core)
                    write_integrity_manifest(core_root)
                matrices.append({"lane": f"lane-{lane_index}", "commit": SHA,
                                 "matrixAttempt": matrix_index, "status": "passed",
                                 "durationSeconds": 20 + lane_index, "stories": story_results,
                                 "core": core,
                                 "appStoreRenderer": renderer})
            write_json(matrix_lane_root / "MatrixLaneSummary.json",
                       {"stage": "matrix", "lane": f"lane-{lane_index}", "commit": SHA,
                        "requestedMatrices": 5, "matrixCount": 5, "buildUnchanged": True,
                        "infrastructureInvalid": False, "status": "passed", "matrices": matrices})

    def tearDown(self):
        self.temp.cleanup()

    def run_aggregate(self):
        return aggregate.main(["--story-input", str(self.story_root),
                               "--matrix-input", str(self.matrix_root),
                               "--manifest", str(self.manifest), "--runtime-baseline", str(self.baseline),
                               "--failure-history", str(self.history),
                               "--sha", SHA, "--output", str(self.root / "report")])

    def story_summary(self, lane=1):
        return self.story_root / f"artifact-{lane}/StoryLaneSummary.json"

    def matrix_summary(self, lane=1):
        return self.matrix_root / f"artifact-{lane}/MatrixLaneSummary.json"

    def test_accepts_complete_green_evidence_and_reports_timings(self):
        self.assertEqual(self.run_aggregate(), 0)
        summary = json.loads((self.root / "report/QualificationSummary.json").read_text())
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(summary["storyQualification"]["durations"]["count"], 130)
        self.assertEqual(summary["matrixQualification"]["logicalWallClock"]["current"]["count"], 5)
        self.assertEqual(summary["matrixQualification"]["logicalWallClock"]["preRemediationSeconds"], 100)
        self.assertEqual(summary["matrixQualification"]["logicalWallClock"]["referenceSeconds"], 100)
        self.assertEqual(summary["matrixQualification"]["phaseTimings"]["test"]["current"]["median"], 65)
        self.assertEqual(summary["matrixQualification"]["phaseTimings"]["build"]["current"]["count"], 5)
        self.assertEqual(summary["matrixQualification"]["phaseTimings"]["build"]["current"]["median"], 100)
        self.assertTrue(summary["failureAccounting"]["rootCauseAccountingComplete"])
        self.assertEqual(len(summary["failureAccounting"]["historical"]), 1)

    def test_rejects_a_runtime_reference_without_approved_coverage_provenance(self):
        payload = json.loads(self.baseline.read_text())
        payload["qualificationReference"].pop("coverageAdjustment")
        write_json(self.baseline, payload)
        self.assertEqual(self.run_aggregate(), 2)

    def test_rejects_an_incomplete_remediation_coverage_adjustment(self):
        payload = json.loads(self.baseline.read_text())
        payload["qualificationReference"]["coverageAdjustment"]["remediationItems"].pop()
        write_json(self.baseline, payload)
        self.assertEqual(self.run_aggregate(), 2)

    def test_rejects_non_hex_runtime_source_commits(self):
        payload = json.loads(self.baseline.read_text())
        payload["qualificationReference"]["source"]["checkoutCommit"] = "z" * 40
        write_json(self.baseline, payload)
        self.assertEqual(self.run_aggregate(), 2)

    def test_rejects_the_legacy_single_runtime_baseline_schema(self):
        payload = json.loads(self.baseline.read_text())
        payload["schemaVersion"] = 1
        write_json(self.baseline, payload)
        self.assertEqual(self.run_aggregate(), 2)

    def test_checked_in_runtime_baseline_matches_the_current_contract(self):
        checked_in = Path(__file__).with_name("r0_runtime_baseline.json")
        validated = aggregate.validate_baseline(checked_in, STORIES)
        self.assertEqual(validated["schemaVersion"], 2)
        self.assertEqual(set(validated["qualificationReference"]["phases"]),
                         aggregate.REQUIRED_PHASES)

    def test_rejects_a_baseline_that_omits_required_gate_phases(self):
        payload = json.loads(self.baseline.read_text())
        for reference in ("preRemediation", "qualificationReference"):
            payload[reference]["phases"].pop("core-tests")
        write_json(self.baseline, payload)
        self.assertEqual(self.run_aggregate(), 2)

    def test_rejects_nonhex_failure_history_commits(self):
        original = json.loads(self.history.read_text())
        for invalid in ("z" * 40, "A" * 40, "a" * 39, 7):
            with self.subTest(invalid=invalid):
                payload = json.loads(json.dumps(original))
                payload["entries"][0]["fix"]["commits"] = [invalid]
                write_json(self.history, payload)
                self.assertEqual(self.run_aggregate(), 2)

    def test_rejects_missing_attempt_directory(self):
        payload = json.loads(self.story_summary().read_text())
        artifact = payload["stories"][0]["attempts"][0]["artifact"]
        for path in sorted((self.story_summary().parent / artifact).rglob("*"), reverse=True):
            path.unlink() if path.is_file() else path.rmdir()
        (self.story_summary().parent / artifact).rmdir()
        self.assertEqual(self.run_aggregate(), 1)

    def test_log_and_result_do_not_prove_test_phase_entered(self):
        payload = json.loads(self.story_summary().read_text())
        artifact = payload["stories"][0]["attempts"][0]["artifact"]
        (self.story_summary().parent / artifact / "PhaseTimings.tsv").write_text(
            "build\t0\t1\tpassed\n", encoding="utf-8")
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("testPhaseEntered disagrees" in error for error in errors))

    def test_rejects_missing_required_evidence_file(self):
        payload = json.loads(self.story_summary().read_text())
        artifact = payload["stories"][0]["attempts"][0]["artifact"]
        (self.story_summary().parent / artifact / "Logs/test.log").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_missing_or_corrupt_evidence_manifest(self):
        payload = json.loads(self.story_summary().read_text())
        artifact = self.story_summary().parent / payload["stories"][0]["attempts"][0]["artifact"]
        (artifact / "EvidenceManifest.json").unlink()
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("EvidenceManifest.json is missing or invalid" in error for error in errors))

        evidence_module.write_manifest(artifact, self.root / STORIES[0], STORIES[0])
        (artifact / "EvidenceManifest.json").write_text("{", encoding="utf-8")
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_manifest_hash_mismatch_or_unlisted_file(self):
        payload = json.loads(self.matrix_summary().read_text())
        artifact = self.matrix_summary().parent / payload["matrices"][0]["stories"][0]["artifact"]
        (artifact / "Logs/test.log").write_text("tampered after manifest\n", encoding="utf-8")
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("every retained evidence file" in error for error in errors))

        evidence_module.write_manifest(artifact, self.root / STORIES[0], STORIES[0])
        (artifact / "unlisted.txt").write_text("not in manifest\n", encoding="utf-8")
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_lane_summary_that_does_not_attest_valid_evidence(self):
        payload = json.loads(self.story_summary().read_text())
        payload["stories"][0]["attempts"][0]["evidenceValid"] = False
        write_json(self.story_summary(), payload)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("does not attest valid evidence" in error for error in errors))

    def test_rejects_missing_run_or_result_bundle(self):
        payload = json.loads(self.story_summary().read_text())
        artifact = self.story_summary().parent / payload["stories"][0]["attempts"][0]["artifact"]
        (artifact / "Run.json").unlink()
        (artifact / "Results/Story.xcresult/Info.plist").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_incomplete_core_evidence(self):
        (self.matrix_root / "artifact-3/Matrices/matrix-01/Core/Logs/tests.log").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_core_evidence_mutated_after_attestation(self):
        log = self.matrix_root / "artifact-3/Matrices/matrix-01/Core/Logs/tests.log"
        log.write_text("replaced after manifest\n", encoding="utf-8")
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("core integrity hash mismatch" in error for error in errors))

    def test_rejects_a_corrupt_extracted_core_test_summary(self):
        root = self.matrix_root / "artifact-3/Matrices/matrix-01/Core"
        write_json(root / "Results/CoreTestSummary.json", {
            "result": "Passed", "totalTestCount": 371, "passedTests": 370,
            "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
        })
        write_integrity_manifest(root)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("fully passing PlayerTests" in error for error in errors))

    def test_accounts_for_a_failed_core_test_as_an_unexplained_failure(self):
        payload = json.loads(self.matrix_summary(3).read_text())
        payload["status"] = "failed"
        payload["matrices"][0]["status"] = "failed"
        payload["matrices"][0]["core"]["status"] = "failed"
        payload["matrices"][0]["core"]["signature"] = \
            "core-test:ComputerReceiverTests.testBrowser:exit-65"
        payload["matrices"][0]["core"]["testExitCode"] = 65
        write_json(self.matrix_summary(3), payload)
        self.assertEqual(self.run_aggregate(), 1)
        summary = json.loads((self.root / "report/QualificationSummary.json").read_text())
        observed = summary["failureAccounting"]["observed"]
        self.assertEqual(observed[0]["signature"],
                         "core-test:ComputerReceiverTests.testBrowser:exit-65")
        self.assertEqual(observed[0]["classification"], "unexplained")

    def test_rejects_a_passing_core_gate_that_masks_a_fixture_failure(self):
        payload = json.loads(self.matrix_summary(3).read_text())
        payload["matrices"][0]["core"]["fixtureExitCode"] = 9
        write_json(self.matrix_summary(3), payload)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("masks a command failure" in error for error in errors))

    def test_rejects_an_emitted_phase_missing_from_the_runtime_reference(self):
        payload = json.loads(self.matrix_summary().read_text())
        record = payload["matrices"][0]["stories"][0]
        artifact = self.matrix_summary().parent / record["artifact"]
        with (artifact / "PhaseTimings.tsv").open("a", encoding="utf-8") as handle:
            handle.write("unreferenced-work\t0\t7\t0\n")
        evidence_module.write_manifest(artifact, self.root / record["story"], record["story"])
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("unreferenced phases: unreferenced-work" in error for error in errors))

    def test_rejects_a_required_phase_absent_from_all_evidence(self):
        for lane in range(1, 6):
            payload = json.loads(self.matrix_summary(lane).read_text())
            for matrix in payload["matrices"]:
                for record in matrix["stories"]:
                    artifact = self.matrix_summary(lane).parent / record["artifact"]
                    rows = (artifact / "PhaseTimings.tsv").read_text().splitlines()
                    (artifact / "PhaseTimings.tsv").write_text(
                        "\n".join(row for row in rows if not row.startswith("build\t")) + "\n",
                        encoding="utf-8")
                    evidence_module.write_manifest(
                        artifact, self.root / record["story"], record["story"])
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("missing required phases: build" in error for error in errors))

    def test_accepts_core_as_a_historical_failure_scope(self):
        payload = json.loads(self.history.read_text())
        payload["entries"][0]["story"] = "core"
        write_json(self.history, payload)
        self.assertEqual(self.run_aggregate(), 0)

    def test_rejects_missing_renderer_asset(self):
        (self.matrix_root / "artifact-5/Matrices/matrix-01/AppStoreListing/screenshots/1.png").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_a_truncated_renderer_png_even_when_reattested(self):
        root = self.matrix_root / "artifact-5/Matrices/matrix-01/AppStoreListing"
        (root / "screenshots/1.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        write_integrity_manifest(root)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("incomplete PNG" in error for error in errors))

    def test_rejects_renderer_png_without_decodable_pixels(self):
        renderer_root = self.matrix_root / "artifact-5/Matrices/matrix-01/AppStoreListing"
        image = renderer_root / "screenshots/1.png"
        header = struct.pack(">IIBBBBB", 1320, 2868, 8, 2, 0, 0, 0)
        for image_data in (None, b"not-zlib"):
            image.write_bytes(
                b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                + (png_chunk(b"IDAT", image_data) if image_data is not None else b"")
                + png_chunk(b"IEND", b""))
            write_integrity_manifest(renderer_root)
            self.assertEqual(self.run_aggregate(), 1)
            errors = json.loads(
                (self.root / "report/QualificationSummary.json").read_text())["errors"]
            self.assertTrue(any("renderer has invalid 1.png" in error for error in errors))

    def test_failure_evidence_png_requires_decodable_pixels(self):
        image = self.root / "failure-screen.png"
        header = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
        image.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                          + png_chunk(b"IEND", b""))
        self.assertIsNone(evidence_module.png_dimensions(image))
        image.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                          + png_chunk(b"IDAT", zlib.compress(b"\0\0\0\0"))
                          + png_chunk(b"IEND", b""))
        self.assertEqual(evidence_module.png_dimensions(image), (1, 1))

    def test_rejects_malformed_story_and_lane_durations_without_crashing(self):
        story = json.loads(self.story_summary().read_text())
        story["stories"][0]["attempts"][0]["durationSeconds"] = -1
        story["stories"][0]["attempts"][1]["durationSeconds"] = "5"
        story["stories"][0]["attempts"][2]["durationSeconds"] = True
        write_json(self.story_summary(), story)
        matrix = json.loads(self.matrix_summary().read_text())
        matrix["matrices"][0]["durationSeconds"] = "twenty"
        write_json(self.matrix_summary(), matrix)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertGreaterEqual(sum("invalid durationSeconds" in error for error in errors), 3)
        self.assertTrue(any("invalid lane wall-clock" in error for error in errors))

    def test_rejects_a_passing_attempt_with_nonzero_exit(self):
        payload = json.loads(self.story_summary().read_text())
        payload["stories"][0]["attempts"][0]["exitCode"] = 65
        write_json(self.story_summary(), payload)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("passed with a nonzero exitCode" in error for error in errors))

    def test_rejects_suite_wall_clock_regression_over_ten_percent(self):
        for lane in range(1, 6):
            path = self.matrix_summary(lane)
            payload = json.loads(path.read_text())
            for matrix in payload["matrices"]: matrix["durationSeconds"] = 111
            write_json(path, payload)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any("wall-clock regressed" in error for error in errors))

    def test_rejects_per_story_regression_over_twenty_percent(self):
        target = MATRIX_QUALIFICATION_LANES[0][0]
        payload = json.loads(self.matrix_summary().read_text())
        for matrix in payload["matrices"]:
            next(story for story in matrix["stories"] if story["story"] == target)["durationSeconds"] = 13
        write_json(self.matrix_summary(), payload)
        self.assertEqual(self.run_aggregate(), 1)
        errors = json.loads((self.root / "report/QualificationSummary.json").read_text())["errors"]
        self.assertTrue(any(target in error and "regressed" in error for error in errors))

    def test_rejects_a_recorded_failure(self):
        path = self.story_summary()
        payload = json.loads(path.read_text())
        payload["stories"][0]["attempts"][4]["result"] = "failed"
        payload["stories"][0]["attempts"][4]["signature"] = "semantic-timeout"
        payload["stories"][0]["passCount"] = 9
        payload["stories"][0]["failureCount"] = 1
        payload["status"] = "failed"
        write_json(path, payload)
        self.assertEqual(self.run_aggregate(), 1)
        accounting = json.loads((self.root / "report/QualificationSummary.json").read_text())["failureAccounting"]
        self.assertEqual(accounting["unexplainedFailureCount"], 1)
        self.assertEqual(accounting["observed"][0]["qualificationResetCount"], 1)

    def test_historical_signature_recurrence_requires_new_root_cause_evidence(self):
        path = self.story_summary(2)
        payload = json.loads(path.read_text())
        attempt = payload["stories"][1]["attempts"][0]
        attempt["result"] = "failed"
        attempt["signature"] = "screenshot:pixel-difference:003-smart-rewind-applied.png"
        payload["stories"][1]["passCount"] = 9
        payload["stories"][1]["failureCount"] = 1
        payload["status"] = "failed"
        write_json(path, payload)
        self.assertEqual(self.run_aggregate(), 1)
        observed = json.loads((self.root / "report/QualificationSummary.json").read_text())["failureAccounting"]["observed"]
        self.assertEqual(observed[0]["classification"], "historical-signature-recurrence-unconfirmed")
        self.assertEqual(observed[0]["qualificationResetCount"], 1)

    def test_pending_historical_fix_validation_blocks_qualification(self):
        history = json.loads(self.history.read_text())
        history["entries"][0]["diagnosisStatus"] = "supported-hypothesis"
        history["entries"][0]["fix"]["status"] = "pending-focused-validation"
        history["entries"][0]["fix"]["validation"] = "Pending focused repetitions."
        write_json(self.history, history)
        self.assertEqual(self.run_aggregate(), 1)
        accounting = json.loads((self.root / "report/QualificationSummary.json").read_text())["failureAccounting"]
        self.assertFalse(accounting["rootCauseAccountingComplete"])
        self.assertEqual(len(accounting["pendingHistorical"]), 1)

    def test_failure_signature_identifies_exact_ui_test(self):
        retained = self.root / "failed-ui-test"
        write_json(retained / "Diagnostics/FailureEvidence.json", {"testExitCode": 65})
        (retained / "Logs").mkdir(parents=True)
        (retained / "Logs/test.log").write_text(
            "Test Case '-[PlayerUITests.AccessibilityUITests testAccessibilityPreferenceTogglesUpdateAndPersist]' passed (1.0 seconds).\n"
            "Test Case '-[PlayerUITests.AccessibilityUITests testCoreJourneysRemainCompleteAtLargestAccessibilityText]' failed (2.0 seconds).\n",
            encoding="utf-8")
        self.assertEqual(
            self.failure_signature(retained, 65),
            "ui-test:AccessibilityUITests.testCoreJourneysRemainCompleteAtLargestAccessibilityText:exit-65")

    def test_failure_signature_reports_each_failed_test_in_stable_order(self):
        retained = self.root / "two-failed-ui-tests"
        write_json(retained / "Diagnostics/FailureEvidence.json", {"testExitCode": 65})
        (retained / "Logs").mkdir(parents=True)
        (retained / "Logs/test.log").write_text(
            "Test Case '-[PlayerUITests.ZebraUITests testSecondFailure]' failed (2.0 seconds).\n"
            "Test Case '-[PlayerUITests.AlphaUITests testFirstFailure]' failed (1.0 seconds).\n",
            encoding="utf-8")
        self.assertEqual(
            self.failure_signature(retained, 65),
            "ui-test:AlphaUITests.testFirstFailure+ZebraUITests.testSecondFailure:exit-65")

    def test_failure_signature_separates_xcode_launch_infrastructure(self):
        retained = self.root / "xcode-launch-timeout"
        write_json(retained / "Diagnostics/FailureEvidence.json", {"testExitCode": 65})
        (retained / "Logs").mkdir(parents=True)
        (retained / "Logs/test.log").write_text(
            "MultifileGroupingUITests.swift:33: error: Failed to launch app via Xcode: "
            "Timed out while launching application via Xcode.\n"
            "Test Case '-[PlayerUITests.MultifileGroupingUITests "
            "testRepairsMessyMultifileGroupingAndCommitsOneBookAtomically]' failed (74 seconds).\n",
            encoding="utf-8")
        self.assertEqual(
            self.failure_signature(retained, 65),
            "infrastructure:xcode-application-launch-timeout:"
            "MultifileGroupingUITests.testRepairsMessyMultifileGroupingAndCommitsOneBookAtomically:exit-65")

    def test_failure_signature_prefers_xcresult_failed_tests(self):
        retained = self.root / "xcresult-failed-ui-test"
        write_json(retained / "Diagnostics/FailureEvidence.json", {"testExitCode": 65})
        (retained / "Results/Story.xcresult").mkdir(parents=True)
        (retained / "Logs").mkdir(parents=True)
        (retained / "Logs/test.log").write_text(
            "Test Case '-[PlayerUITests.LogFallbackUITests testLogFailure]' failed (1.0 seconds).\n",
            encoding="utf-8")
        fake_bin = self.root / "fake-xcresult-bin"
        fake_bin.mkdir()
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            "#!/usr/bin/env bash\n"
            "cat <<'JSON'\n"
            '{"tests":[{"result":"Failed","identifier":"PlayerUITests/XCResultUITests/testAuthoritativeFailure()"}]}\n'
            "JSON\n",
            encoding="utf-8")
        fake_xcrun.chmod(0o755)
        self.assertEqual(
            self.failure_signature(retained, 65, extra_path=fake_bin),
            "ui-test:XCResultUITests.testAuthoritativeFailure:exit-65")

    def test_failure_signature_identifies_exact_screenshot_and_difference(self):
        retained = self.root / "failed-screenshot"
        write_json(retained / "Diagnostics/ScreenshotComparison/summary.json", {
            "failureCount": 1,
            "images": [{"name": "003-smart-rewind-applied.png", "result": "pixel-difference"}]
        })
        self.assertEqual(self.failure_signature(retained, 1),
                         "screenshot:pixel-difference:003-smart-rewind-applied.png")

    def test_core_failure_signature_identifies_every_failed_test_stably(self):
        retained = self.root / "failed-core-tests"
        (retained / "Logs").mkdir(parents=True)
        (retained / "Logs/tests.log").write_text(
            "Failing tests:\n"
            "\tZebraTests.testSecond()\n"
            "\tAlphaTests.testFirst()\n",
            encoding="utf-8")
        self.assertEqual(
            self.core_failure_signature(retained, 0, 65),
            "core-test:AlphaTests.testFirst+ZebraTests.testSecond:exit-65")
        self.assertEqual(
            self.core_failure_signature(retained, 7, 7),
            "core-fixtures:exit-7")

    def test_core_failure_signature_prefers_xcresult_over_the_log(self):
        retained = self.root / "xcresult-failed-core-test"
        (retained / "Results/Core.xcresult").mkdir(parents=True)
        (retained / "Logs").mkdir(parents=True)
        (retained / "Logs/tests.log").write_text(
            "\tLogFallbackTests.testLogFailure()\n", encoding="utf-8")
        fake_bin = self.root / "fake-core-xcresult-bin"
        fake_bin.mkdir()
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            "#!/usr/bin/env bash\n"
            "cat <<'JSON'\n"
            '{"tests":[{"result":"Failed","identifier":'
            '"PlayerTests/CoreAuthorityTests/testExactFailure()"}]}\n'
            "JSON\n",
            encoding="utf-8")
        fake_xcrun.chmod(0o755)
        self.assertEqual(
            self.core_failure_signature(retained, 0, 65, extra_path=fake_bin),
            "core-test:CoreAuthorityTests.testExactFailure:exit-65")

    def test_logged_command_gate_preserves_the_first_failure_and_stops(self):
        commands = self.root / "fixture-commands"
        commands.mkdir()
        marker = commands / "third-ran"
        scripts = []
        for name, body in (
                ("first", "echo first\n"),
                ("second", "echo second\nexit 7\n"),
                ("third", f"touch '{marker}'\n")):
            script = commands / name
            script.write_text(f"#!/usr/bin/env bash\n{body}", encoding="utf-8")
            script.chmod(0o755)
            scripts.append(script)
        support = Path(__file__).with_name("qualification-support.sh")
        log = commands / "gate.log"
        result = subprocess.run(
            ["bash", "-c",
             'set +e; . "$1"; qualification_run_logged_commands "$2" "$3" "$4" "$5"; '
             'status=$?; set -e; printf "status=%s\\n" "$status"',
             "qualification-command-gate-test", str(support), str(log),
             *(str(script) for script in scripts)],
            check=True, capture_output=True, text=True)
        self.assertTrue(result.stdout.endswith("status=7\n"))
        self.assertEqual(log.read_text(), "first\nsecond\n")
        self.assertFalse(marker.exists())

        log_failure = subprocess.run(
            ["bash", "-c",
             'set +e; . "$1"; qualification_run_logged_commands "$2" "$3"; '
             'status=$?; set -e; printf "status=%s\\n" "$status"',
             "qualification-log-failure-test", str(support), str(commands), str(scripts[0])],
            check=True, capture_output=True, text=True)
        self.assertTrue(log_failure.stdout.endswith("status=1\n"))

        fake_bin = commands / "fake-bin"
        fake_bin.mkdir()
        fake_tee = fake_bin / "tee"
        fake_tee.write_text("#!/usr/bin/env bash\n/bin/cat\nexit 9\n", encoding="utf-8")
        fake_tee.chmod(0o755)
        tee_failure = subprocess.run(
            ["bash", "-c",
             'set +e; PATH="$2:$PATH"; . "$1"; '
             'qualification_run_logged_commands "$3" "$4"; status=$?; set -e; '
             'printf "status=%s command=%s log=%s failed=%s\\n" "$status" '
             '"$QUALIFICATION_COMMAND_EXIT_CODE" "$QUALIFICATION_LOG_EXIT_CODE" '
             '"$QUALIFICATION_FAILED_COMMAND"',
             "qualification-tee-failure-test", str(support), str(fake_bin),
             str(commands / "tee-failure.log"), str(scripts[0])],
            check=True, capture_output=True, text=True)
        self.assertTrue(tee_failure.stdout.endswith(
            "status=9 command=0 log=9 failed=\n"))

    def test_shell_integrity_manifest_attests_the_exact_file_set(self):
        retained = self.root / "shell-integrity"
        (retained / "nested").mkdir(parents=True)
        (retained / "nested/file with spaces.txt").write_text("evidence\n", encoding="utf-8")
        support = Path(__file__).with_name("qualification-support.sh")
        subprocess.run(
            ["bash", "-c", '. "$1"; qualification_write_integrity_manifest "$2"',
             "qualification-integrity-test", str(support), str(retained)],
            check=True)
        errors = []
        aggregate.validate_integrity_manifest(retained, "shell fixture", errors)
        self.assertEqual(errors, [])
        (retained / "nested/file with spaces.txt").write_text("mutated\n", encoding="utf-8")
        aggregate.validate_integrity_manifest(retained, "shell fixture", errors)
        self.assertTrue(any("hash mismatch" in error for error in errors))

    def failure_signature(self, retained, exit_code, extra_path=None):
        support = Path(__file__).with_name("qualification-support.sh")
        environment = os.environ.copy()
        if extra_path is not None:
            environment["PATH"] = f"{extra_path}:{environment['PATH']}"
        result = subprocess.run(
            ["bash", "-c", '. "$1"; qualification_failure_signature "$2" "$3"',
             "qualification-signature-test", str(support), str(retained), str(exit_code)],
            check=True, capture_output=True, text=True, env=environment)
        return result.stdout.strip()

    def core_failure_signature(self, retained, fixture_exit, test_exit, extra_path=None):
        support = Path(__file__).with_name("qualification-support.sh")
        environment = os.environ.copy()
        if extra_path is not None:
            environment["PATH"] = f"{extra_path}:{environment['PATH']}"
        result = subprocess.run(
            ["bash", "-c",
             '. "$1"; qualification_core_failure_signature "$2" "$3" "$4"',
             "qualification-core-signature-test", str(support), str(retained),
             str(fixture_exit), str(test_exit)],
            check=True, capture_output=True, text=True, env=environment)
        return result.stdout.strip()

    def test_rejects_missing_story_or_matrix_lane(self):
        self.story_summary(3).unlink()
        self.matrix_summary(4).unlink()
        self.assertEqual(self.run_aggregate(), 1)


if __name__ == "__main__":
    unittest.main()
