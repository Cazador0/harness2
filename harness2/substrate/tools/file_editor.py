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

"""Specialized, robust file-editing primitive for coding agent sessions.

Replaces fragile shell commands (`sed`, `awk`, `cat <<EOF`) with deterministic,
uniqueness-checked string replacement and AST syntax validation to prevent file corruption
and infinite editing loops during multi-turn coding agent sessions.
"""

from __future__ import annotations

import ast
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path


class ReplacementError(Exception):
    """Base exception for file editing errors."""


class AmbiguousTargetError(ReplacementError):
    """Raised when target_content matches multiple locations and allow_multiple is False."""


class TargetNotFoundError(ReplacementError):
    """Raised when target_content cannot be found in the specified line range."""


class SyntaxValidationError(ReplacementError):
    """Raised when a proposed replacement introduces a syntax error in the source file."""


@dataclass
class EditResult:
    """Result of an atomic file modification."""

    path: Path
    occurrences_replaced: int
    bytes_written: int
    lines_total: int


class FileEditor:
    """Deterministic, robust file editing engine."""

    @staticmethod
    def replace_content(
        path: str | Path,
        target_content: str,
        replacement_content: str,
        *,
        start_line: int | None = None,
        end_line: int | None = None,
        allow_multiple: bool = False,
        validate_syntax: bool = True,
    ) -> EditResult:
        """Replace exact occurrences of target_content in a file with atomic rollback.

        Args:
            path: Target file path.
            target_content: The exact substring to replace.
            replacement_content: The replacement string.
            start_line: Optional 1-indexed start line boundary.
            end_line: Optional 1-indexed end line boundary.
            allow_multiple: If False, raises AmbiguousTargetError when multiple matches exist.
            validate_syntax: If True and the file is Python, ensures modified file parses.
        """
        target_path = Path(path).resolve()
        if not target_path.is_file():
            raise FileNotFoundError(f"Target file not found: {target_path}")

        original_text = target_path.read_text(encoding="utf-8")
        lines = original_text.splitlines(keepends=True)
        total_lines = len(lines)

        # Range bounds validation
        if start_line is not None and (start_line < 1 or start_line > total_lines):
            raise IndexError(f"start_line {start_line} out of bounds (1..{total_lines})")
        if end_line is not None and (end_line < 1 or end_line > total_lines):
            raise IndexError(f"end_line {end_line} out of bounds (1..{total_lines})")
        if start_line and end_line and start_line > end_line:
            raise ValueError(f"start_line ({start_line}) must be <= end_line ({end_line})")

        # Determine search range
        s_idx = (start_line - 1) if start_line else 0
        e_idx = end_line if end_line else total_lines

        prefix_text = "".join(lines[:s_idx])
        scoped_text = "".join(lines[s_idx:e_idx])
        suffix_text = "".join(lines[e_idx:])

        count = scoped_text.count(target_content)
        if count == 0:
            scope_str = (
                f" in lines {start_line}..{end_line}"
                if (start_line or end_line)
                else ""
            )
            raise TargetNotFoundError(
                f"Target content not found in {target_path.name}{scope_str}.\n"
                f"Ensure exact character match including leading indentation and whitespace."
            )

        if count > 1 and not allow_multiple:
            raise AmbiguousTargetError(
                f"Found {count} occurrences of target content in {target_path.name}. "
                f"Narrow the search with start_line and end_line, or set allow_multiple=True."
            )

        new_scoped_text = scoped_text.replace(target_content, replacement_content)
        new_full_text = prefix_text + new_scoped_text + suffix_text

        # Validate syntax if editing Python file
        if validate_syntax and target_path.suffix.lower() == ".py":
            try:
                ast.parse(new_full_text, filename=str(target_path))
            except SyntaxError as exc:
                raise SyntaxValidationError(
                    f"Syntax error introduced in {target_path.name} at line {exc.lineno}: {exc.msg}\n"
                    f"Edit was automatically rejected and original file content was preserved."
                ) from exc

        # Atomic write via temporary file
        parent_dir = target_path.parent
        with tempfile.NamedTemporaryFile(
            "w", dir=parent_dir, delete=False, encoding="utf-8"
        ) as tmp:
            tmp.write(new_full_text)
            tmp_path = Path(tmp.name)

        tmp_path.replace(target_path)

        new_lines_count = len(new_full_text.splitlines())
        return EditResult(
            path=target_path,
            occurrences_replaced=count,
            bytes_written=len(new_full_text.encode("utf-8")),
            lines_total=new_lines_count,
        )


def replace_file_content(
    path: str | Path,
    target_content: str,
    replacement_content: str,
    *,
    start_line: int | None = None,
    end_line: int | None = None,
    allow_multiple: bool = False,
    validate_syntax: bool = True,
) -> EditResult:
    """Convenience wrapper for FileEditor.replace_content."""
    return FileEditor.replace_content(
        path=path,
        target_content=target_content,
        replacement_content=replacement_content,
        start_line=start_line,
        end_line=end_line,
        allow_multiple=allow_multiple,
        validate_syntax=validate_syntax,
    )


TOOL_GUIDANCE_EDITING = """## File Editing Rules (Robust Replacement Primitive)
Use the `replace_file_content` tool instead of terminal commands (`sed`, `cat <<EOF`, or `echo`)
when modifying source files:
1. Always specify exact character matches for `target_content`, preserving indentation.
2. If `target_content` appears multiple times, provide `start_line` and `end_line` boundaries.
3. Edits that introduce Python syntax errors will automatically trigger a rollback and error report.
"""
