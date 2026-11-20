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

"""Unit tests for decoupled Model and Harness benchmark reporting."""

import json
import unittest

from harness2.core.manifest import (
    BenchmarkManifest,
    ContextStrategy,
    HarnessSpec,
    ModelSpec,
    ToolDefinition,
)
from harness2.core.report import Summary, create_manifest


class TestManifestDecoupling(unittest.TestCase):
    def setUp(self) -> None:
        self.model = ModelSpec(
            model_id="gemini-3.5-flash",
            provider="google",
            family="gemini",
            temperature=0.2,
            context_window=1_000_000,
            reasoning_effort="high",
        )
        self.tools = [
            ToolDefinition(
                name="replace_file_content",
                description="Precise single-match file edit tool",
                execution_mode="direct",
            ),
            ToolDefinition(
                name="run_command",
                description="Sandboxed terminal command execution",
                execution_mode="sandbox_bash",
            ),
        ]
        self.ctx = ContextStrategy(
            compaction_strategy="summary_prune",
            max_history_turns=50,
            token_budget=64_000,
            system_prompt_version="2.1",
        )
        self.harness = HarnessSpec(
            harness_id="opencode-harness-v2",
            harness_version="2.0.0",
            tools=self.tools,
            context_strategy=self.ctx,
            max_step_budget=100,
            timeout_seconds=1800,
            subagent_allowed=False,
            recursion_k=2,
        )

    def test_model_spec_validation(self) -> None:
        with self.assertRaises(ValueError):
            ModelSpec(model_id="", provider="google")
        with self.assertRaises(ValueError):
            ModelSpec(model_id="gemini", provider="")

    def test_harness_fingerprint_deterministic(self) -> None:
        fp1 = self.harness.compute_fingerprint()
        fp2 = self.harness.compute_fingerprint()
        self.assertEqual(fp1, fp2)
        self.assertEqual(self.harness.fingerprint, fp1)

        # Modifying a tool alters the fingerprint
        modified_harness = HarnessSpec(
            harness_id="opencode-harness-v2",
            harness_version="2.0.0",
            tools=[self.tools[0]],
            context_strategy=self.ctx,
            max_step_budget=100,
            timeout_seconds=1800,
        )
        self.assertNotEqual(fp1, modified_harness.fingerprint)

    def test_manifest_roundtrip_serialization(self) -> None:
        manifest = BenchmarkManifest(
            benchmark_name="SWE-bench Verified",
            benchmark_version="1.0.0",
            model=self.model,
            harness=self.harness,
            task_count=500,
            score=54.2,
            all_pass_rate=54.2,
            cost_usd=124.50,
        )
        errs = manifest.validate()
        self.assertEqual(errs, [])

        json_str = manifest.to_json()
        parsed = json.loads(json_str)
        self.assertEqual(parsed["benchmark_name"], "SWE-bench Verified")
        self.assertEqual(parsed["model"]["model_id"], "gemini-3.5-flash")
        self.assertEqual(parsed["harness"]["harness_id"], "opencode-harness-v2")
        self.assertEqual(len(parsed["harness"]["tools"]), 2)

        reconstructed = BenchmarkManifest.from_dict(parsed)
        self.assertEqual(reconstructed.benchmark_name, manifest.benchmark_name)
        self.assertEqual(reconstructed.model.model_id, manifest.model.model_id)
        self.assertEqual(reconstructed.harness.fingerprint, manifest.harness.fingerprint)
        self.assertEqual(reconstructed.score, manifest.score)

    def test_manifest_markdown_rendering(self) -> None:
        manifest = BenchmarkManifest(
            benchmark_name="JobBench",
            benchmark_version="1.2.0",
            model=self.model,
            harness=self.harness,
            task_count=80,
            score=68.5,
            all_pass_rate=65.0,
            cost_usd=42.10,
        )
        md = manifest.to_markdown()
        self.assertIn("Decoupled Benchmark Report", md)
        self.assertIn("gemini-3.5-flash", md)
        self.assertIn("opencode-harness-v2", md)
        self.assertIn("replace_file_content", md)
        self.assertIn("Score: 68.50%", md)

    def test_create_manifest_from_summary(self) -> None:
        summary = Summary(
            mode="agg",
            k=2,
            n=40,
            score=72.5,
            all_pass=70.0,
            usd=35.50,
            chose_final=30,
            kept_base=5,
        )
        manifest = create_manifest(
            summary, self.model, self.harness, benchmark_name="JobBench"
        )
        self.assertEqual(manifest.task_count, 40)
        self.assertEqual(manifest.score, 72.5)
        self.assertEqual(manifest.cost_usd, 35.50)
        self.assertEqual(manifest.metadata["chose_final"], 30)


if __name__ == "__main__":
    unittest.main()
