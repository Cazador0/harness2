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

"""Golden PR Replay benchmark adapter for private codebase evaluation.

Enables practitioners to evaluate coding agent harnesses by replaying recent, private,
merged internal pull requests from their own engineering organization, avoiding public
benchmark data contamination while testing against realistic production codebases.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class GoldenPRTask:
    """A task representing a private merged pull request to be replayed."""

    task_id: str
    title: str
    description: str
    repo_path: str
    base_commit: str
    merge_commit: str
    test_command: str
    domain: str = "general"
    changed_files: list[str] = field(default_factory=list)
    timeout_seconds: int = 300

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> GoldenPRTask:
        return cls(
            task_id=data["task_id"],
            title=data.get("title", ""),
            description=data.get("description", ""),
            repo_path=data["repo_path"],
            base_commit=data["base_commit"],
            merge_commit=data["merge_commit"],
            test_command=data.get("test_command", "pytest"),
            domain=data.get("domain", "general"),
            changed_files=data.get("changed_files", []),
            timeout_seconds=int(data.get("timeout_seconds", 300)),
        )


@dataclass
class GoldenPRResult:
    """Evaluation result of replaying a Golden PR task."""

    task_id: str
    passed: bool
    score: float  # 0.0 to 100.0
    return_code: int
    test_output: str
    patch_diff: str
    error: str | None = None


class GoldenPRAdapter:
    """Adapter managing repository setup, isolation, and evaluation for Golden PR replays."""

    def __init__(self, tasks: dict[str, GoldenPRTask]) -> None:
        self.tasks = tasks

    @classmethod
    def load_dataset(cls, manifest_path: Path) -> GoldenPRAdapter:
        """Load tasks from a JSON dataset manifest."""
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        tasks = {
            item["task_id"]: GoldenPRTask.from_dict(item)
            for item in data.get("tasks", [])
        }
        return cls(tasks)

    def save_dataset(self, manifest_path: Path) -> None:
        """Save tasks to a JSON dataset manifest."""
        data = {
            "version": "1.0.0",
            "benchmark": "golden_pr_replay",
            "tasks": [t.to_dict() for t in self.tasks.values()],
        }
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(data, indent=2), encoding="utf-8")

    def setup_workdir(self, task_id: str, dest_dir: Path) -> None:
        """Clone and checkout the repository at base_commit in a clean, detached state.

        To prevent future history leakage (where the agent inspects future commits to find
        the golden answer), this creates a shallow detached clone or checks out base_commit.
        """
        task = self.tasks[task_id]
        src_repo = Path(task.repo_path).resolve()
        if not src_repo.exists():
            raise FileNotFoundError(f"Source repository not found: {src_repo}")

        if dest_dir.exists():
            shutil.rmtree(dest_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)

        # Clone locally
        subprocess.run(
            ["git", "clone", "--no-checkout", str(src_repo), str(dest_dir)],
            check=True,
            capture_output=True,
            text=True,
        )

        # Checkout base_commit in detached state
        subprocess.run(
            ["git", "checkout", "--detach", task.base_commit],
            cwd=str(dest_dir),
            check=True,
            capture_output=True,
            text=True,
        )

        # Write task prompt file inside workspace
        instructions = (
            f"# Task: {task.title}\n\n"
            f"{task.description}\n\n"
            f"## Requirements\n"
            f"- Make all necessary changes to resolve the task.\n"
            f"- Ensure test command passes: `{task.test_command}`\n"
        )
        (dest_dir / "TASK_INSTRUCTIONS.md").write_text(instructions, encoding="utf-8")

    def evaluate_workdir(self, task_id: str, work_dir: Path) -> GoldenPRResult:
        """Run the test suite on the agent's work directory and capture patch diff."""
        task = self.tasks[task_id]
        if not work_dir.exists():
            return GoldenPRResult(
                task_id=task_id,
                passed=False,
                score=0.0,
                return_code=-1,
                test_output="",
                patch_diff="",
                error=f"Work directory does not exist: {work_dir}",
            )

        # Capture git diff produced by agent
        diff_res = subprocess.run(
            ["git", "diff", task.base_commit, "HEAD"],
            cwd=str(work_dir),
            capture_output=True,
            text=True,
        )
        patch = diff_res.stdout

        # Also include uncommitted unstaged/staged changes
        uncommitted = subprocess.run(
            ["git", "diff", "HEAD"],
            cwd=str(work_dir),
            capture_output=True,
            text=True,
        )
        if uncommitted.stdout:
            patch = (patch + "\n" + uncommitted.stdout).strip()

        # Run test command
        try:
            test_res = subprocess.run(
                task.test_command,
                shell=True,
                cwd=str(work_dir),
                capture_output=True,
                text=True,
                timeout=task.timeout_seconds,
            )
            passed = test_res.returncode == 0
            score = 100.0 if passed else 0.0
            output = (test_res.stdout + "\n" + test_res.stderr).strip()

            return GoldenPRResult(
                task_id=task_id,
                passed=passed,
                score=score,
                return_code=test_res.returncode,
                test_output=output,
                patch_diff=patch,
            )
        except subprocess.TimeoutExpired as exc:
            return GoldenPRResult(
                task_id=task_id,
                passed=False,
                score=0.0,
                return_code=-1,
                test_output=str(exc),
                patch_diff=patch,
                error=f"Test timed out after {task.timeout_seconds} seconds",
            )
        except Exception as exc:
            return GoldenPRResult(
                task_id=task_id,
                passed=False,
                score=0.0,
                return_code=-1,
                test_output="",
                patch_diff=patch,
                error=str(exc),
            )
