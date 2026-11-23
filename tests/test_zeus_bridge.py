# Copyright 2026 Google LLC & The Zeus Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Unit tests for ZeusBridge in Harness2."""

import unittest
from unittest.mock import MagicMock, patch

from harness2.core.zeus_bridge import CandidateEvaluation, ZeusBridge, ZeusHit


class TestZeusBridge(unittest.TestCase):
    def setUp(self) -> None:
        self.bridge = ZeusBridge()

    def test_bridge_availability(self) -> None:
        # Check that the bridge correctly inspects local disk structure
        self.assertTrue(self.bridge.is_available())

    @patch.object(ZeusBridge, "_run_cli")
    def test_search_parsing(self, mock_cli: MagicMock) -> None:
        mock_cli.return_value.stdout = (
            "0.875 knowledge/lessons/accounting.md:12-15 Always calculate credits with correct sign.\n"
            "0.720 knowledge/lessons/tax.md:4-8 Verify deductibility rules.\n"
        )
        hits = self.bridge.search("accounting calculation", k=2)
        self.assertEqual(len(hits), 2)
        self.assertAlmostEqual(hits[0].score, 0.875)
        self.assertEqual(hits[0].location, "knowledge/lessons/accounting.md:12-15")
        self.assertIn("Always calculate credits", hits[0].snippet)

    @patch.object(ZeusBridge, "_run_cli")
    def test_classify_binary_success(self, mock_cli: MagicMock) -> None:
        mock_cli.return_value.stdout = (
            '{"type": "binary", "probability": 0.95, "confidence": 1.0, "verdict": "meets", "model": "ollama:llama3.2:3b"}'
        )
        res = self.bridge.classify_binary("Does this code calculate credits?", "total += credits")
        self.assertEqual(res["type"], "binary")
        self.assertEqual(res["probability"], 0.95)
        self.assertEqual(res["verdict"], "meets")

    @patch.object(ZeusBridge, "classify_binary")
    def test_evaluate_candidates_selection(self, mock_classify: MagicMock) -> None:
        def side_effect(instructions: str, state: str, **kwargs):
            if "credits - debits" in state:
                return {"type": "binary", "probability": 0.92, "confidence": 1.0, "verdict": "meets", "model": "test"}
            return {"type": "binary", "probability": 0.15, "confidence": 1.0, "verdict": "misses", "model": "test"}

        mock_classify.side_effect = side_effect

        candidates = {
            "cand_A": "total = credits - debits",
            "cand_B": "total = 0 # bug",
        }
        chosen, max_p, evals = self.bridge.evaluate_candidates(candidates, "Calculate net ledger balance", pass_threshold=0.70)
        self.assertEqual(chosen, "cand_A")
        self.assertAlmostEqual(max_p, 0.92)
        self.assertEqual(evals["cand_A"].verdict, "meets")
        self.assertEqual(evals["cand_B"].verdict, "misses")

    @patch.object(ZeusBridge, "classify_binary")
    def test_evaluate_candidates_abstention(self, mock_classify: MagicMock) -> None:
        # Both candidates fail to meet pass threshold -> fail closed
        mock_classify.return_value = {"type": "binary", "probability": 0.35, "confidence": 1.0, "verdict": "unsettled", "model": "test"}

        candidates = {
            "cand_1": "incomplete 1",
            "cand_2": "incomplete 2",
        }
        chosen, max_p, evals = self.bridge.evaluate_candidates(candidates, "Complex task", pass_threshold=0.70)
        self.assertIsNone(chosen)
        self.assertAlmostEqual(max_p, 0.35)


if __name__ == "__main__":
    unittest.main()
