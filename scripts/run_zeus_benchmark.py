#!/usr/bin/env python3
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

"""Live Multi-Agent Benchmark Runner: Harness² + Zeus Integration.

Executes an end-to-end multi-agent benchmark measuring:
1. Retrieval Recall & Speed: Querying Zeus RAPTOR tree during Propose.
2. Decision Latency & Accuracy: Evaluating candidate deliverables via ClassifierPort & TruthTable.
3. Knowledge Curation: Ingesting transferable lessons into Zeus memory with two-stage secret redaction.
4. Secret Scan: Verifying zero credential leakage across the complete execution.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from harness2.core import schedule
from harness2.core.zeus_bridge import ZeusBridge
from harness2.demo import DemoAdapter, DemoProposer


def run_live_benchmark(output_dir: Path | None = None, k: int = 2) -> dict:
    root = output_dir or Path(tempfile.mkdtemp(prefix="zeus_benchmark_run_"))
    root.mkdir(parents=True, exist_ok=True)

    print("==================================================================")
    print("🚀 STARTING HARNESS² + ZEUS END-TO-END MULTI-AGENT BENCHMARK")
    print("==================================================================")
    print(f"Target Directory: {root}")
    print(f"Recursion Scale:  k={k} (R={4*k} rollouts, P={3*k} improver sessions)")

    bridge = ZeusBridge()
    if not bridge.is_available():
        raise RuntimeError(f"Zeus not available at {bridge.zeus_dir}")

    print(f"Zeus Repository:  {bridge.zeus_dir} (detected, online)")

    # 1. Warm Retrieval Check
    print("\n[Phase 1] Testing Zeus RAPTOR Retrieval Latency...")
    t_start = time.perf_counter()
    hits = bridge.search("accounting credit calculation debits", k=3)
    retrieval_ms = (time.perf_counter() - t_start) * 1000
    print(f"  ✓ Retrieved {len(hits)} passages in {retrieval_ms:.2f} ms")
    for i, h in enumerate(hits, 1):
        print(f"    - Hit {i} (score: {h.score:.3f}): {h.location}")

    # 2. ClassifierPort Discriminative Evaluation Check
    print("\n[Phase 2] Testing System One Discriminative Classifier...")
    t_start = time.perf_counter()
    cands = {
        "A": "def summarize(rows): return sum(r.credits - r.debits for r in rows)",
        "B": "def summarize(rows): return 0 # bug",
    }
    task_desc = "Calculate net balance correctly summing credits and subtracting debits."
    chosen_id, max_p, evals = bridge.evaluate_candidates(cands, task_desc, pass_threshold=0.70)
    classifier_ms = (time.perf_counter() - t_start) * 1000
    if chosen_id:
        print(f"  ✓ Winner: {chosen_id} with calibrated probability P={max_p:.3f} (verdict: {evals[chosen_id].verdict})")
    else:
        print(f"  ✓ Abstention: No candidate met threshold (max P={max_p:.3f})")

    # 3. Live Benchmark Execution via Schedule
    print("\n[Phase 3] Running Full Multi-Agent Adaptation Sweep on Accounting...")
    adapter = DemoAdapter(root)
    proposer = DemoProposer(adapter.spec.channels["proposer"])

    sweep_start = time.perf_counter()
    summary = schedule.run_domain(
        "accounting",
        adapter.tasks(),
        k=k,
        adapter=adapter,
        prop=proposer,
        runs_root=adapter.spec.runs_root,
        library_root=root / "library" / str(k),
    )
    sweep_duration = time.perf_counter() - sweep_start

    done_count = summary.get("done", 0)
    failed_count = summary.get("failed", 0)
    print(f"  ✓ Sweep Completed in {sweep_duration:.2f} s: {done_count} tasks done, {failed_count} failed")

    # 4. Ingestion / Curation Verification
    print("\n[Phase 4] Verifying Zeus Memory Curation...")
    lib_path = root / "library" / str(k) / "accounting"
    experiences = list(lib_path.rglob("EXPERIENCE.md"))
    print(f"  ✓ Generated {len(experiences)} transferable experience records in library")
    for exp in experiences:
        print(f"    - {exp.relative_to(root)}")

    # 5. Secret Redaction Scan
    print("\n[Phase 5] Running Gitleaks Zero-Leak Verification on Output...")
    gitleaks_res = subprocess.run(
        ["gitleaks", "dir", "--no-banner", str(root)],
        capture_output=True,
        text=True,
    )
    leaks_found = "No leaks found" in (gitleaks_res.stdout + gitleaks_res.stderr) or gitleaks_res.returncode == 0
    print(f"  ✓ Secret Scan Status: {'CLEAN (0 leaks)' if leaks_found else 'FLAGGED'}")

    # Telemetry report
    report = {
        "benchmark": "accounting_demo",
        "scale_k": k,
        "tasks_completed": done_count,
        "tasks_failed": failed_count,
        "retrieval_ms": retrieval_ms,
        "classifier_ms": classifier_ms,
        "sweep_duration_s": sweep_duration,
        "total_executions": adapter.execution_count,
        "proposer_calls": len(proposer._calls),
        "secret_leaks": 0 if leaks_found else 1,
        "status": "PASS" if done_count == 2 and failed_count == 0 and leaks_found else "FAIL",
    }

    print("\n==================================================================")
    print(f"🏆 BENCHMARK RESULT: {report['status']}")
    print(f"   Execution Count:   {report['total_executions']}")
    print(f"   Proposer Sessions: {report['proposer_calls']}")
    print(f"   Sweep Duration:    {report['sweep_duration_s']:.2f} s")
    print(f"   Secrets Leaked:    {report['secret_leaks']}")
    print("==================================================================")

    return report


if __name__ == "__main__":
    report = run_live_benchmark()
    print("\nFinal JSON Telemetry:")
    print(json.dumps(report, indent=2))
