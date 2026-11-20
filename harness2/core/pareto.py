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

"""Pareto efficiency and Cost-per-Pass evaluation for coding agent harnesses.

Evaluates coding agent configurations across multiple dimensions (accuracy vs. cost-per-pass
vs. latency) to expose the 'Harness Tax': situations where heavy scaffolding drastically
inflates token consumption and inference cost for negligible accuracy gains.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Sequence


@dataclass(frozen=True)
class RunMetrics:
    """Metrics recorded for one benchmark run of a model-harness pair."""

    name: str
    score: float  # Percentage accuracy (0.0 to 100.0)
    cost_usd: float  # Total dollar cost of the run
    resolved_tasks: int  # Number of tasks resolved / passed
    total_tasks: int  # Total tasks evaluated
    latency_seconds: float = 0.0  # Total or average wall-clock latency
    tokens_total: int = 0  # Total tokens consumed (input + output)

    @property
    def cost_per_pass(self) -> float:
        """Cost per resolved task in USD. Returns infinity if 0 tasks resolved."""
        if self.resolved_tasks <= 0:
            return float("inf")
        return self.cost_usd / self.resolved_tasks

    @property
    def pass_rate(self) -> float:
        """Percentage of tasks resolved."""
        if self.total_tasks <= 0:
            return 0.0
        return (self.resolved_tasks / self.total_tasks) * 100.0


def dominates(
    a: RunMetrics,
    b: RunMetrics,
    *,
    maximize: tuple[str, ...] = ("score",),
    minimize: tuple[str, ...] = ("cost_per_pass",),
) -> bool:
    """Check if run 'a' Pareto-dominates run 'b'.

    'a' dominates 'b' iff 'a' is no worse than 'b' on all specified objectives,
    and strictly better on at least one objective.
    """
    at_least_as_good = True
    strictly_better = False

    for obj in maximize:
        val_a = getattr(a, obj)
        val_b = getattr(b, obj)
        if val_a < val_b:
            at_least_as_good = False
            break
        if val_a > val_b:
            strictly_better = True

    if not at_least_as_good:
        return False

    for obj in minimize:
        val_a = getattr(a, obj)
        val_b = getattr(b, obj)
        if val_a > val_b:
            at_least_as_good = False
            break
        if val_a < val_b:
            strictly_better = True

    return at_least_as_good and strictly_better


def compute_pareto_frontier(
    runs: Sequence[RunMetrics],
    *,
    maximize: tuple[str, ...] = ("score",),
    minimize: tuple[str, ...] = ("cost_per_pass",),
) -> list[RunMetrics]:
    """Identify the Pareto-optimal frontier among candidate benchmark runs.

    Returns the subset of runs that are non-dominated, sorted by score descending.
    """
    if not runs:
        return []

    frontier: list[RunMetrics] = []
    for candidate in runs:
        is_dominated = False
        for other in runs:
            if candidate != other and dominates(
                other, candidate, maximize=maximize, minimize=minimize
            ):
                is_dominated = True
                break
        if not is_dominated:
            frontier.append(candidate)

    return sorted(frontier, key=lambda r: r.score, reverse=True)


def calculate_harness_tax(
    candidate: RunMetrics,
    baseline: RunMetrics,
) -> dict[str, float]:
    """Calculate the cost multiplier, accuracy delta, and marginal cost per point of accuracy."""
    score_delta = candidate.score - baseline.score
    cost_ratio = (
        candidate.cost_usd / baseline.cost_usd
        if baseline.cost_usd > 0
        else float("inf")
    )
    cost_per_pass_ratio = (
        candidate.cost_per_pass / baseline.cost_per_pass
        if baseline.cost_per_pass > 0
        else float("inf")
    )
    marginal_cost_per_pt = (
        (candidate.cost_usd - baseline.cost_usd) / score_delta
        if score_delta > 0
        else float("inf")
    )

    return {
        "score_delta": score_delta,
        "cost_ratio": cost_ratio,
        "cost_per_pass_ratio": cost_per_pass_ratio,
        "marginal_cost_per_pt": marginal_cost_per_pt,
    }


def generate_pareto_report(
    runs: Sequence[RunMetrics],
    *,
    baseline_name: str | None = None,
    title: str = "Pareto Efficiency & Cost-per-Pass Analysis",
) -> str:
    """Generate a publication-ready Markdown report analyzing Pareto efficiency and Harness Tax."""
    if not runs:
        return "No run metrics provided for Pareto analysis."

    frontier = compute_pareto_frontier(runs)
    frontier_names = {r.name for r in frontier}

    baseline = None
    if baseline_name:
        baseline = next((r for r in runs if r.name == baseline_name), None)
    if not baseline and runs:
        # Default baseline: lowest cost run
        baseline = min(runs, key=lambda r: r.cost_usd)

    lines = [
        f"### {title}",
        "",
        "| Configuration | Score | Passed | Total Cost | Cost / Pass | Latency | Pareto Status |",
        "|---|---|---|---|---|---|---|",
    ]

    for r in sorted(runs, key=lambda x: x.score, reverse=True):
        cost_pass_str = (
            f"${r.cost_per_pass:.2f}" if r.cost_per_pass != float("inf") else "N/A"
        )
        status = "**Pareto Optimal**" if r.name in frontier_names else "Dominated"
        lines.append(
            f"| `{r.name}` | {r.score:.2f}% | {r.resolved_tasks}/{r.total_tasks} | "
            f"${r.cost_usd:.2f} | {cost_pass_str} | {r.latency_seconds:.1f}s | {status} |"
        )

    lines.append("")
    lines.append("#### Harness Tax & Marginal Efficiency Insights")

    for r in runs:
        if r.name == baseline.name:
            continue
        tax = calculate_harness_tax(r, baseline)
        if tax["score_delta"] > 0:
            lines.append(
                f"- **`{r.name}` vs Baseline (`{baseline.name}`)**: +{tax['score_delta']:.2f}% score "
                f"at **{tax['cost_ratio']:.2f}×** total spend (${r.cost_usd:.2f} vs ${baseline.cost_usd:.2f}). "
                f"Cost-per-pass increased by **{tax['cost_per_pass_ratio']:.2f}×** "
                f"(${r.cost_per_pass:.2f} vs ${baseline.cost_per_pass:.2f}). "
                f"Marginal cost: **${tax['marginal_cost_per_pt']:.2f}** per +1% score."
            )
        else:
            lines.append(
                f"- **`{r.name}` vs Baseline (`{baseline.name}`)**: {tax['score_delta']:.2f}% score "
                f"with {tax['cost_ratio']:.2f}× cost (Dominated: negative return on spend)."
            )

    return "\n".join(lines)
