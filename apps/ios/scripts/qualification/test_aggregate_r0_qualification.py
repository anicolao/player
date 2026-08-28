#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import aggregate_r0_qualification as aggregate


SHA = "a" * 40
STORIES = ["001-ios-launch", "002-import-and-play", "003-multifile-grouping",
           "004-metadata-repair", "005-play-and-restore", "006-safe-zip-import",
           "007-sleep-timer", "008-library-search", "009-accessible-core-journeys",
           "010-library-backup", "011-offline-recovery", "012-monetization",
           "013-app-store-listing"]
STORY_LANES = [STORIES[0:3], STORIES[3:6], STORIES[6:9], STORIES[9:11], STORIES[11:13]]


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def write_story_evidence(root, story, artifact, duration=5):
    evidence = root / artifact
    write_json(evidence / "Run.json", {"story": story, "commit": SHA, "status": "passed"})
    (evidence / "Logs").mkdir(parents=True, exist_ok=True)
    (evidence / "Logs/test.log").write_text("test entered\n", encoding="utf-8")
    (evidence / "Results/Story.xcresult").mkdir(parents=True, exist_ok=True)
    (evidence / "Results/Story.xcresult/Info.plist").write_text("plist", encoding="utf-8")
    (evidence / "PhaseTimings.tsv").write_text(f"test\t0\t{duration}\tpassed\n", encoding="utf-8")


class QualificationAggregatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest = self.root / "manifest.json"
        write_json(self.manifest, [{"story": story, "tests": ["test"]} for story in STORIES])
        self.baseline = self.root / "baseline.json"
        write_json(self.baseline, {"schemaVersion": 1,
                                  "thresholds": {"suiteRegression": .1, "storyRegression": .2},
                                  "appStoreAssetCount": 2,
                                  "suite": {"logicalWallSeconds": 100},
                                  "stories": {story: 10 for story in STORIES},
                                  "phases": {"test": 65, "core-fixtures": 2,
                                             "core-tests": 3, "app-store-renderer": 1}})
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
        for lane_index, lane_stories in enumerate(STORY_LANES, 1):
            lane_root = self.story_root / f"artifact-{lane_index}"
            summaries = []
            for story in lane_stories:
                attempts = []
                for index in range(1, 11):
                    artifact = f"Stories/{story}/attempt-{index:02d}"
                    write_story_evidence(lane_root, story, artifact)
                    attempts.append({"attempt": index, "result": "passed", "durationSeconds": 5,
                                     "exitCode": 0, "testPhaseEntered": True,
                                     "signature": "none", "artifact": artifact})
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
                    write_story_evidence(matrix_lane_root, story, artifact)
                    story_results.append({"story": story, "commit": SHA, "status": "passed",
                                          "signature": "none", "durationSeconds": 5,
                                          "testPhaseEntered": True, "artifact": artifact})
                renderer = {"required": False, "status": "not-required"}
                if lane_index == 5:
                    renderer_artifact = f"Matrices/{matrix_name}/AppStoreListing"
                    renderer_root = matrix_lane_root / renderer_artifact
                    (renderer_root / "screenshots").mkdir(parents=True)
                    for asset in range(1, 3):
                        (renderer_root / f"screenshots/{asset}.png").write_text("png", encoding="utf-8")
                    (renderer_root / "renderer.log").write_text("rendered\n", encoding="utf-8")
                    renderer = {"required": True, "status": "passed", "exitCode": 0,
                                "durationSeconds": 1, "renderedAssetCount": 2,
                                "expectedAssetCount": 2, "artifact": renderer_artifact}
                    core_artifact = f"Matrices/{matrix_name}/Core"
                    core_root = matrix_lane_root / core_artifact
                    (core_root / "Logs").mkdir(parents=True)
                    (core_root / "Logs/fixtures.log").write_text("fixtures\n", encoding="utf-8")
                    (core_root / "Logs/tests.log").write_text("tests\n", encoding="utf-8")
                    (core_root / "Results/Core.xcresult").mkdir(parents=True)
                    (core_root / "Results/Core.xcresult/Info.plist").write_text("plist", encoding="utf-8")
                matrices.append({"lane": f"lane-{lane_index}", "commit": SHA,
                                 "matrixAttempt": matrix_index, "status": "passed",
                                 "durationSeconds": 20 + lane_index, "stories": story_results,
                                 "core": {"required": lane_index == 5,
                                          "status": "passed" if lane_index == 5 else "not-required",
                                          "fixtureDurationSeconds": 2 if lane_index == 5 else None,
                                          "testDurationSeconds": 3 if lane_index == 5 else None,
                                          "artifact": core_artifact if lane_index == 5 else None},
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
        self.assertEqual(summary["matrixQualification"]["phaseTimings"]["test"]["current"]["median"], 65)
        self.assertTrue(summary["failureAccounting"]["rootCauseAccountingComplete"])
        self.assertEqual(len(summary["failureAccounting"]["historical"]), 1)

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

    def test_rejects_missing_run_or_result_bundle(self):
        payload = json.loads(self.story_summary().read_text())
        artifact = self.story_summary().parent / payload["stories"][0]["attempts"][0]["artifact"]
        (artifact / "Run.json").unlink()
        (artifact / "Results/Story.xcresult/Info.plist").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_incomplete_core_evidence(self):
        (self.matrix_root / "artifact-5/Matrices/matrix-01/Core/Logs/tests.log").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_missing_renderer_asset(self):
        (self.matrix_root / "artifact-5/Matrices/matrix-01/AppStoreListing/screenshots/1.png").unlink()
        self.assertEqual(self.run_aggregate(), 1)

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
        target = STORIES[0]
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

    def test_rejects_missing_story_or_matrix_lane(self):
        self.story_summary(3).unlink()
        self.matrix_summary(4).unlink()
        self.assertEqual(self.run_aggregate(), 1)


if __name__ == "__main__":
    unittest.main()
