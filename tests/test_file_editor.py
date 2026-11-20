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

"""Unit tests for robust file editing primitive."""

import shutil
import tempfile
import unittest
from pathlib import Path

from harness2.substrate.tools.file_editor import (
    AmbiguousTargetError,
    FileEditor,
    SyntaxValidationError,
    TargetNotFoundError,
    replace_file_content,
)


class TestFileEditor(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp_dir = Path(tempfile.mkdtemp(prefix="file_editor_test_"))
        self.py_file = self.tmp_dir / "sample.py"
        self.py_file.write_text(
            "def foo():\n"
            "    value = 1\n"
            "    return value\n\n"
            "def bar():\n"
            "    value = 1\n"
            "    return value\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp_dir, ignore_errors=True)

    def test_unique_replacement_success(self) -> None:
        res = replace_file_content(
            self.py_file,
            target_content="def foo():\n    value = 1\n    return value",
            replacement_content="def foo():\n    value = 42\n    return value",
        )
        self.assertEqual(res.occurrences_replaced, 1)
        content = self.py_file.read_text(encoding="utf-8")
        self.assertIn("value = 42", content)
        self.assertIn("def bar():\n    value = 1", content)

    def test_ambiguous_target_error(self) -> None:
        # "    value = 1" appears twice
        with self.assertRaises(AmbiguousTargetError):
            replace_file_content(
                self.py_file,
                target_content="    value = 1\n",
                replacement_content="    value = 99\n",
                allow_multiple=False,
            )
        # Content unchanged
        content = self.py_file.read_text(encoding="utf-8")
        self.assertNotIn("99", content)

    def test_scoped_replacement_disambiguation(self) -> None:
        # Using start_line and end_line to disambiguate the first occurrence
        res = replace_file_content(
            self.py_file,
            target_content="    value = 1\n",
            replacement_content="    value = 99\n",
            start_line=1,
            end_line=3,
            allow_multiple=False,
        )
        self.assertEqual(res.occurrences_replaced, 1)
        content = self.py_file.read_text(encoding="utf-8")
        self.assertIn("def foo():\n    value = 99", content)
        self.assertIn("def bar():\n    value = 1", content)

    def test_target_not_found(self) -> None:
        with self.assertRaises(TargetNotFoundError):
            replace_file_content(
                self.py_file,
                target_content="nonexistent_symbol = True\n",
                replacement_content="something_else\n",
            )

    def test_syntax_validation_and_rollback(self) -> None:
        # Proposed replacement creates a syntax error in Python
        original_content = self.py_file.read_text(encoding="utf-8")
        with self.assertRaises(SyntaxValidationError):
            replace_file_content(
                self.py_file,
                target_content="def foo():\n",
                replacement_content="def foo(\n",  # Invalid syntax
                validate_syntax=True,
            )
        # Verify file content was not corrupted
        self.assertEqual(self.py_file.read_text(encoding="utf-8"), original_content)

    def test_allow_multiple_replacement(self) -> None:
        res = replace_file_content(
            self.py_file,
            target_content="    value = 1\n",
            replacement_content="    value = 100\n",
            allow_multiple=True,
        )
        self.assertEqual(res.occurrences_replaced, 2)
        content = self.py_file.read_text(encoding="utf-8")
        self.assertEqual(content.count("value = 100"), 2)


if __name__ == "__main__":
    unittest.main()
