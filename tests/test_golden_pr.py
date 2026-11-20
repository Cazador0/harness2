# Copyright 2026 Google LLC
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

"""Unit tests for Golden PR Replay benchmark adapter."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from harness2.benchmarks.golden_pr import (
    GoldenPRAdapter,
    GoldenPRResult,
    GoldenPRTask,
)


class TestGoldenPRReplay(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp(prefix="golden_pr_test_"))
        self.origin_repo = self.tmp_dir / "origin_repo"
        self.origin_repo.mkdir()

        # Initialize mock git repo
        subprocess.run(["git", "init"], cwd=str(self.origin_repo), check=True, capture_output=True)
        subprocess.run(
            ["git", "config", "user.name", "Tester"],
            cwd=str(self.origin_repo),
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "tester@example.com"],
            cwd=str(self.origin_repo),
            check=True,
        )

        # Base commit: buggy function and a test script
        (self.origin_repo / "calc.py").write_text("def add(a, b): return a - b\n")
        (self.origin_repo / "test_calc.py").write_text(
            "import calc\ndef test_add(): assert calc.add(2, 3) == 5\nif __name__ == '__main__': test_add()\n"
        )
        subprocess.run(["git", "add", "."], cwd=str(self.origin_repo), check=True)
        subprocess.run(
            ["git", "commit", "-m", "Initial commit with failing test"],
            cwd=str(self.origin_repo),
            check=True,
            capture_output=True,
        )
        base_rev = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(self.origin_repo),
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.base_commit = base_rev

        # Merge commit: fix the function
        (self.origin_repo / "calc.py").write_text("def add(a, b): return a + b\n")
        subprocess.run(["git", "add", "."], cwd=str(self.origin_repo), check=True)
        subprocess.run(
            ["git", "commit", "-m", "Fix add function"],
            cwd=str(self.origin_repo),
            check=True,
            capture_output=True,
        )
        merge_rev = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=str(self.origin_repo),
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.merge_commit = merge_rev

        self.task = GoldenPRTask(
            task_id="pr-101",
            title="Fix addition bug in calc.py",
            description="The add function returns a - b instead of a + b.",
            repo_path=str(self.origin_repo),
            base_commit=self.base_commit,
            merge_commit=self.merge_commit,
            test_command="python3 test_calc.py",
            changed_files=["calc.py"],
        )
        self.adapter = GoldenPRAdapter({self.task.task_id: self.task})

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_dataset_serialization(self) -> None:
        manifest_file = self.tmp_dir / "dataset.json"
        self.adapter.save_dataset(manifest_file)
        self.assertTrue(manifest_file.exists())

        loaded_adapter = GoldenPRAdapter.load_dataset(manifest_file)
        self.assertIn("pr-101", loaded_adapter.tasks)
        self.assertEqual(loaded_adapter.tasks["pr-101"].title, self.task.title)

    def test_setup_workdir_isolation(self) -> None:
        work_dir = self.tmp_dir / "agent_workdir"
        self.adapter.setup_workdir("pr-101", work_dir)

        # Check that workdir has base commit files
        self.assertTrue((work_dir / "calc.py").exists())
        self.assertTrue((work_dir / "TASK_INSTRUCTIONS.md").exists())

        # Check calc.py has buggy code at base_commit
        content = (work_dir / "calc.py").read_text()
        self.assertIn("return a - b", content)

    def test_evaluate_workdir_failing(self) -> None:
        work_dir = self.tmp_dir / "agent_workdir"
        self.adapter.setup_workdir("pr-101", work_dir)

        # Run test before fix - should fail
        res = self.adapter.evaluate_workdir("pr-101", work_dir)
        self.assertFalse(res.passed)
        self.assertEqual(res.score, 0.0)

    def test_evaluate_workdir_passing(self) -> None:
        work_dir = self.tmp_dir / "agent_workdir"
        self.adapter.setup_workdir("pr-101", work_dir)

        # Simulate agent fix
        (work_dir / "calc.py").write_text("def add(a, b): return a + b\n")

        # Run evaluation - should pass
        res = self.adapter.evaluate_workdir("pr-101", work_dir)
        self.assertTrue(res.passed)
        self.assertEqual(res.score, 100.0)
        self.assertIn("+def add(a, b): return a + b", res.patch_diff)


if __name__ == "__main__":
    unittest.main()
