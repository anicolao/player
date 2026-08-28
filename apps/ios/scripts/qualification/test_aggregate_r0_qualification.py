#!/usr/bin/env python3
import copy
import json
import tempfile
import unittest
from pathlib import Path

import aggregate_r0_qualification as aggregate


SHA = "a" * 40
STORIES = [f"{index:03d}-story" for index in range(1, 14)]
STORY_LANES = [STORIES[0:3], STORIES[3:6], STORIES[6:9], STORIES[9:11], STORIES[11:13]]


def attempt(index):
    return {"attempt": index, "result": "passed", "durationSeconds": index,
            "exitCode": 0, "testPhaseEntered": True, "signature": "none"}


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


class QualificationAggregatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.manifest = self.root / "manifest.json"
        write_json(self.manifest, [{"story": story, "tests": ["test"]} for story in STORIES])
        self.story_root = self.root / "stories"
        self.matrix_root = self.root / "matrices"
        for lane_index, lane_stories in enumerate(STORY_LANES, 1):
            summaries = []
            for story in lane_stories:
                attempts = [attempt(index) for index in range(1, 11)]
                summaries.append({"story": story, "commit": SHA, "requestedAttempts": 10,
                                  "attemptCount": 10, "passCount": 10, "failureCount": 0,
                                  "attempts": attempts})
            write_json(self.story_root / f"artifact-{lane_index}" / "StoryLaneSummary.json",
                       {"stage": "story", "lane": f"lane-{lane_index}", "commit": SHA,
                        "requestedAttempts": 10, "buildUnchanged": True,
                        "infrastructureInvalid": False, "status": "passed", "stories": summaries})
            matrices = []
            for matrix_index in range(1, 6):
                story_results = [{"story": story, "commit": SHA, "status": "passed",
                                  "signature": "none", "durationSeconds": matrix_index,
                                  "testPhaseEntered": True} for story in lane_stories]
                matrices.append({"lane": f"lane-{lane_index}", "commit": SHA,
                                 "matrixAttempt": matrix_index, "status": "passed",
                                 "stories": story_results,
                                 "core": {"required": lane_index == 5,
                                          "status": "passed" if lane_index == 5 else "not-required"}})
            write_json(self.matrix_root / f"artifact-{lane_index}" / "MatrixLaneSummary.json",
                       {"stage": "matrix", "lane": f"lane-{lane_index}", "commit": SHA,
                        "requestedMatrices": 5, "matrixCount": 5, "buildUnchanged": True,
                        "infrastructureInvalid": False, "status": "passed", "matrices": matrices})

    def tearDown(self):
        self.temp.cleanup()

    def run_aggregate(self):
        return aggregate.main(["--story-input", str(self.story_root),
                               "--matrix-input", str(self.matrix_root),
                               "--manifest", str(self.manifest), "--sha", SHA,
                               "--output", str(self.root / "report")])

    def test_accepts_complete_green_evidence(self):
        self.assertEqual(self.run_aggregate(), 0)
        summary = json.loads((self.root / "report/QualificationSummary.json").read_text())
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(summary["storyQualification"]["durations"]["count"], 130)

    def test_rejects_a_recorded_failure(self):
        path = self.story_root / "artifact-1/StoryLaneSummary.json"
        payload = json.loads(path.read_text())
        payload["stories"][0]["attempts"][4]["result"] = "failed"
        payload["stories"][0]["attempts"][4]["signature"] = "semantic-timeout"
        payload["stories"][0]["passCount"] = 9
        payload["stories"][0]["failureCount"] = 1
        payload["status"] = "failed"
        write_json(path, payload)
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_missing_story_lane(self):
        (self.story_root / "artifact-3/StoryLaneSummary.json").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_missing_matrix_lane(self):
        (self.matrix_root / "artifact-4/MatrixLaneSummary.json").unlink()
        self.assertEqual(self.run_aggregate(), 1)

    def test_rejects_a_red_logical_matrix(self):
        path = self.matrix_root / "artifact-2/MatrixLaneSummary.json"
        payload = json.loads(path.read_text())
        payload["matrices"][2]["stories"][0]["status"] = "failed"
        payload["matrices"][2]["status"] = "failed"
        payload["status"] = "failed"
        write_json(path, payload)
        self.assertEqual(self.run_aggregate(), 1)


if __name__ == "__main__":
    unittest.main()
