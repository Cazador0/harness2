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

"""Zeus Bridge: Integration between Harness² and Zeus Knowledge & Classifier Core.

Connects the Harness² recursive improvement loop (Propose -> Probe -> Compose -> Select)
to Zeus:
1. Retrieval: Queries Zeus RAPTOR tree during Propose to inject prior transferable lessons.
2. Curation: Automatically curates lessons from EXPERIENCE.md into Zeus with 2-stage secret redaction.
3. Discrimination: Evaluates candidates via ClassifierPort (TypeSafe Jev / Ollama GBNF) and TruthTable.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

ZEUS_DIR = Path(os.environ.get("ZEUS_DIR", "/home/antigravity/Cazador0/zeus")).resolve()


class ZeusBridgeError(RuntimeError):
    """Raised when an operation against Zeus fails."""


@dataclass(frozen=True)
class ZeusHit:
    score: float
    location: str
    snippet: str


@dataclass
class CandidateEvaluation:
    candidate_id: str
    probability: float
    confidence: float
    verdict: str
    model: str


class ZeusBridge:
    """Zero-dependency client bridge to Zeus memory, retrieval, and classification services."""

    def __init__(self, zeus_dir: Path | str | None = None) -> None:
        self.zeus_dir = Path(zeus_dir or ZEUS_DIR).resolve()
        self.python_bin = self.zeus_dir / ".venv" / "bin" / "python3"

    def is_available(self) -> bool:
        """Returns True if Zeus repository and virtualenv are available on disk."""
        return self.python_bin.exists() and (self.zeus_dir / "src" / "zeus").is_dir()

    def _run_cli(self, args: list[str], timeout: float = 30.0) -> subprocess.CompletedProcess[str]:
        if not self.is_available():
            raise ZeusBridgeError(f"Zeus not found or virtualenv missing at {self.zeus_dir}")
        cmd = [str(self.python_bin), "-m", "zeus.cli"] + args
        try:
            return subprocess.run(
                cmd,
                cwd=str(self.zeus_dir),
                capture_output=True,
                text=True,
                check=True,
                timeout=timeout,
            )
        except subprocess.CalledProcessError as exc:
            msg = (exc.stderr or exc.stdout or "").strip()
            raise ZeusBridgeError(f"Zeus CLI failed (code {exc.returncode}): {msg}") from exc
        except subprocess.TimeoutExpired as exc:
            raise ZeusBridgeError(f"Zeus CLI timed out after {timeout}s: {' '.join(args)}") from exc

    def search(self, query: str, k: int = 5) -> list[ZeusHit]:
        """Search Zeus RAPTOR index for relevant lessons or context passages."""
        try:
            res = self._run_cli(["search", query, "--k", str(k)], timeout=15.0)
            hits: list[ZeusHit] = []
            for line in res.stdout.strip().splitlines():
                parts = line.split(maxsplit=2)
                if len(parts) >= 2:
                    score = float(parts[0]) if parts[0].replace(".", "", 1).isdigit() else 0.0
                    loc = parts[1]
                    snippet = parts[2] if len(parts) > 2 else ""
                    hits.append(ZeusHit(score=score, location=loc, snippet=snippet))
            return hits
        except Exception:
            return []

    def remember(
        self,
        content: str,
        agent: str = "harness2",
        session_id: str | None = None,
    ) -> dict[str, Any]:
        """Save a session note into Zeus memory (subject to two-stage secret redaction)."""
        args = ["remember", content, "--agent", agent]
        if session_id:
            args += ["--session-id", session_id]
        res = self._run_cli(args)
        return {"output": res.stdout.strip()}

    def curate_lesson(
        self,
        title: str,
        rule: str,
        evidence: str,
        sources: list[str] | None = None,
    ) -> dict[str, Any]:
        """Curate a lesson directly into Zeus knowledge/lessons/ with conflict detection."""
        args = ["curate", title, rule, evidence]
        if sources:
            for s in sources:
                args += ["--source", s]
        res = self._run_cli(args)
        return {"output": res.stdout.strip()}

    def classify_binary(
        self,
        instructions: str,
        state: str,
        criteria: str = "",
        force_local: bool = True,
    ) -> dict[str, Any]:
        """Evaluate a binary decision using ClassifierPort (System One / Ollama GBNF)."""
        args = ["classify", "binary", "-i", instructions, "-s", state, "--json"]
        if criteria:
            args += ["-c", criteria]
        if force_local:
            args += ["--local"]
        res = self._run_cli(args, timeout=25.0)
        try:
            return json.loads(res.stdout)
        except json.JSONDecodeError:
            return {"type": "refusal", "reason": res.stdout.strip()}

    def evaluate_candidates(
        self,
        candidates: Mapping[str, str],
        task_prompt: str,
        *,
        pass_threshold: float = 0.70,
        force_local: bool = True,
    ) -> tuple[str | None, float, dict[str, CandidateEvaluation]]:
        """Evaluate anonymous candidate deliverables against task instructions.
        
        Applies calibrated discriminative scoring and deterministic truth table logic.
        Returns:
            (selected_id, max_probability, evaluations_dict)
            selected_id is None if no candidate exceeds pass_threshold (fail-closed abstention).
        """
        evals: dict[str, CandidateEvaluation] = {}
        best_id: str | None = None
        max_p: float = -1.0

        for cid, content in candidates.items():
            inst = f"Does this candidate solution correctly solve the required task?\nTask: {task_prompt}"
            res = self.classify_binary(inst, content, force_local=force_local)
            
            p = float(res.get("probability", 0.0)) if res.get("type") == "binary" else 0.0
            conf = float(res.get("confidence", 0.0))
            verdict = str(res.get("verdict", "unsettled"))
            model = str(res.get("model", "unknown"))

            evals[cid] = CandidateEvaluation(
                candidate_id=cid,
                probability=p,
                confidence=conf,
                verdict=verdict,
                model=model,
            )

            if p > max_p:
                max_p = p
                best_id = cid

        if max_p >= pass_threshold:
            return best_id, max_p, evals

        # Abstain if below pass threshold
        return None, max(0.0, max_p), evals
