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

"""Unit tests for SandboxGuard and anti-leakage network egress controls."""

import unittest

from harness2.core.sandbox import (
    NetworkEgressPolicy,
    SandboxGuard,
    SandboxViolationError,
)


class TestSandboxGuards(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = NetworkEgressPolicy(enforce_offline=True)
        self.guard = SandboxGuard(self.policy)

    def test_benign_commands_allowed(self) -> None:
        benign_commands = [
            "python3 -m unittest discover tests",
            "cat src/main.py",
            "pytest -v",
            "git status",
            "git diff HEAD",
            "grep -rn 'def add' .",
        ]
        for cmd in benign_commands:
            self.assertEqual(self.policy.check_command(cmd), [])
            # Should not raise
            self.guard.audit_command(cmd)

    def test_blocked_network_domains_detected(self) -> None:
        malicious_commands = [
            "curl -O https://huggingface.co/datasets/benchmarks/rubrics/task_1.json",
            "wget https://raw.githubusercontent.com/evals/test_answer.py",
            "git clone https://github.com/secret/repo.git",
        ]
        for cmd in malicious_commands:
            violations = self.policy.check_command(cmd)
            self.assertTrue(len(violations) > 0)
            with self.assertRaises(SandboxViolationError):
                self.guard.audit_command(cmd)

    def test_git_leakage_inspection_detected(self) -> None:
        git_leak_commands = [
            "git log -p",
            "git log --patch",
            "git diff origin/main",
            "git show origin/test_patch",
            "git fetch origin",
            "git pull",
        ]
        for cmd in git_leak_commands:
            violations = self.policy.check_command(cmd)
            self.assertTrue(len(violations) > 0)
            with self.assertRaises(SandboxViolationError):
                self.guard.audit_command(cmd)

    def test_iptables_rules_generation(self) -> None:
        rules = self.policy.generate_iptables_rules()
        self.assertTrue(any("lo -j ACCEPT" in r for r in rules))
        self.assertTrue(any("OUTPUT -j DROP" in r for r in rules))

    def test_audit_trajectory_findings(self) -> None:
        trajectory = """
        User: Solve the bug in parser.py
        Assistant: I will inspect the git log to find the patch.
        $ git log -p
        Assistant: Now let me download the rubric.
        $ curl https://huggingface.co/rubrics.json
        $ pytest
        """
        findings = self.guard.audit_trajectory(trajectory)
        self.assertEqual(len(findings), 3)  # git log -p, huggingface domain, curl command


if __name__ == "__main__":
    unittest.main()
