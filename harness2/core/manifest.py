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

"""Manifest schema and utilities for decoupled Model + Harness reporting.

Every benchmark score represents the joint capability of a foundation model and its
agent harness. This module enforces dual reporting: a benchmark result cannot be published
or serialized without explicitly documenting both the model parameters and the complete
harness specification (tool definitions, context compaction strategy, step budget, and fingerprint).
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


@dataclass(frozen=True)
class ModelSpec:
    """Specification of the foundation model used during evaluation."""

    model_id: str
    provider: str
    family: str | None = None
    temperature: float = 0.0
    context_window: int = 128_000
    reasoning_effort: str | None = None

    def __post_init__(self) -> None:
        if not self.model_id or not self.model_id.strip():
            raise ValueError("model_id must not be empty")
        if not self.provider or not self.provider.strip():
            raise ValueError("provider must not be empty")


@dataclass(frozen=True)
class ToolDefinition:
    """Metadata describing a tool available to the agent during execution."""

    name: str
    description: str = ""
    parameters_schema: dict[str, Any] | None = None
    execution_mode: str = "direct"  # e.g., 'direct', 'sandbox_bash', 'subagent'

    def __post_init__(self) -> None:
        if not self.name or not self.name.strip():
            raise ValueError("tool name must not be empty")


@dataclass(frozen=True)
class ContextStrategy:
    """Context construction, compaction, and history management strategy."""

    compaction_strategy: str = "truncation"  # 'sliding_window', 'truncation', 'summary_prune', 'verbatim'
    max_history_turns: int | None = None
    token_budget: int | None = None
    system_prompt_version: str | None = None


@dataclass
class HarnessSpec:
    """Complete specification of the agent harness runtime."""

    harness_id: str
    harness_version: str = "1.0.0"
    tools: list[ToolDefinition] = field(default_factory=list)
    context_strategy: ContextStrategy = field(default_factory=ContextStrategy)
    max_step_budget: int = 120
    timeout_seconds: int = 3600
    subagent_allowed: bool = False
    recursion_k: int = 1
    fingerprint: str = ""

    def __post_init__(self) -> None:
        if not self.harness_id or not self.harness_id.strip():
            raise ValueError("harness_id must not be empty")
        if not self.fingerprint:
            self.fingerprint = self.compute_fingerprint()

    def compute_fingerprint(self) -> str:
        """Derive a deterministic SHA-256 fingerprint from the harness configuration."""
        components = {
            "harness_id": self.harness_id,
            "harness_version": self.harness_version,
            "tools": sorted(t.name for t in self.tools),
            "context_strategy": asdict(self.context_strategy),
            "max_step_budget": self.max_step_budget,
            "timeout_seconds": self.timeout_seconds,
            "subagent_allowed": self.subagent_allowed,
            "recursion_k": self.recursion_k,
        }
        encoded = json.dumps(components, sort_keys=True).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()[:16]


@dataclass
class BenchmarkManifest:
    """Decoupled dual-dimension benchmark report linking Model and Harness specifications."""

    benchmark_name: str
    model: ModelSpec
    harness: HarnessSpec
    benchmark_version: str = "1.0.0"
    timestamp: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    task_count: int = 0
    score: float | None = None
    all_pass_rate: float | None = None
    cost_usd: float | None = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def validate(self) -> list[str]:
        """Validate that the manifest satisfies decoupling and reporting standards."""
        errors: list[str] = []
        if not self.benchmark_name.strip():
            errors.append("benchmark_name is required")
        if not self.model or not self.model.model_id:
            errors.append("Valid model specification is required")
        if not self.harness or not self.harness.harness_id:
            errors.append("Valid harness specification is required")
        if not self.harness.fingerprint:
            errors.append("Harness specification must contain a valid fingerprint")
        return errors

    def to_dict(self) -> dict[str, Any]:
        """Serialize manifest to a structured dictionary."""
        return {
            "benchmark_name": self.benchmark_name,
            "benchmark_version": self.benchmark_version,
            "timestamp": self.timestamp,
            "model": asdict(self.model),
            "harness": {
                "harness_id": self.harness.harness_id,
                "harness_version": self.harness.harness_version,
                "fingerprint": self.harness.fingerprint,
                "max_step_budget": self.harness.max_step_budget,
                "timeout_seconds": self.harness.timeout_seconds,
                "subagent_allowed": self.harness.subagent_allowed,
                "recursion_k": self.harness.recursion_k,
                "context_strategy": asdict(self.harness.context_strategy),
                "tools": [asdict(t) for t in self.harness.tools],
            },
            "results": {
                "task_count": self.task_count,
                "score": self.score,
                "all_pass_rate": self.all_pass_rate,
                "cost_usd": self.cost_usd,
            },
            "metadata": self.metadata,
        }

    def to_json(self, indent: int = 2) -> str:
        """Serialize manifest to JSON formatted string."""
        return json.dumps(self.to_dict(), indent=indent)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> BenchmarkManifest:
        """Deserialize manifest from dictionary."""
        model_data = data.get("model", {})
        model = ModelSpec(
            model_id=model_data.get("model_id", ""),
            provider=model_data.get("provider", ""),
            family=model_data.get("family"),
            temperature=float(model_data.get("temperature", 0.0)),
            context_window=int(model_data.get("context_window", 128_000)),
            reasoning_effort=model_data.get("reasoning_effort"),
        )

        harness_data = data.get("harness", {})
        ctx_data = harness_data.get("context_strategy", {})
        context_strategy = ContextStrategy(
            compaction_strategy=ctx_data.get("compaction_strategy", "truncation"),
            max_history_turns=ctx_data.get("max_history_turns"),
            token_budget=ctx_data.get("token_budget"),
            system_prompt_version=ctx_data.get("system_prompt_version"),
        )

        tools = [
            ToolDefinition(
                name=t.get("name", ""),
                description=t.get("description", ""),
                parameters_schema=t.get("parameters_schema"),
                execution_mode=t.get("execution_mode", "direct"),
            )
            for t in harness_data.get("tools", [])
        ]

        harness = HarnessSpec(
            harness_id=harness_data.get("harness_id", ""),
            harness_version=harness_data.get("harness_version", "1.0.0"),
            tools=tools,
            context_strategy=context_strategy,
            max_step_budget=int(harness_data.get("max_step_budget", 120)),
            timeout_seconds=int(harness_data.get("timeout_seconds", 3600)),
            subagent_allowed=bool(harness_data.get("subagent_allowed", False)),
            recursion_k=int(harness_data.get("recursion_k", 1)),
            fingerprint=harness_data.get("fingerprint", ""),
        )

        results = data.get("results", {})
        return cls(
            benchmark_name=data.get("benchmark_name", ""),
            benchmark_version=data.get("benchmark_version", "1.0.0"),
            timestamp=data.get("timestamp", ""),
            model=model,
            harness=harness,
            task_count=int(results.get("task_count", 0)),
            score=results.get("score"),
            all_pass_rate=results.get("all_pass_rate"),
            cost_usd=results.get("cost_usd"),
            metadata=data.get("metadata", {}),
        )

    def to_markdown(self) -> str:
        """Render a publication-ready Markdown table decoupling Model and Harness."""
        score_str = f"{self.score:.2f}%" if self.score is not None else "N/A"
        pass_str = f"{self.all_pass_rate:.2f}%" if self.all_pass_rate is not None else "N/A"
        cost_str = f"${self.cost_usd:.2f}" if self.cost_usd is not None else "N/A"
        tools_str = ", ".join(t.name for t in self.harness.tools) or "None"

        return f"""### Decoupled Benchmark Report: {self.benchmark_name} v{self.benchmark_version}

| Dimension | Specification | Details |
|---|---|---|
| **Model ID** | `{self.model.model_id}` | Provider: `{self.model.provider}` (Temp: `{self.model.temperature}`) |
| **Model Context** | `{self.model.context_window:,} tokens` | Reasoning Effort: `{self.model.reasoning_effort or 'standard'}` |
| **Harness ID** | `{self.harness.harness_id}` (v`{self.harness.harness_version}`) | Fingerprint: `{self.harness.fingerprint}` |
| **Tool Surface** | `{len(self.harness.tools)} tools` | `{tools_str}` |
| **Context Strategy** | `{self.harness.context_strategy.compaction_strategy}` | Max Turns: `{self.harness.context_strategy.max_history_turns or 'unlimited'}` |
| **Step Budget** | `{self.harness.max_step_budget} steps` | Timeout: `{self.harness.timeout_seconds}s` (Recursion k=`{self.harness.recursion_k}`) |
| **Benchmark Results** | **Score: {score_str}** | All-Pass: `{pass_str}` \| Evaluated: `{self.task_count} tasks` \| Cost: `{cost_str}` |
"""
