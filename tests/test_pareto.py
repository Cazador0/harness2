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

"""Unit tests for Pareto efficiency and Cost-per-Pass metrics."""

import unittest

from harness2.core.pareto import (
    RunMetrics,
    calculate_harness_tax,
    compute_pareto_frontier,
    dominates,
    generate_pareto_report,
)


class TestParetoMetrics(unittest.TestCase):
    def setUp(self) -> None:
        # A: Efficient baseline
        self.run_a = RunMetrics(
            name="Base Harness (Minimal)",
            score=50.0,
            cost_usd=10.0,
            resolved_tasks=25,
            total_tasks=50,
            latency_seconds=300.0,
        )
        # B: High-end Pareto optimal (higher score, proportionally acceptable cost)
        self.run_b = RunMetrics(
            name="Recursive k=2 (Optimized)",
            score=60.0,
            cost_usd=15.0,
            resolved_tasks=30,
            total_tasks=50,
            latency_seconds=500.0,
        )
        # C: Dominated run ("Harness Tax" failure: tiny score gain, 6x cost)
        self.run_c = RunMetrics(
            name="Bloated Multi-Agent Harness",
            score=52.0,
            cost_usd=60.0,
            resolved_tasks=26,
            total_tasks=50,
            latency_seconds=2000.0,
        )
        # D: Strictly dominated by run A (lower score, higher cost)
        self.run_d = RunMetrics(
            name="Broken Custom Harness",
            score=45.0,
            cost_usd=20.0,
            resolved_tasks=20,
            total_tasks=50,
            latency_seconds=400.0,
        )

    def test_cost_per_pass_calculation(self) -> None:
        self.assertEqual(self.run_a.cost_per_pass, 0.40)  # $10 / 25
        self.assertEqual(self.run_b.cost_per_pass, 0.50)  # $15 / 30
        self.assertAlmostEqual(self.run_c.cost_per_pass, 60.0 / 26, places=2)

        zero_pass_run = RunMetrics(
            name="Zero Pass",
            score=0.0,
            cost_usd=10.0,
            resolved_tasks=0,
            total_tasks=50,
        )
        self.assertEqual(zero_pass_run.cost_per_pass, float("inf"))

    def test_pareto_dominance(self) -> None:
        # run_a (score 50, cost 10) dominates run_d (score 45, cost 20)
        self.assertTrue(dominates(self.run_a, self.run_d))
        self.assertFalse(dominates(self.run_d, self.run_a))

        # run_a and run_b do not dominate each other (tradeoff between score and cost)
        self.assertFalse(dominates(self.run_a, self.run_b))
        self.assertFalse(dominates(self.run_b, self.run_a))

    def test_compute_pareto_frontier(self) -> None:
        runs = [self.run_a, self.run_b, self.run_c, self.run_d]
        frontier = compute_pareto_frontier(runs)

        frontier_names = [r.name for r in frontier]
        # B and A should be on the frontier
        self.assertIn(self.run_b.name, frontier_names)
        self.assertIn(self.run_a.name, frontier_names)
        # C and D are dominated and should not be on the frontier
        self.assertNotIn(self.run_d.name, frontier_names)

    def test_harness_tax_calculation(self) -> None:
        tax = calculate_harness_tax(self.run_c, self.run_a)
        self.assertEqual(tax["score_delta"], 2.0)
        self.assertEqual(tax["cost_ratio"], 6.0)  # $60 vs $10 = 6x cost
        self.assertEqual(tax["marginal_cost_per_pt"], 25.0)  # ($60-$10)/2

    def test_generate_pareto_report_markdown(self) -> None:
        runs = [self.run_a, self.run_b, self.run_c]
        report = generate_pareto_report(runs, baseline_name=self.run_a.name)

        self.assertIn("Pareto Efficiency & Cost-per-Pass Analysis", report)
        self.assertIn("Pareto Optimal", report)
        self.assertIn("Harness Tax & Marginal Efficiency Insights", report)
        self.assertIn("6.00×", report)  # Cost ratio for bloated run


if __name__ == "__main__":
    unittest.main()
