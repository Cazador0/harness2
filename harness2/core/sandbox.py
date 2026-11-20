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

"""Strict sandbox guards and network egress anti-leakage controls.

Prevents agents during benchmark sessions from escaping the sandbox, accessing remote
repositories (e.g. GitHub, Hugging Face) to download test rubrics or solutions, or
inspecting future git history containing benchmark test patches.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Sequence

DEFAULT_BLOCKED_DOMAINS: tuple[str, ...] = (
    "github.com",
    "raw.githubusercontent.com",
    "api.github.com",
    "huggingface.co",
    "hf.co",
    "gitlab.com",
    "bitbucket.org",
    "gist.githubusercontent.com",
)

GIT_LEAK_PATTERNS: tuple[re.Pattern, ...] = (
    re.compile(r"\bgit\s+log\s+.*-(?:p|u|patch)\b", re.IGNORECASE),
    re.compile(r"\bgit\s+diff\s+.*(?:origin/|heads/|tags/)\b", re.IGNORECASE),
    re.compile(r"\bgit\s+show\s+.*(?:origin/|test|golden|answer)\b", re.IGNORECASE),
    re.compile(r"\bgit\s+fetch\b", re.IGNORECASE),
    re.compile(r"\bgit\s+pull\b", re.IGNORECASE),
)

NETWORK_COMMAND_PATTERNS: tuple[re.Pattern, ...] = (
    re.compile(r"\b(?:curl|wget|fetch|http|aria2c)\s+.*https?://[^\s'\"]+", re.IGNORECASE),
    re.compile(r"\b(?:git\s+clone)\s+https?://[^\s'\"]+", re.IGNORECASE),
    re.compile(r"\bpython(?:3)?\s+-c\s+.*(?:urllib|requests|aiohttp|httpx)", re.IGNORECASE),
)


class SandboxViolationError(RuntimeError):
    """Raised when an agent attempts an unauthorized network egress or test-leak operation."""


@dataclass
class NetworkEgressPolicy:
    """Network egress isolation policy defining blocked and allowed outbound domains."""

    blocked_domains: tuple[str, ...] = DEFAULT_BLOCKED_DOMAINS
    allow_loopback: bool = True
    enforce_offline: bool = True

    def check_command(self, command: str) -> list[str]:
        """Inspect a shell command for unauthorized network access or git history snooping."""
        violations: list[str] = []

        # Check git inspection patterns targeting remote or hidden branches
        for pattern in GIT_LEAK_PATTERNS:
            if pattern.search(command):
                violations.append(
                    f"Git history leak attempt detected in command: {command!r}"
                )

        # Check network access attempts to blocked domains
        for domain in self.blocked_domains:
            escaped = re.escape(domain)
            if re.search(rf"\b{escaped}\b", command, re.IGNORECASE):
                violations.append(
                    f"Prohibited network destination {domain!r} referenced in command: {command!r}"
                )

        # If offline enforcement is enabled, flag external web access commands
        if self.enforce_offline:
            for net_pat in NETWORK_COMMAND_PATTERNS:
                match = net_pat.search(command)
                if match:
                    violations.append(
                        f"Prohibited external network call under offline policy: {match.group(0)!r}"
                    )

        return violations

    def generate_iptables_rules(self) -> list[str]:
        """Generate Linux iptables rules to strictly isolate the sandbox network."""
        rules = [
            "# Allow loopback traffic",
            "iptables -A OUTPUT -o lo -j ACCEPT",
            "# Allow established connections if permitted",
            "iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT",
        ]
        if self.enforce_offline:
            rules.append("# Drop all other outbound network traffic")
            rules.append("iptables -A OUTPUT -j DROP")
        else:
            for domain in self.blocked_domains:
                rules.append(f"# Block domain: {domain}")
                rules.append(f"iptables -A OUTPUT -p tcp -m string --string '{domain}' --algo bm -j DROP")
        return rules


class SandboxGuard:
    """Tripwire and enforcement coordinator protecting benchmark integrity."""

    def __init__(self, policy: NetworkEgressPolicy | None = None) -> None:
        self.policy = policy or NetworkEgressPolicy()

    def audit_command(self, command: str) -> None:
        """Validate command before execution, raising SandboxViolationError if unsafe."""
        violations = self.policy.check_command(command)
        if violations:
            raise SandboxViolationError(
                "Sandbox guard blocked execution:\n" + "\n".join(f"- {v}" for v in violations)
            )

    def audit_trajectory(self, trajectory_text: str) -> list[str]:
        """Scan completed rollout trajectory for evidence of network egress or git leakage."""
        findings: list[str] = []
        for line in trajectory_text.splitlines():
            line_str = line.strip()
            # Extract shell command if present in trajectory
            if line_str.startswith("$ ") or line_str.startswith("bash ") or "command:" in line_str:
                violations = self.policy.check_command(line_str)
                findings.extend(violations)
        return findings
