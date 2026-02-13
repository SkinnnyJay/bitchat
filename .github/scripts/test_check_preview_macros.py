#!/usr/bin/env python3
"""
Unit tests for preview guard token detection behavior.
"""

from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import check_preview_macros  # noqa: E402


class PreviewMacroDetectionTests(unittest.TestCase):
    def test_detects_preview_token_at_start_of_code(self) -> None:
        content = """
            #Preview {
                Text("hi")
            }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2])

    def test_ignores_inline_comment_preview_token(self) -> None:
        content = """
            // #Preview {
            let value = 1 // #Preview should be ignored
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [])

    def test_ignores_block_comment_preview_token(self) -> None:
        content = """
            /* #Preview {
               Text("inside comment")
            } */
            let value = 1
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [])

    def test_detects_preview_after_block_comment_closes(self) -> None:
        content = """
            /* comment */
            #Preview("Name") {
                Text("real preview")
            }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_ignores_nested_block_comment_preview_token(self) -> None:
        content = """
            /*
              outer layer
              /* #Preview { Text("inside nested comment") } */
            */
            let value = 1
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [])

    def test_detects_preview_after_nested_block_comment_closes(self) -> None:
        content = """
            /*
              outer
              /* inner */
            */
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [6])

    def test_detects_preview_after_inline_nested_block_comment_closes(self) -> None:
        content = """
            /* outer /* inner */ still outer */ #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2])

    def test_detects_preview_after_string_with_comment_markers(self) -> None:
        content = """
            let tricky = "/* not a comment marker in a string */"
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_detects_preview_after_unclosed_comment_marker_in_string_literal(self) -> None:
        content = """
            let tricky = "/*"
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_reports_multiple_line_numbers(self) -> None:
        content = """
            #Preview { Text("one") }
            let value = 1
            #Preview { Text("two") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2, 4])


class PreviewMacroScriptBehaviorTests(unittest.TestCase):
    script_path = str(SCRIPT_DIR / "check_preview_macros.py")

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, self.script_path, *args],
            check=False,
            text=True,
            capture_output=True,
        )

    def test_fails_when_scan_root_missing(self) -> None:
        result = self.run_script("--root", "this/path/does/not/exist")
        self.assertEqual(result.returncode, 1)
        self.assertIn("One or more scan roots are invalid", result.stdout)
        self.assertIn("does not exist", result.stdout)

    def test_fails_when_scan_root_is_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            file_root = temp_path / "not_a_directory.txt"
            file_root.write_text("hello\n", encoding="utf-8")

            result = self.run_script("--root", str(file_root))
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("is not a directory", result.stdout)

    def test_fails_when_no_swift_files_found_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("No Swift files were discovered", result.stdout)

    def test_allow_empty_succeeds_when_no_swift_files_found(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--allow-empty")
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_reports_detected_file_and_line_number(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Example.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    struct Example: View {
                        var body: some View { Text("ok") }
                    }
                    #Preview {
                        Example()
                    }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Example.swift (lines: 4)", result.stdout)

    def test_supports_custom_token_scans(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "OtherPreview.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    struct OtherPreview: View {
                        var body: some View { Text("ok") }
                    }
                    #MyPreview {
                        OtherPreview()
                    }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir, "--token", "#MyPreview")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Found unsupported token '#MyPreview'", result.stdout)
            self.assertIn("OtherPreview.swift (lines: 4)", result.stdout)

    def test_trims_custom_token_value_before_scanning(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "TrimmedToken.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    struct TrimmedToken: View {
                        var body: some View { Text("ok") }
                    }
                    #MyPreview {
                        TrimmedToken()
                    }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir, "--token", "  #MyPreview  ")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Found unsupported token '#MyPreview'", result.stdout)
            self.assertIn("TrimmedToken.swift (lines: 4)", result.stdout)

    def test_fails_when_token_is_blank_after_trimming(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--token", "   ")
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "Configured token is empty after trimming; provide a non-empty token.",
                result.stdout,
            )

    def test_deduplicates_overlapping_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            nested_dir = temp_path / "nested"
            nested_dir.mkdir(parents=True, exist_ok=True)
            swift_file = nested_dir / "OnlyOnce.swift"
            swift_file.write_text(
                "struct OnlyOnce {}\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir, "--root", str(nested_dir))
            self.assertEqual(result.returncode, 0)
            self.assertIn("across 1 Swift files.", result.stdout)

    def test_fails_closed_when_swift_file_is_not_utf8_decodable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Corrupt.swift"
            swift_file.write_bytes(b"\xff\xfe\xfa")

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Corrupt.swift", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
