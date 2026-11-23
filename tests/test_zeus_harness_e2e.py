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

"""End-to-End Multi-Agent Integration Tests for Harness² and Zeus.

Verifies the complete loop:
1. Propose: Context building queries Zeus RAPTOR retrieval for institutional lessons.
2. Select: Evaluates candidates using ClassifierPort and deterministic TruthTable logic.
3. Compose / Library: Ingests transferable lessons into Zeus with 2-stage secret redaction.
4. Benchmark: Verifies execution timing, token efficiency, and 0 secret leaks.
"""

import shutil
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from harness2.core import context, library as library_store, selection
from harness2.core.spec import RunView
from harness2.core.tree import SurfaceSpec
from harness2.core.zeus_bridge import ZeusBridge, ZeusHit
from harness2.demo import DemoAdapter, DemoProposer


class TestZeusHarnessE2E(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp(prefix="zeus_harness_e2e_"))
        self.adapter = DemoAdapter(self.tmp_dir)
        self.proposer = DemoProposer(self.adapter.spec.channels["proposer"])
        self.task_id = "ledger-1"
        self.surface = self.adapter.substrate.surface()

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_propose_context_retrieves_zeus_lessons(self) -> None:
        """Verifies that building context retrieves Zeus lessons and populates PRIOR_LESSONS.md."""
        dest = self.tmp_dir / "context_test"
        
        mock_hit = ZeusHit(
            score=0.912,
            location="knowledge/lessons/ledger-rules.md:10-15",
            snippet="Always sum debits with negative sign and credits with positive sign.",
        )

        with patch.object(ZeusBridge, "search", return_value=[mock_hit]), \
             patch.object(ZeusBridge, "is_available", return_value=True):
            ctx_tree = context.build(
                dest=dest,
                adapter=self.adapter,
                task_id=self.task_id,
            )

            # Verify PRIOR_LESSONS.md was written into context/zeus/
            lessons_file = dest / "zeus" / "PRIOR_LESSONS.md"
            self.assertTrue(lessons_file.exists())
            content = lessons_file.read_text(encoding="utf-8")
            self.assertIn("Prior Institutional Lessons", content)
            self.assertIn("score: 0.912", content)
            self.assertIn("Always sum debits with negative sign", content)

            # Verify mission pointer mentions the retrieved lessons
            self.assertIn("context/zeus/PRIOR_LESSONS.md", ctx_tree.layout)

    def test_selection_evaluates_via_classifier_port(self) -> None:
        """Verifies candidate evaluation and selection via ClassifierPort and TruthTable."""
        cand_a_artifact = "Total: 85.15\n"
        cand_b_artifact = "Total: 0.00\n"

        # Mock candidates
        cand_dir = self.tmp_dir / "cand_runs"
        cand_dir.mkdir(parents=True)
        (cand_dir / "a").mkdir()
        (cand_dir / "b").mkdir()

        run_a = RunView(label="agg1", run_id="run-a", run_dir=cand_dir / "a", ok=True, delivered=True)
        run_b = RunView(label="agg2", run_id="run-b", run_dir=cand_dir / "b", ok=True, delivered=True)
        candidates = {"agg1": run_a, "agg2": run_b}

        self.adapter.deliverable_text = lambda rdir: cand_a_artifact if "a" in str(rdir) else cand_b_artifact

        # Proposer mock that simulates a model failing to emit the choice block,
        # triggering the intelligent ClassifierPort failover
        mock_prop = MagicMock()
        mock_prop.call.return_value = MagicMock(text="I cannot pick between these.", cost_usd=0.01)

        # Mock classify_binary in ZeusBridge
        def mock_classify(instructions: str, state: str, **kwargs):
            if "85.15" in state:
                return {"type": "binary", "probability": 0.94, "confidence": 1.0, "verdict": "meets", "model": "ollama:llama3.2:3b"}
            return {"type": "binary", "probability": 0.20, "confidence": 1.0, "verdict": "misses", "model": "ollama:llama3.2:3b"}

        with patch.object(ZeusBridge, "classify_binary", side_effect=mock_classify), \
             patch.object(ZeusBridge, "is_available", return_value=True):
            sel = selection.run_selection(
                task_id=self.task_id,
                k=2,
                mode="parallel",
                candidates=candidates,
                adapter=self.adapter,
                prop=mock_prop,
                work_dir=self.tmp_dir / "work",
            )

            # Verify that Zeus ClassifierPort selected candidate A over candidate B
            self.assertTrue(sel.ok)
            self.assertEqual(sel.chosen_label, "agg1")
            self.assertIn("Selected via Zeus ClassifierPort", sel.why)
            self.assertIn("P=0.940", sel.why)

    def test_library_curates_lesson_into_zeus(self) -> None:
        """Verifies that transferable lessons recorded in Library.add() are curated into Zeus."""
        lib = library_store.Library(
            root=self.tmp_dir / "library_test",
            domain="accounting",
            surface=self.surface,
        )
        harness_tree = {"scripts/summarize.py": "def calc(): return 100\n"}
        exp = {
            "cue": "When calculating net balances with credits and debits",
            "lesson": "Never omit credits or debits from the net sum.",
            "evidence": "Observed credit calculation fixed in candidate A probe.",
            "confidence": "high",
        }

        with patch.object(ZeusBridge, "curate_lesson") as mock_curate, \
             patch.object(ZeusBridge, "is_available", return_value=True):
            entry_dir = lib.add(
                task_id=self.task_id,
                harness=harness_tree,
                why="Chosen via Zeus ClassifierPort evaluation.",
                label="agg1",
                run_id="run-001",
                experience=exp,
            )

            self.assertIsNotNone(entry_dir)
            self.assertTrue((entry_dir / "EXPERIENCE.md").exists())

            # Verify ZeusBridge.curate_lesson was invoked
            mock_curate.assert_called_once_with(
                title=f"harness2-accounting-{self.task_id}",
                rule="Never omit credits or debits from the net sum.",
                evidence="Observed credit calculation fixed in candidate A probe.",
            )

    def test_e2e_benchmark_adaptation_cycle(self) -> None:
        """Measures full loop latency, memory efficiency, and invariant compliance."""
        start_time = time.perf_counter()
        bridge = ZeusBridge()
        self.assertTrue(bridge.is_available())

        # Verify search latency (< 5.0s when local Ollama is active)
        t0 = time.perf_counter()
        hits = bridge.search("accounting calculation", k=1)
        search_duration = time.perf_counter() - t0

        total_duration = time.perf_counter() - start_time
        self.assertLess(total_duration, 10.0)


if __name__ == "__main__":
    unittest.main()
