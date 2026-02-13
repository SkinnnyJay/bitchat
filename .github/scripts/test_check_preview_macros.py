#!/usr/bin/env python3
"""
Unit tests for preview guard token detection behavior.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import io
import os
import pathlib
import random
import stat
import string
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


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

    def test_detects_preview_after_statement_semicolon_on_same_line(self) -> None:
        content = """
            let value = 1; #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2])

    def test_detects_custom_token_with_trailing_non_word_character(self) -> None:
        content = """
            let value = 1; #MyPreview(ExampleView())
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#MyPreview("), [2])

    def test_detects_custom_token_ending_with_combining_mark_with_boundary(self) -> None:
        content = """
            #MyPreview\u0301suffix
            #MyPreview\u0301 { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#MyPreview\u0301"), [3])

    def test_detects_custom_token_ending_with_connector_punctuation_with_boundary(self) -> None:
        content = """
            #MyPreview‿suffix
            #MyPreview‿ { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#MyPreview‿"), [3])

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

    def test_detects_preview_after_closing_brace_on_same_line(self) -> None:
        content = """
            if true {} #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2])

    def test_detects_preview_after_attribute_clause_on_same_line(self) -> None:
        content = """
            @available(iOS 17, *) #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2])

    def test_does_not_match_double_hash_prefixed_token(self) -> None:
        content = """
            ##Preview { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_hash_suffixed_token(self) -> None:
        content = """
            #Preview# { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_dollar_suffixed_token(self) -> None:
        content = """
            #Preview$ { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_dollar_prefixed_token(self) -> None:
        content = """
            let combinedNoSpace = $#Preview
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_combining_mark_suffixed_token(self) -> None:
        content = """
            #Preview\u0301 { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_zero_width_joiner_suffixed_token(self) -> None:
        content = """
            #Preview\u200d { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_connector_punctuation_suffixed_token(self) -> None:
        content = """
            #Preview‿ { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_detects_backtick_wrapped_preview_token(self) -> None:
        content = """
            let marker = `#Preview`
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2, 3])

    def test_does_not_match_backtick_wrapped_hash_suffixed_token(self) -> None:
        content = """
            let marker = `#Preview#`
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_unicode_identifier_prefixed_token(self) -> None:
        content = """
            let combined = α#Preview
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_combining_mark_prefixed_token(self) -> None:
        content = """
            let combined = pre\u0301#Preview
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_connector_punctuation_prefixed_token(self) -> None:
        content = """
            let combined = pre‿#Preview
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_does_not_match_identifier_prefixed_suffix_variant(self) -> None:
        content = """
            #PreviewVariant { Text("not target token") }
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

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

    def test_detects_preview_after_multiline_string_with_escaped_triple_quote(self) -> None:
        escaped_triple_quote = "\\" + "\"\"\""
        content = "\n".join(
            [
                "",
                '            let tricky = """',
                f"            literal marker {escaped_triple_quote}",
                "            still string content",
                '            """',
                '            #Preview { Text("real preview") }',
                "        ",
            ]
        )
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [6])

    def test_detects_preview_after_multiline_string_closes_on_even_backslashes(self) -> None:
        even_backslashes_then_triple_quote = "\\\\" + "\"\"\""
        content = "\n".join(
            [
                "",
                '            let tricky = """',
                f"            {even_backslashes_then_triple_quote}",
                '            #Preview { Text("real preview") }',
                "        ",
            ]
        )
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [4])

    def test_detects_preview_after_multiline_string_with_three_backslashes_before_triple(self) -> None:
        odd_backslashes_then_triple_quote = "\\\\\\" + "\"\"\""
        content = "\n".join(
            [
                "",
                '            let tricky = """',
                f"            marker {odd_backslashes_then_triple_quote}",
                "            still inside string",
                '            """',
                '            #Preview { Text("real preview") }',
                "        ",
            ]
        )
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [6])

    def test_detects_preview_after_raw_multiline_string_with_comment_markers(self) -> None:
        content = '''
            let raw = #"""
            /* not a comment marker */
            // still string content
            """#
            #Preview { Text("real preview") }
        '''
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [6])

    def test_detects_preview_after_raw_single_line_string_with_escaped_closer(self) -> None:
        content = """
            let raw = #"before \\#"# still in string"#
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_detects_preview_after_raw_single_line_string_with_two_hashes_escaped_closer(self) -> None:
        content = """
            let raw = ##"before \\##"## still in string"##
            #Preview { Text("real preview") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [3])

    def test_detects_preview_after_raw_multiline_string_with_escaped_closer(self) -> None:
        content = '''
            let raw = #"""
            before
            \\#"""#
            still content
            """#
            #Preview { Text("real preview") }
        '''
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [7])

    def test_detects_preview_after_raw_multiline_string_with_two_hashes_escaped_closer(self) -> None:
        content = '''
            let raw = ##"""
            before
            \\##"""##
            still content
            """##
            #Preview { Text("real preview") }
        '''
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [7])

    def test_reports_multiple_line_numbers(self) -> None:
        content = """
            #Preview { Text("one") }
            let value = 1
            #Preview { Text("two") }
        """
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2, 4])

    def test_detects_preview_with_unicode_line_separator(self) -> None:
        content = "let value = 1\u2028#Preview { Text(\"one\") }\n"
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [2])

    def test_detects_preview_when_file_starts_with_utf8_bom(self) -> None:
        content = "\ufeff#Preview { Text(\"one\") }\n"
        self.assertEqual(check_preview_macros.find_token_line_numbers(content, "#Preview"), [1])

    def test_reports_parse_state_for_unterminated_single_line_string(self) -> None:
        content = """
            let value = "unterminated
            #Preview { Text("real preview") }
        """
        matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
            content, "#Preview"
        )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "unterminated single-line string literal (opened at line 2)",
        )

    def test_reports_parse_state_for_unmatched_block_comment_closer(self) -> None:
        content = """
            let value = 1
            */
            #Preview { Text("real preview") }
        """
        matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
            content, "#Preview"
        )
        self.assertEqual(matches, [])
        self.assertEqual(parse_error, "unmatched block comment closer at line 3")

    def test_reports_parse_state_for_excessive_block_comment_nesting(self) -> None:
        content = "/* /* /* */ */ */\n#Preview { Text(\"real preview\") }\n"
        with mock.patch.object(check_preview_macros, "MAX_BLOCK_COMMENT_NESTING", 2):
            matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                content, "#Preview"
            )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "block comment nesting exceeds maximum supported depth (2) at line 1",
        )

    def test_reports_parse_state_for_excessive_raw_string_hash_delimiter(self) -> None:
        content = '##"value"##\n#Preview { Text("real preview") }\n'
        with mock.patch.object(check_preview_macros, "MAX_RAW_STRING_DELIMITER_HASHES", 1):
            matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                content, "#Preview"
            )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "raw string delimiter exceeds maximum supported hash count (1) at line 1",
        )

    def test_reports_parse_state_for_excessive_line_count(self) -> None:
        content = "line1\nline2\n#Preview { Text(\"real preview\") }\n"
        with mock.patch.object(check_preview_macros, "MAX_SWIFT_FILE_LINES", 2):
            matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                content, "#Preview"
            )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "Swift file exceeds maximum supported line count (2)",
        )

    def test_reports_parse_state_for_excessive_line_length(self) -> None:
        content = "abcd\n#Preview { Text(\"real preview\") }\n"
        with mock.patch.object(check_preview_macros, "MAX_SWIFT_LINE_CHARS", 3):
            matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                content, "#Preview"
            )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "Swift line exceeds maximum supported character count (3) at line 1",
        )

    def test_reports_parse_state_for_excessive_token_candidate_checks(self) -> None:
        content = "#a#a#a#a#a\n"
        with mock.patch.object(check_preview_macros, "MAX_TOKEN_CANDIDATE_CHECKS_PER_LINE", 3):
            matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                content, "#a"
            )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "token candidate checks exceed maximum supported count (3) at line 1",
        )

    def test_reports_parse_state_for_excessive_total_token_candidate_checks(self) -> None:
        content = "#a#a#a\n#a#a#a\n"
        with (
            mock.patch.object(check_preview_macros, "MAX_TOKEN_CANDIDATE_CHECKS_PER_LINE", 10),
            mock.patch.object(check_preview_macros, "MAX_TOTAL_TOKEN_CANDIDATE_CHECKS", 5),
        ):
            matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                content, "#a"
            )
        self.assertEqual(matches, [])
        self.assertEqual(
            parse_error,
            "total token candidate checks exceed maximum supported count (5) at line 2",
        )

    def test_randomized_inputs_never_raise_parser_exceptions(self) -> None:
        rng = random.Random(20260213)
        alphabet = string.ascii_letters + string.digits + string.punctuation + " \t\nαβ🙂"

        for _ in range(2000):
            length = rng.randint(0, 500)
            content = "".join(rng.choice(alphabet) for _ in range(length))
            try:
                matches, parse_error = check_preview_macros.find_token_line_numbers_with_state(
                    content, "#Preview"
                )
            except Exception as error:  # pragma: no cover - explicit crash guard assertion
                self.fail(f"Parser raised {type(error).__name__} for randomized input: {error}")

            self.assertEqual(matches, sorted(set(matches)))
            for line_number in matches:
                self.assertGreaterEqual(line_number, 1)
            if parse_error is not None:
                self.assertIsInstance(parse_error, str)


class PreviewMacroUtilityTests(unittest.TestCase):
    def test_reports_utf8_byte_length_or_none(self) -> None:
        self.assertEqual(check_preview_macros.utf8_byte_length_or_none("abc"), 3)
        self.assertEqual(check_preview_macros.utf8_byte_length_or_none("🙂"), 4)
        self.assertIsNone(check_preview_macros.utf8_byte_length_or_none("\ud800"))

    def test_reads_stat_timestamp_ns_from_nanosecond_field(self) -> None:
        stats = type("StatLike", (), {"st_mtime_ns": 123, "st_mtime": 9.0})()
        self.assertEqual(
            check_preview_macros.stat_timestamp_ns_or_none(
                stats,
                "st_mtime_ns",
                "st_mtime",
            ),
            123,
        )

    def test_reads_stat_timestamp_ns_from_seconds_fallback(self) -> None:
        stats = type("StatLike", (), {"st_mtime": 1.25})()
        self.assertEqual(
            check_preview_macros.stat_timestamp_ns_or_none(
                stats,
                "st_mtime_ns",
                "st_mtime",
            ),
            1_250_000_000,
        )

    def test_returns_none_for_non_finite_stat_seconds_values(self) -> None:
        nan_stats = type("StatLike", (), {"st_mtime": float("nan")})()
        inf_stats = type("StatLike", (), {"st_mtime": float("inf")})()
        self.assertIsNone(
            check_preview_macros.stat_timestamp_ns_or_none(
                nan_stats,
                "st_mtime_ns",
                "st_mtime",
            )
        )
        self.assertIsNone(
            check_preview_macros.stat_timestamp_ns_or_none(
                inf_stats,
                "st_mtime_ns",
                "st_mtime",
            )
        )

    def test_returns_none_for_boolean_stat_timestamp_values(self) -> None:
        ns_bool_stats = type("StatLike", (), {"st_mtime_ns": True, "st_mtime": 2.0})()
        seconds_bool_stats = type("StatLike", (), {"st_mtime": False})()
        self.assertEqual(
            check_preview_macros.stat_timestamp_ns_or_none(
                ns_bool_stats,
                "st_mtime_ns",
                "st_mtime",
            ),
            2_000_000_000,
        )
        self.assertIsNone(
            check_preview_macros.stat_timestamp_ns_or_none(
                seconds_bool_stats,
                "st_mtime_ns",
                "st_mtime",
            )
        )

    def test_returns_none_when_stat_timestamp_fields_are_missing(self) -> None:
        stats = type("StatLike", (), {})()
        self.assertIsNone(
            check_preview_macros.stat_timestamp_ns_or_none(
                stats,
                "st_mtime_ns",
                "st_mtime",
            )
        )

    def test_reads_stat_integer_or_none_for_integer_values(self) -> None:
        stats = type("StatLike", (), {"st_dev": 42})()
        self.assertEqual(check_preview_macros.stat_integer_or_none(stats, "st_dev"), 42)

    def test_returns_none_for_boolean_stat_integer_values(self) -> None:
        stats = type("StatLike", (), {"st_dev": True})()
        self.assertIsNone(check_preview_macros.stat_integer_or_none(stats, "st_dev"))

    def test_reads_stat_identity_or_none_for_integer_fields(self) -> None:
        stats = type("StatLike", (), {"st_dev": 7, "st_ino": 9})()
        self.assertEqual(check_preview_macros.stat_identity_or_none(stats), (7, 9))

    def test_returns_none_for_stat_identity_with_invalid_fields(self) -> None:
        stats = type("StatLike", (), {"st_dev": True, "st_ino": 9})()
        self.assertIsNone(check_preview_macros.stat_identity_or_none(stats))

    def test_reads_stat_nonnegative_integer_or_none(self) -> None:
        stats = type("StatLike", (), {"st_size": 12})()
        self.assertEqual(check_preview_macros.stat_nonnegative_integer_or_none(stats, "st_size"), 12)
        negative_stats = type("StatLike", (), {"st_size": -1})()
        self.assertIsNone(check_preview_macros.stat_nonnegative_integer_or_none(negative_stats, "st_size"))

    def test_reads_stat_positive_integer_or_none(self) -> None:
        stats = type("StatLike", (), {"st_nlink": 2})()
        self.assertEqual(check_preview_macros.stat_positive_integer_or_none(stats, "st_nlink"), 2)
        zero_stats = type("StatLike", (), {"st_nlink": 0})()
        self.assertIsNone(check_preview_macros.stat_positive_integer_or_none(zero_stats, "st_nlink"))

    def test_reads_stat_is_regular_file_or_none(self) -> None:
        regular_stats = type("StatLike", (), {"st_mode": stat.S_IFREG | 0o644})()
        directory_stats = type("StatLike", (), {"st_mode": stat.S_IFDIR | 0o755})()
        invalid_stats = type("StatLike", (), {"st_mode": True})()
        self.assertTrue(check_preview_macros.stat_is_regular_file_or_none(regular_stats))
        self.assertFalse(check_preview_macros.stat_is_regular_file_or_none(directory_stats))
        self.assertIsNone(check_preview_macros.stat_is_regular_file_or_none(invalid_stats))

    def test_formats_roots_for_diagnostics(self) -> None:
        roots = [pathlib.Path("/tmp/a"), pathlib.Path("/tmp/b"), pathlib.Path("/tmp/c")]
        self.assertEqual(
            check_preview_macros.format_roots_for_diagnostics(roots),
            "/tmp/a, /tmp/b, /tmp/c",
        )
        with mock.patch.object(check_preview_macros, "MAX_REPORTED_ROOTS_IN_SUMMARY", 2):
            self.assertEqual(
                check_preview_macros.format_roots_for_diagnostics(roots),
                "/tmp/a, /tmp/b ... +1 more roots",
            )

    def test_formats_line_numbers_for_diagnostics(self) -> None:
        self.assertEqual(
            check_preview_macros.format_line_numbers_for_diagnostics([1, 2, 3]),
            "1, 2, 3",
        )
        self.assertEqual(
            check_preview_macros.format_line_numbers_for_diagnostics([1, 2], total_line_number_count=5),
            "1, 2 ... +3 more",
        )
        with mock.patch.object(check_preview_macros, "MAX_REPORTED_LINE_NUMBERS_PER_FILE", 2):
            self.assertEqual(
                check_preview_macros.format_line_numbers_for_diagnostics([1, 2, 3, 4]),
                "1, 2 ... +2 more",
            )

    def test_escapes_control_characters_for_diagnostics(self) -> None:
        self.assertEqual(
            check_preview_macros.escape_diagnostic_text("line1\nline2\t\x01"),
            "line1\\nline2\\t\\x01",
        )

    def test_truncates_escaped_diagnostics_when_too_long(self) -> None:
        with mock.patch.object(check_preview_macros, "MAX_DIAGNOSTIC_TEXT_CHARS", 10):
            escaped = check_preview_macros.escape_diagnostic_text("abcdefghijklmnop")
        self.assertEqual(escaped, "abcdefghij... +6 chars truncated")

    def test_detects_disallowed_unicode_control_categories(self) -> None:
        self.assertTrue(check_preview_macros.contains_disallowed_control_characters("a\u2060b"))
        self.assertTrue(check_preview_macros.contains_disallowed_control_characters("a\x7fb"))
        self.assertFalse(check_preview_macros.contains_disallowed_control_characters("abc"))

    def test_detects_swift_identifier_continuation_characters(self) -> None:
        self.assertTrue(check_preview_macros.is_swift_identifier_continuation_character("a"))
        self.assertTrue(check_preview_macros.is_swift_identifier_continuation_character("_"))
        self.assertTrue(check_preview_macros.is_swift_identifier_continuation_character("$"))
        self.assertTrue(check_preview_macros.is_swift_identifier_continuation_character("\u0301"))
        self.assertTrue(check_preview_macros.is_swift_identifier_continuation_character("\u200d"))
        self.assertTrue(check_preview_macros.is_swift_identifier_continuation_character("‿"))
        self.assertFalse(check_preview_macros.is_swift_identifier_continuation_character("#"))
        self.assertFalse(check_preview_macros.is_swift_identifier_continuation_character(" "))

    def test_validates_token_boundaries_with_swift_identifier_suffixes(self) -> None:
        self.assertFalse(
            check_preview_macros.has_token_boundaries(
                "#Preview\u0301",
                0,
                len("#Preview"),
                requires_right_boundary=True,
            )
        )
        self.assertFalse(
            check_preview_macros.has_token_boundaries(
                "#Preview\u200d",
                0,
                len("#Preview"),
                requires_right_boundary=True,
            )
        )
        self.assertFalse(
            check_preview_macros.has_token_boundaries(
                "#Preview$",
                0,
                len("#Preview"),
                requires_right_boundary=True,
            )
        )
        self.assertFalse(
            check_preview_macros.has_token_boundaries(
                "$#Preview",
                1,
                1 + len("#Preview"),
                requires_right_boundary=True,
            )
        )
        self.assertFalse(
            check_preview_macros.has_token_boundaries(
                "#Preview‿",
                0,
                len("#Preview"),
                requires_right_boundary=True,
            )
        )
        self.assertTrue(
            check_preview_macros.has_token_boundaries(
                "#Preview(",
                0,
                len("#Preview"),
                requires_right_boundary=True,
            )
        )

    def test_truncates_error_reason_for_storage(self) -> None:
        with mock.patch.object(check_preview_macros, "MAX_STORED_ERROR_REASON_CHARS", 8):
            self.assertEqual(
                check_preview_macros.truncate_error_reason_for_storage("abcdefghijk"),
                "abcdefgh... +3 chars truncated",
            )
            self.assertEqual(
                check_preview_macros.truncate_error_reason_for_storage("abcd"),
                "abcd",
            )

    def test_formats_open_error_for_symlink_loop(self) -> None:
        error = OSError(errno.ELOOP, "too many levels of symbolic links")
        self.assertEqual(
            check_preview_macros.format_open_read_error(error),
            "symlinked Swift file not scanned",
        )

    def test_formats_open_error_for_non_regular_path(self) -> None:
        error = OSError(errno.EISDIR, "is a directory")
        self.assertEqual(
            check_preview_macros.format_open_read_error(error),
            "unsupported non-regular Swift path",
        )

    def test_formats_open_error_for_permission_denied(self) -> None:
        error = OSError(errno.EACCES, "permission denied")
        self.assertIn(
            "permission denied",
            check_preview_macros.format_open_read_error(error),
        )

    def test_formats_open_error_for_disappeared_path(self) -> None:
        error = OSError(errno.ENOENT, "no such file or directory")
        self.assertIn(
            "path disappeared during scan",
            check_preview_macros.format_open_read_error(error),
        )

    def test_formats_open_error_for_generic_failure(self) -> None:
        error = OSError(errno.EIO, "input/output error")
        self.assertIn(
            "cannot open/read file",
            check_preview_macros.format_open_read_error(error),
        )

    def test_formats_walk_error_for_symlink_loop(self) -> None:
        error = OSError(errno.ELOOP, "too many levels of symbolic links")
        self.assertIn(
            "cannot traverse directory (symlink loop:",
            check_preview_macros.format_walk_error(error),
        )

    def test_formats_walk_error_for_non_directory_path(self) -> None:
        error = OSError(errno.ENOTDIR, "not a directory")
        self.assertIn(
            "cannot traverse directory (non-directory path:",
            check_preview_macros.format_walk_error(error),
        )

    def test_formats_walk_error_for_permission_denied(self) -> None:
        error = OSError(errno.EACCES, "permission denied")
        self.assertIn(
            "cannot traverse directory (permission denied:",
            check_preview_macros.format_walk_error(error),
        )

    def test_formats_walk_error_for_disappeared_path(self) -> None:
        error = OSError(errno.ENOENT, "no such file or directory")
        self.assertIn(
            "directory disappeared during scan",
            check_preview_macros.format_walk_error(error),
        )

    def test_formats_directory_inspection_error_for_permission_denied(self) -> None:
        error = OSError(errno.EACCES, "permission denied")
        self.assertIn(
            "cannot inspect directory (permission denied:",
            check_preview_macros.format_directory_inspection_error(error),
        )

    def test_formats_path_access_error_for_permission_denied(self) -> None:
        error = OSError(errno.EACCES, "permission denied")
        self.assertIn(
            "cannot access path (permission denied:",
            check_preview_macros.format_path_access_error(error),
        )

    def test_formats_resolve_path_error_for_symlink_loop(self) -> None:
        error = OSError(errno.ELOOP, "too many levels of symbolic links")
        self.assertIn(
            "cannot resolve path (symlink loop:",
            check_preview_macros.format_resolve_path_error(error),
        )

    def test_formats_resolve_runtime_error_with_context(self) -> None:
        error = RuntimeError("simulated resolution recursion")
        self.assertEqual(
            check_preview_macros.format_resolve_runtime_error(error),
            "cannot resolve path (runtime failure: simulated resolution recursion)",
        )

    def test_formats_file_inspection_error_for_permission_denied(self) -> None:
        error = OSError(errno.EACCES, "permission denied")
        self.assertIn(
            "cannot inspect file (permission denied:",
            check_preview_macros.format_file_inspection_error(error),
        )

    def test_formats_file_metadata_error_for_disappeared_path(self) -> None:
        error = OSError(errno.ENOENT, "no such file or directory")
        self.assertIn(
            "cannot inspect file metadata (path disappeared during scan:",
            check_preview_macros.format_file_metadata_error(error),
        )

    def test_formats_utf8_decode_error_for_single_byte_position(self) -> None:
        error = UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte")
        self.assertEqual(
            check_preview_macros.format_utf8_decode_error(error),
            "cannot decode file as UTF-8 (invalid start byte at byte 0)",
        )

    def test_formats_utf8_decode_error_for_byte_range(self) -> None:
        error = UnicodeDecodeError("utf-8", b"\xe2(\xa1", 0, 3, "invalid continuation byte")
        self.assertEqual(
            check_preview_macros.format_utf8_decode_error(error),
            "cannot decode file as UTF-8 (invalid continuation byte at bytes 0-2)",
        )

    def test_formats_utf8_decode_error_with_negative_start_index(self) -> None:
        error = UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte")
        error.start = -1
        self.assertEqual(
            check_preview_macros.format_utf8_decode_error(error),
            "cannot decode file as UTF-8 (invalid start byte)",
        )

    def test_formats_utf8_decode_error_with_negative_end_index(self) -> None:
        error = UnicodeDecodeError("utf-8", b"\xff", 2, 3, "invalid continuation byte")
        error.end = -1
        self.assertEqual(
            check_preview_macros.format_utf8_decode_error(error),
            "cannot decode file as UTF-8 (invalid continuation byte at byte 2)",
        )

    def test_iter_content_lines_handles_mixed_newline_sequences(self) -> None:
        content = "a\r\nb\rc\n\n"
        self.assertEqual(
            list(check_preview_macros.iter_content_lines(content)),
            [(1, "a"), (2, "b"), (3, "c"), (4, "")],
        )

    def test_iter_content_lines_handles_additional_line_separators(self) -> None:
        content = "a\x0bb\x0cc\x1cd\x1de\x1ef\x85g\u2028h\u2029i"
        self.assertEqual(
            list(check_preview_macros.iter_content_lines(content)),
            [
                (1, "a"),
                (2, "b"),
                (3, "c"),
                (4, "d"),
                (5, "e"),
                (6, "f"),
                (7, "g"),
                (8, "h"),
                (9, "i"),
            ],
        )

    def test_builds_error_path_from_bytes_filename(self) -> None:
        fallback = pathlib.Path("/tmp/fallback")
        result = check_preview_macros.path_from_error_filename(b"/tmp/\xffbad", fallback)
        self.assertIsInstance(result, pathlib.Path)
        self.assertTrue(str(result).startswith("/tmp/"))

    def test_falls_back_when_error_filename_is_not_pathlike_or_stringable(self) -> None:
        class BadFilename:
            def __fspath__(self) -> str:
                raise TypeError("invalid path")

            def __str__(self) -> str:
                raise TypeError("not stringable")

        fallback = pathlib.Path("/tmp/fallback")
        result = check_preview_macros.path_from_error_filename(BadFilename(), fallback)
        self.assertEqual(result, fallback)


class PreviewMacroScriptBehaviorTests(unittest.TestCase):
    script_path = str(SCRIPT_DIR / "check_preview_macros.py")

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, self.script_path, *args],
            check=False,
            text=True,
            capture_output=True,
        )

    def run_main_with_args(
        self,
        *,
        roots: list[str] | None,
        token: str,
        allow_empty: bool = False,
    ) -> tuple[int, str]:
        namespace = argparse.Namespace(root=roots, token=token, allow_empty=allow_empty)
        output = io.StringIO()
        with (
            contextlib.redirect_stdout(output),
            mock.patch.object(check_preview_macros, "parse_args", return_value=namespace),
        ):
            return_code = check_preview_macros.main()
        return return_code, output.getvalue()

    def test_fails_when_scan_root_missing(self) -> None:
        result = self.run_script("--root", "this/path/does/not/exist")
        self.assertEqual(result.returncode, 1)
        self.assertIn("One or more scan roots are invalid", result.stdout)
        self.assertIn("does not exist", result.stdout)

    def test_truncates_long_invalid_root_diagnostics(self) -> None:
        long_missing_root = "missing-" + ("x" * 80)
        with mock.patch.object(check_preview_macros, "MAX_DIAGNOSTIC_TEXT_CHARS", 24):
            return_code, output = self.run_main_with_args(
                roots=[long_missing_root],
                token="#Preview",
                allow_empty=True,
            )
        self.assertEqual(return_code, 1)
        self.assertIn("One or more scan roots are invalid", output)
        self.assertIn("chars truncated", output)
        self.assertIn("does not exist", output)

    def test_fails_when_scan_root_path_is_inaccessible(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            inaccessible_parent = temp_path / "inaccessible"
            inaccessible_parent.mkdir(parents=True, exist_ok=True)
            nested_root = inaccessible_parent / "nested"

            try:
                os.chmod(inaccessible_parent, 0)
            except OSError as error:
                self.skipTest(f"Could not adjust parent permissions for root accessibility test: {error}")

            if os.access(inaccessible_parent, os.R_OK | os.X_OK):
                os.chmod(inaccessible_parent, 0o755)
                self.skipTest("Permission restrictions are not enforced in this environment.")

            try:
                result = self.run_script("--root", str(nested_root))
            finally:
                os.chmod(inaccessible_parent, 0o755)

            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("cannot access path", result.stdout)

    def test_fails_when_scan_root_is_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            file_root = temp_path / "not_a_directory.txt"
            file_root.write_text("hello\n", encoding="utf-8")

            result = self.run_script("--root", str(file_root))
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("is not a directory", result.stdout)

    def test_fails_when_scan_root_mode_metadata_is_non_integer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target_root = pathlib.Path(temp_dir)
            original_lstat = pathlib.Path.lstat

            def fake_lstat(path: pathlib.Path) -> os.stat_result | object:
                if path == target_root:
                    return type("StatLike", (), {"st_mode": True})()
                return original_lstat(path)

            with mock.patch.object(pathlib.Path, "lstat", new=fake_lstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("One or more scan roots are invalid", output)
            self.assertIn("cannot read path mode metadata", output)

    def test_fails_when_scan_root_mode_metadata_is_negative(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            target_root = pathlib.Path(temp_dir)
            original_lstat = pathlib.Path.lstat

            def fake_lstat(path: pathlib.Path) -> os.stat_result | object:
                if path == target_root:
                    return type("StatLike", (), {"st_mode": -1})()
                return original_lstat(path)

            with mock.patch.object(pathlib.Path, "lstat", new=fake_lstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("One or more scan roots are invalid", output)
            self.assertIn("cannot read path mode metadata", output)

    def test_fails_when_scan_root_is_symlinked_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            real_root = temp_path / "real_root"
            real_root.mkdir(parents=True, exist_ok=True)
            symlink_root = temp_path / "symlink_root"
            try:
                symlink_root.symlink_to(real_root, target_is_directory=True)
            except (NotImplementedError, OSError) as error:
                self.skipTest(f"Symlink creation not supported in environment: {error}")

            result = self.run_script("--root", str(symlink_root))
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("is a symlinked directory", result.stdout)

    def test_rejects_symlink_root_when_canonical_root_is_also_configured(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            real_root = temp_path / "real_root"
            real_root.mkdir(parents=True, exist_ok=True)
            (real_root / "Real.swift").write_text("struct Real {}\n", encoding="utf-8")

            symlink_root = temp_path / "symlink_root"
            try:
                symlink_root.symlink_to(real_root, target_is_directory=True)
            except (NotImplementedError, OSError) as error:
                self.skipTest(f"Symlink creation not supported in environment: {error}")

            result = self.run_script("--root", str(real_root), "--root", str(symlink_root))
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("symlink_root", result.stdout)
            self.assertIn("is a symlinked directory", result.stdout)

    def test_fails_when_scan_root_has_symlink_loop(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            loop_root = temp_path / "loop"
            try:
                loop_root.symlink_to(loop_root)
            except OSError as error:
                self.skipTest(f"Symlink creation not supported in environment: {error}")

            result = self.run_script("--root", str(loop_root))
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertTrue(
                "cannot resolve path" in result.stdout
                or "does not exist" in result.stdout
                or "is a symlinked directory" in result.stdout,
                msg=result.stdout,
            )

    def test_fails_when_scan_root_is_blank_after_trimming(self) -> None:
        result = self.run_script("--root", "   ")
        self.assertEqual(result.returncode, 1)
        self.assertIn("One or more scan roots are invalid", result.stdout)
        self.assertIn("is empty after trimming", result.stdout)

    def test_fails_when_scan_root_exceeds_max_utf8_bytes(self) -> None:
        oversized_root = "a" * (check_preview_macros.MAX_ROOT_BYTES + 1)
        result = self.run_script("--root", oversized_root)
        self.assertEqual(result.returncode, 1)
        self.assertIn("One or more scan roots are invalid", result.stdout)
        self.assertIn("is too long", result.stdout)
        self.assertIn(
            f"{check_preview_macros.MAX_ROOT_BYTES} UTF-8 bytes",
            result.stdout,
        )

    def test_fails_when_scan_root_count_exceeds_max(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            args: list[str] = []
            for _ in range(check_preview_macros.MAX_ROOT_COUNT + 1):
                args.extend(["--root", temp_dir])
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Too many scan roots configured", result.stdout)
            self.assertIn(
                f"{check_preview_macros.MAX_ROOT_COUNT} root arguments",
                result.stdout,
            )

    def test_fails_closed_when_scan_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")
            (temp_path / "B.swift").write_text("struct B {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_SCANNED_SWIFT_FILES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Scan aborted after reaching maximum Swift file limit (1).", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)
            self.assertIn("Read ", output)

    def test_fails_closed_when_total_swift_byte_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_TOTAL_SCANNED_SWIFT_BYTES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum total Swift byte-read limit (1 bytes).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)
            self.assertIn("Read 0 Swift bytes before failure.", output)

    def test_fails_closed_when_total_parsed_line_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("line1\nline2\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_TOTAL_PARSED_SWIFT_LINES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum total parsed Swift line limit (1).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)
            self.assertIn("Parsed 2 Swift lines before failure.", output)

    def test_fails_closed_when_directory_visit_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "nested").mkdir(parents=True, exist_ok=True)

            with mock.patch.object(check_preview_macros, "MAX_VISITED_DIRECTORIES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum directory-visit limit (1).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 0 Swift files before failure.", output)
            self.assertIn("Visited 1 directories before failure.", output)
            self.assertIn("Read 0 Swift bytes before failure.", output)

    def test_fails_closed_when_entries_per_directory_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")
            (temp_path / "B.swift").write_text("struct B {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_DIRECTORY_ENTRIES_PER_DIRECTORY", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum entries-per-directory limit (1) at",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 0 Swift files before failure.", output)
            self.assertIn("Visited 1 directories before failure.", output)
            self.assertIn("Read 0 Swift bytes before failure.", output)

    def test_fails_closed_when_total_directory_entries_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")
            (temp_path / "B.swift").write_text("struct B {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_TOTAL_DIRECTORY_ENTRIES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum total directory-entry limit (1).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 0 Swift files before failure.", output)
            self.assertIn("Visited 1 directories before failure.", output)
            self.assertIn("Processed 0 directory entries before failure.", output)
            self.assertIn("Read 0 Swift bytes before failure.", output)

    def test_fails_closed_when_seen_path_key_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")
            (temp_path / "B.swift").write_text("struct B {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_SEEN_SWIFT_PATH_KEYS", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum tracked Swift path-key limit (1).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)
            self.assertIn("Tracked 1 unique Swift path keys before failure.", output)

    def test_fails_closed_when_seen_file_identity_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")
            (temp_path / "B.swift").write_text("struct B {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_SEEN_SWIFT_FILE_IDENTITIES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum tracked Swift file-identity limit (1).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 2 Swift files before failure.", output)
            self.assertIn("Tracked 1 unique Swift file identities before failure.", output)

    def test_fails_closed_when_path_key_exceeds_max_utf8_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_STORED_PATH_BYTES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after encountering an unsupported Swift path key:",
                output,
            )
            self.assertIn("exceeds maximum path-key size", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 0 Swift files before failure.", output)

    def test_fails_closed_when_path_key_cannot_be_fsencoded(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "A.swift").write_text("struct A {}\n", encoding="utf-8")

            real_fsencode = check_preview_macros.os.fsencode

            def fake_fsencode(value: str | bytes) -> bytes:
                if isinstance(value, str) and value.endswith("A.swift"):
                    raise UnicodeEncodeError("utf-8", value, 0, 1, "simulated failure")
                return real_fsencode(value)

            with mock.patch.object(check_preview_macros.os, "fsencode", side_effect=fake_fsencode):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after encountering an unsupported Swift path key:",
                output,
            )
            self.assertIn("cannot be encoded for filesystem operations", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 0 Swift files before failure.", output)

    def test_limits_reported_invalid_roots(self) -> None:
        roots = ["   ", "\u2060", "\x01invalid"]
        with mock.patch.object(check_preview_macros, "MAX_REPORTED_INVALID_ROOTS", 2):
            return_code, output = self.run_main_with_args(
                roots=roots,
                token="#Preview",
                allow_empty=True,
            )

        self.assertEqual(return_code, 1)
        self.assertIn("One or more scan roots are invalid:", output)
        self.assertEqual(output.count(" - "), 2)
        self.assertIn("... and 1 more invalid roots not shown.", output)

    def test_fails_when_scan_root_contains_control_character(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", f"{temp_dir}\x01")
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("contains control characters", result.stdout)
            self.assertIn("\\x01", result.stdout)

    def test_fails_when_scan_root_contains_unicode_format_character(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", f"{temp_dir}\u2060")
            self.assertEqual(result.returncode, 1)
            self.assertIn("One or more scan roots are invalid", result.stdout)
            self.assertIn("contains control characters", result.stdout)
            self.assertIn("\\u2060", result.stdout)

    def test_fails_when_no_swift_files_found_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("No Swift files were discovered", result.stdout)

    def test_truncates_root_list_in_no_swift_failure_summary(self) -> None:
        with (
            tempfile.TemporaryDirectory() as root_a,
            tempfile.TemporaryDirectory() as root_b,
            tempfile.TemporaryDirectory() as root_c,
            mock.patch.object(check_preview_macros, "MAX_REPORTED_ROOTS_IN_SUMMARY", 2),
        ):
            return_code, output = self.run_main_with_args(
                roots=[root_a, root_b, root_c],
                token="#Preview",
            )
            self.assertEqual(return_code, 1)
            self.assertIn("No Swift files were discovered in configured roots", output)
            self.assertIn("Roots: [", output)
            self.assertIn("... +1 more roots]", output)

    def test_deduplicates_duplicate_root_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn(f"Roots: [{temp_dir}]", result.stdout)

    def test_deduplicates_canonical_equivalent_root_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            alias_root = str(pathlib.Path(temp_dir) / ".")
            result = self.run_script("--root", temp_dir, "--root", alias_root)
            self.assertEqual(result.returncode, 1)
            self.assertIn(f"Roots: [{temp_dir}]", result.stdout)

    def test_supports_tilde_expansion_for_roots(self) -> None:
        home_dir = pathlib.Path.home()
        with tempfile.TemporaryDirectory(dir=str(home_dir)) as temp_dir:
            relative = pathlib.Path(temp_dir).relative_to(home_dir)
            tilde_root = f"~/{relative.as_posix()}"
            result = self.run_script("--root", tilde_root, "--allow-empty")
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_allow_empty_succeeds_when_no_swift_files_found(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--allow-empty")
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_truncates_root_list_in_allow_empty_success_summary(self) -> None:
        with (
            tempfile.TemporaryDirectory() as root_a,
            tempfile.TemporaryDirectory() as root_b,
            tempfile.TemporaryDirectory() as root_c,
            mock.patch.object(check_preview_macros, "MAX_REPORTED_ROOTS_IN_SUMMARY", 2),
        ):
            return_code, output = self.run_main_with_args(
                roots=[root_a, root_b, root_c],
                token="#Preview",
                allow_empty=True,
            )
            self.assertEqual(return_code, 0)
            self.assertIn("No unsupported token '#Preview' detected in roots [", output)
            self.assertIn("... +1 more roots] across 0 Swift files (0 bytes read).", output)

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
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 1 token matches.", result.stdout)

    def test_limits_reported_token_match_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            for index in range(3):
                (temp_path / f"Example{index}.swift").write_text(
                    textwrap.dedent(
                        f"""
                        struct Example{index}: View {{
                            var body: some View {{ Text("ok") }}
                        }}
                        #Preview {{
                            Example{index}()
                        }}
                        """
                    ).strip() + "\n",
                    encoding="utf-8",
                )

            with mock.patch.object(check_preview_macros, "MAX_REPORTED_TOKEN_MATCH_FILES", 2):
                return_code, output = self.run_main_with_args(roots=[temp_dir], token="#Preview")

            self.assertEqual(return_code, 1)
            self.assertIn("Found unsupported token '#Preview' in Swift sources:", output)
            self.assertEqual(output.count("(lines:"), 2)
            self.assertIn("... and 1 more files not shown.", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 3 token matches.", output)

    def test_preserves_token_match_counts_when_internal_file_tracking_is_capped(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            for index in range(3):
                (temp_path / f"Example{index}.swift").write_text(
                    textwrap.dedent(
                        f"""
                        struct Example{index}: View {{
                            var body: some View {{ Text("ok") }}
                        }}
                        #Preview {{
                            Example{index}()
                        }}
                        """
                    ).strip() + "\n",
                    encoding="utf-8",
                )

            with mock.patch.object(check_preview_macros, "MAX_TRACKED_TOKEN_MATCH_FILES", 1):
                return_code, output = self.run_main_with_args(roots=[temp_dir], token="#Preview")

            self.assertEqual(return_code, 1)
            self.assertEqual(output.count("(lines:"), 1)
            self.assertIn("... and 2 more files not shown.", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 3 token matches.", output)

    def test_limits_reported_line_numbers_per_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "ManyPreviews.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    #Preview { Text("1") }
                    #Preview { Text("2") }
                    #Preview { Text("3") }
                    #Preview { Text("4") }
                    #Preview { Text("5") }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            with mock.patch.object(check_preview_macros, "MAX_REPORTED_LINE_NUMBERS_PER_FILE", 3):
                return_code, output = self.run_main_with_args(roots=[temp_dir], token="#Preview")

            self.assertEqual(return_code, 1)
            self.assertIn("ManyPreviews.swift (lines: 1, 2, 3 ... +2 more)", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 1 token matches.", output)

    def test_preserves_total_line_match_counts_when_internal_tracking_is_capped(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "ManyPreviews.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    #Preview { Text("1") }
                    #Preview { Text("2") }
                    #Preview { Text("3") }
                    #Preview { Text("4") }
                    #Preview { Text("5") }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            with (
                mock.patch.object(check_preview_macros, "MAX_REPORTED_LINE_NUMBERS_PER_FILE", 2),
                mock.patch.object(check_preview_macros, "MAX_TRACKED_LINE_NUMBERS_PER_FILE", 3),
            ):
                return_code, output = self.run_main_with_args(roots=[temp_dir], token="#Preview")

            self.assertEqual(return_code, 1)
            self.assertIn("ManyPreviews.swift (lines: 1, 2 ... +3 more)", output)
            self.assertIn("Failure summary: 0 unreadable, 0 parse errors, 1 token matches.", output)

    def test_limits_reported_unreadable_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            with tempfile.TemporaryDirectory() as target_dir:
                target_root = pathlib.Path(target_dir)
                for index in range(3):
                    real_swift = target_root / f"Real{index}.swift"
                    real_swift.write_text("struct Real {}\n", encoding="utf-8")
                    symlinked_swift = temp_path / f"Linked{index}.swift"
                    try:
                        symlinked_swift.symlink_to(real_swift)
                    except (NotImplementedError, OSError) as error:
                        self.skipTest(f"Symlink setup not supported in environment: {error}")

                with mock.patch.object(check_preview_macros, "MAX_REPORTED_UNREADABLE_FILES", 2):
                    return_code, output = self.run_main_with_args(
                        roots=[temp_dir],
                        token="#Preview",
                        allow_empty=True,
                    )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files:", output)
            self.assertEqual(output.count("symlinked Swift file not scanned"), 2)
            self.assertIn("... and 1 more unreadable files not shown.", output)
            self.assertIn("Failure summary: 3 unreadable, 0 parse errors, 0 token matches.", output)

    def test_preserves_unreadable_counts_when_internal_tracking_is_capped(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            with tempfile.TemporaryDirectory() as target_dir:
                target_root = pathlib.Path(target_dir)
                for index in range(3):
                    real_swift = target_root / f"Real{index}.swift"
                    real_swift.write_text("struct Real {}\n", encoding="utf-8")
                    symlinked_swift = temp_path / f"Linked{index}.swift"
                    try:
                        symlinked_swift.symlink_to(real_swift)
                    except (NotImplementedError, OSError) as error:
                        self.skipTest(f"Symlink setup not supported in environment: {error}")

                with mock.patch.object(check_preview_macros, "MAX_TRACKED_UNREADABLE_FILES", 1):
                    return_code, output = self.run_main_with_args(
                        roots=[temp_dir],
                        token="#Preview",
                        allow_empty=True,
                    )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files:", output)
            self.assertEqual(output.count("symlinked Swift file not scanned"), 1)
            self.assertIn("... and 2 more unreadable files not shown.", output)
            self.assertIn("Failure summary: 3 unreadable, 0 parse errors, 0 token matches.", output)

    def test_fails_closed_when_unreadable_tracking_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            with tempfile.TemporaryDirectory() as target_dir:
                target_root = pathlib.Path(target_dir)
                for index in range(2):
                    real_swift = target_root / f"Real{index}.swift"
                    real_swift.write_text("struct Real {}\n", encoding="utf-8")
                    symlinked_swift = temp_path / f"Linked{index}.swift"
                    try:
                        symlinked_swift.symlink_to(real_swift)
                    except (NotImplementedError, OSError) as error:
                        self.skipTest(f"Symlink setup not supported in environment: {error}")

                with mock.patch.object(check_preview_macros, "MAX_UNREADABLE_FILE_PATHS", 1):
                    return_code, output = self.run_main_with_args(
                        roots=[temp_dir],
                        token="#Preview",
                        allow_empty=True,
                    )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum unreadable-path tracking limit (1).",
                output,
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 2 Swift files before failure.", output)

    def test_limits_reported_parse_error_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            for index in range(3):
                malformed_swift = temp_path / f"Malformed{index}.swift"
                malformed_swift.write_text(
                    'let value = "unterminated\n',
                    encoding="utf-8",
                )

            with mock.patch.object(check_preview_macros, "MAX_REPORTED_PARSE_ERROR_FILES", 2):
                return_code, output = self.run_main_with_args(roots=[temp_dir], token="#Preview")

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files:", output)
            self.assertEqual(output.count("unterminated single-line string literal"), 2)
            self.assertIn("... and 1 more parse-error files not shown.", output)
            self.assertIn("Failure summary: 0 unreadable, 3 parse errors, 0 token matches.", output)

    def test_truncates_stored_unreadable_error_reason(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "Unreadable.swift").write_text("struct U {}\n", encoding="utf-8")
            long_reason = "R" * 40

            with (
                mock.patch.object(check_preview_macros, "MAX_STORED_ERROR_REASON_CHARS", 8),
                mock.patch.object(check_preview_macros, "format_open_read_error", return_value=long_reason),
                mock.patch.object(
                    check_preview_macros.os,
                    "open",
                    side_effect=OSError(errno.EIO, "simulated unreadable error"),
                ),
            ):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files:", output)
            self.assertIn("RRRRRRRR... +32 chars truncated", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_fails_closed_when_open_reports_non_regular_swift_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDirectory.swift"
            swift_file.write_text("struct RaceDirectory {}\n", encoding="utf-8")

            with mock.patch.object(
                check_preview_macros.os,
                "open",
                side_effect=OSError(errno.EISDIR, "is a directory"),
            ):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files:", output)
            self.assertIn("RaceDirectory.swift", output)
            self.assertIn("unsupported non-regular Swift path", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_fails_closed_when_swift_file_is_not_utf8_decodable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            non_utf8_swift = temp_path / "NonUtf8.swift"
            non_utf8_swift.write_bytes(b"\xff")

            return_code, output = self.run_main_with_args(
                roots=[temp_dir],
                token="#Preview",
                allow_empty=True,
            )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files:", output)
            self.assertIn("NonUtf8.swift", output)
            self.assertIn("cannot decode file as UTF-8", output)
            self.assertIn("byte 0", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_preserves_parse_error_counts_when_internal_tracking_is_capped(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            for index in range(3):
                malformed_swift = temp_path / f"Malformed{index}.swift"
                malformed_swift.write_text(
                    'let value = "unterminated\n',
                    encoding="utf-8",
                )

            with mock.patch.object(check_preview_macros, "MAX_TRACKED_PARSE_ERROR_FILES", 1):
                return_code, output = self.run_main_with_args(roots=[temp_dir], token="#Preview")

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files:", output)
            self.assertEqual(output.count("unterminated single-line string literal"), 1)
            self.assertIn("... and 2 more parse-error files not shown.", output)
            self.assertIn("Failure summary: 0 unreadable, 3 parse errors, 0 token matches.", output)

    def test_truncates_stored_parse_error_reason(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            (temp_path / "Parse.swift").write_text("struct P {}\n", encoding="utf-8")
            long_reason = "P" * 40

            with (
                mock.patch.object(check_preview_macros, "MAX_STORED_ERROR_REASON_CHARS", 8),
                mock.patch.object(
                    check_preview_macros,
                    "find_token_matches_with_state",
                    return_value=([], 0, long_reason, 1),
                ),
            ):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files:", output)
            self.assertIn("PPPPPPPP... +32 chars truncated", output)
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)

    def test_fails_closed_when_parse_error_tracking_limit_is_reached(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            for index in range(2):
                malformed_swift = temp_path / f"Malformed{index}.swift"
                malformed_swift.write_text(
                    'let value = "unterminated\n',
                    encoding="utf-8",
                )

            with mock.patch.object(check_preview_macros, "MAX_PARSE_ERROR_FILE_PATHS", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn(
                "Scan aborted after reaching maximum parse-error tracking limit (1).",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 2 Swift files before failure.", output)

    def test_reports_detected_file_with_absolute_path_for_relative_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RelativeRootPreview.swift"
            swift_file.write_text("#Preview { Text(\"flagged\") }\n", encoding="utf-8")

            relative_root = os.path.relpath(temp_dir, pathlib.Path.cwd())
            result = self.run_script("--root", relative_root)
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                f"{os.path.abspath(swift_file)} (lines: 1)",
                result.stdout,
            )

    def test_reports_detected_file_with_utf8_bom(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "BomExample.swift"
            swift_file.write_text(
                "\ufeff#Preview { Text(\"hi\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("BomExample.swift (lines: 1)", result.stdout)

    def test_reports_detected_file_with_uppercase_swift_extension(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Uppercase.SWIFT"
            swift_file.write_text(
                "#Preview { Text(\"hi\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Uppercase.SWIFT (lines: 1)", result.stdout)

    def test_does_not_flag_double_hash_prefixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "DoubleHash.swift"
            swift_file.write_text(
                "##Preview { Text(\"ignored\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_does_not_flag_hash_suffixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "HashSuffix.swift"
            swift_file.write_text(
                "#Preview# { Text(\"ignored\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_does_not_flag_dollar_suffixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "DollarSuffix.swift"
            swift_file.write_text(
                "#Preview$ { Text(\"ignored\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_does_not_flag_dollar_prefixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "DollarPrefix.swift"
            swift_file.write_text(
                "let combined = $#Preview\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_does_not_flag_combining_mark_suffixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "CombiningSuffix.swift"
            swift_file.write_text(
                "#Preview\u0301 { Text(\"ignored\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_does_not_flag_zero_width_joiner_suffixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "JoinerSuffix.swift"
            swift_file.write_text(
                "#Preview\u200d { Text(\"ignored\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_does_not_flag_connector_punctuation_suffixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "ConnectorSuffix.swift"
            swift_file.write_text(
                "#Preview‿ { Text(\"ignored\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_flags_backtick_wrapped_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "BacktickPreview.swift"
            swift_file.write_text(
                "let marker = `#Preview`\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("BacktickPreview.swift (lines: 1)", result.stdout)

    def test_does_not_flag_backtick_hash_suffixed_preview_token_in_script_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "BacktickHashSuffix.swift"
            swift_file.write_text(
                "let marker = `#Preview#`\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("No unsupported token '#Preview' detected", result.stdout)

    def test_reports_only_canonical_preview_when_unicode_prefixed_variant_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "UnicodePrefix.swift"
            swift_file.write_text(
                "let value = α#Preview\n#Preview { Text(\"flagged\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("UnicodePrefix.swift (lines: 2)", result.stdout)
            self.assertNotIn("lines: 1, 2", result.stdout)

    def test_reports_only_canonical_preview_when_combining_mark_prefixed_variant_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "CombiningPrefix.swift"
            swift_file.write_text(
                "let value = pre\u0301#Preview\n#Preview { Text(\"flagged\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("CombiningPrefix.swift (lines: 2)", result.stdout)
            self.assertNotIn("lines: 1, 2", result.stdout)

    def test_reports_only_canonical_preview_when_connector_prefixed_variant_exists(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "ConnectorPrefix.swift"
            swift_file.write_text(
                "let value = pre‿#Preview\n#Preview { Text(\"flagged\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("ConnectorPrefix.swift (lines: 2)", result.stdout)
            self.assertNotIn("lines: 1, 2", result.stdout)

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

    def test_supports_custom_token_ending_with_non_word_character(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "OtherPreviewCall.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    struct OtherPreviewCall: View {
                        var body: some View { Text("ok") }
                    }
                    #MyPreview(OtherPreviewCall())
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir, "--token", "#MyPreview(")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Found unsupported token '#MyPreview('", result.stdout)
            self.assertIn("OtherPreviewCall.swift (lines: 4)", result.stdout)

    def test_supports_custom_token_ending_with_combining_mark(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "CombiningToken.swift"
            swift_file.write_text(
                "#MyPreview\u0301suffix\n#MyPreview\u0301 { Text(\"flagged\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir, "--token", "#MyPreview\u0301")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Found unsupported token '#MyPreview\u0301'", result.stdout)
            self.assertIn("CombiningToken.swift (lines: 2)", result.stdout)
            self.assertNotIn("lines: 1, 2", result.stdout)

    def test_supports_custom_token_ending_with_connector_punctuation(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "ConnectorToken.swift"
            swift_file.write_text(
                "#MyPreview‿suffix\n#MyPreview‿ { Text(\"flagged\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir, "--token", "#MyPreview‿")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Found unsupported token '#MyPreview‿'", result.stdout)
            self.assertIn("ConnectorToken.swift (lines: 2)", result.stdout)
            self.assertNotIn("lines: 1, 2", result.stdout)

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

    def test_fails_when_token_contains_newline(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--token", "#My\nPreview")
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "Configured token must be single-line; newline characters are not allowed.",
                result.stdout,
            )

    def test_fails_when_token_contains_internal_whitespace(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--token", "#My Preview")
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "Configured token must not contain whitespace characters.",
                result.stdout,
            )

    def test_fails_when_token_contains_control_character(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--token", "#My\x01Preview")
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "Configured token must not contain control characters.",
                result.stdout,
            )

    def test_fails_when_token_contains_unicode_format_character(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--token", "#My\u2060Preview")
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "Configured token must not contain control characters.",
                result.stdout,
            )

    def test_fails_when_token_contains_non_ascii_control_character(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            result = self.run_script("--root", temp_dir, "--token", "#My\u009fPreview")
            self.assertEqual(result.returncode, 1)
            self.assertIn(
                "Configured token must not contain control characters.",
                result.stdout,
            )

    def test_fails_when_token_is_not_utf8_encodable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            return_code, output = self.run_main_with_args(
                roots=[temp_dir],
                token="#My\ud800Preview",
                allow_empty=True,
            )
            self.assertEqual(return_code, 1)
            self.assertIn("Configured token must be valid UTF-8 text.", output)

    def test_fails_when_scan_root_is_not_utf8_encodable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            return_code, output = self.run_main_with_args(
                roots=[f"{temp_dir}\ud800"],
                token="#Preview",
                allow_empty=True,
            )
            self.assertEqual(return_code, 1)
            self.assertIn("One or more scan roots are invalid", output)
            self.assertIn("is not valid UTF-8 text", output)
            self.assertIn("\\ud800", output)

    def test_fails_when_token_exceeds_max_utf8_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            oversized_token = "#" + ("a" * check_preview_macros.MAX_TOKEN_BYTES)
            result = self.run_script("--root", temp_dir, "--token", oversized_token)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Configured token is too long", result.stdout)
            self.assertIn(
                f"{check_preview_macros.MAX_TOKEN_BYTES} UTF-8 bytes",
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
            self.assertIn("across 1 Swift files (", result.stdout)

    def test_deduplicates_hardlinked_swift_files_by_file_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            canonical_swift = temp_path / "Canonical.swift"
            hardlinked_swift = temp_path / "Linked.swift"
            canonical_swift.write_text("struct Canonical {}\n", encoding="utf-8")
            try:
                os.link(canonical_swift, hardlinked_swift)
            except (AttributeError, NotImplementedError, OSError) as error:
                self.skipTest(f"Hard-link setup not supported in environment: {error}")

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 0)
            self.assertIn("across 1 Swift files (", result.stdout)

    def test_fails_closed_when_swift_file_is_not_utf8_decodable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Corrupt.swift"
            swift_file.write_bytes(b"\xff\xfe\xfa")

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Corrupt.swift", result.stdout)
            self.assertIn("Scanned 1 Swift files before failure.", result.stdout)

    def test_fails_closed_when_swift_file_is_permission_denied(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            locked_file = temp_path / "Locked.swift"
            locked_file.write_text("struct Locked {}\n", encoding="utf-8")

            try:
                os.chmod(locked_file, 0)
            except OSError as error:
                self.skipTest(f"Could not adjust file permissions for readability test: {error}")

            if os.access(locked_file, os.R_OK):
                os.chmod(locked_file, 0o644)
                self.skipTest("File permission restrictions are not enforced in this environment.")

            try:
                result = self.run_script("--root", temp_dir)
            finally:
                os.chmod(locked_file, 0o644)

            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Locked.swift", result.stdout)
            self.assertIn("permission denied", result.stdout)
            self.assertIn("Scanned 1 Swift files before failure.", result.stdout)

    def test_fails_closed_when_swift_file_exceeds_max_supported_size(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Oversized.swift"
            oversized_payload = b"a" * (check_preview_macros.MAX_SWIFT_FILE_BYTES + 1)
            swift_file.write_bytes(oversized_payload)

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Oversized.swift", result.stdout)
            self.assertIn("file exceeds max supported size", result.stdout)
            self.assertIn(
                f"{check_preview_macros.MAX_SWIFT_FILE_BYTES} bytes",
                result.stdout,
            )
            self.assertIn("Scanned 1 Swift files before failure.", result.stdout)

    def test_fails_closed_when_swift_path_is_non_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            fifo_path = temp_path / "Stream.swift"
            try:
                os.mkfifo(fifo_path)
            except (AttributeError, NotImplementedError, OSError) as error:
                self.skipTest(f"FIFO setup not supported in environment: {error}")

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Stream.swift", result.stdout)
            self.assertIn("unsupported non-regular Swift path", result.stdout)
            self.assertIn("Scanned 1 Swift files before failure.", result.stdout)

    def test_fails_closed_when_swift_identity_changes_between_stat_and_open(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Race.swift"
            swift_file.write_text("struct Race {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat

            def fake_fstat(descriptor: int) -> os.stat_result:
                descriptor_stat = real_fstat(descriptor)
                descriptor_values = list(descriptor_stat)
                descriptor_values[1] = descriptor_stat.st_ino + 1
                return os.stat_result(descriptor_values)

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("Race.swift", output)
            self.assertIn("file identity changed during open/read (possible race", output)
            self.assertRegex(
                output,
                r"file identity changed during open/read \(possible race: \d+:\d+ -> \d+:\d+\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_descriptor_identity_fields_are_non_integer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDescriptorIdentity.swift"
            swift_file.write_text("struct RaceDescriptorIdentity {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 0:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[2] = True
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceDescriptorIdentity.swift", output)
            self.assertIn("cannot read descriptor file identity metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_post_read_identity_fields_are_non_integer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RacePostReadIdentity.swift"
            swift_file.write_text("struct RacePostReadIdentity {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[1] = True
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RacePostReadIdentity.swift", output)
            self.assertIn("cannot read post-read file identity metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_descriptor_size_field_is_non_integer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDescriptorSize.swift"
            swift_file.write_text("struct RaceDescriptorSize {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 0:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[6] = True
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceDescriptorSize.swift", output)
            self.assertIn("cannot read file size metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_descriptor_link_count_field_is_non_positive(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDescriptorLinkCount.swift"
            swift_file.write_text("struct RaceDescriptorLinkCount {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 0:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[3] = 0
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceDescriptorLinkCount.swift", output)
            self.assertIn("cannot read file link-count metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_descriptor_mode_field_is_negative(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDescriptorMode.swift"
            swift_file.write_text("struct RaceDescriptorMode {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 0:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[0] = -1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceDescriptorMode.swift", output)
            self.assertIn("cannot read file mode metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_post_read_link_count_field_is_non_positive(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RacePostReadLinkCount.swift"
            swift_file.write_text("struct RacePostReadLinkCount {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[3] = 0
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RacePostReadLinkCount.swift", output)
            self.assertIn("cannot read post-read file link-count metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_post_read_size_field_is_negative(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RacePostReadSize.swift"
            swift_file.write_text("struct RacePostReadSize {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[6] = -1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RacePostReadSize.swift", output)
            self.assertIn("cannot read post-read file size metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_post_read_mode_field_is_non_integer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RacePostReadMode.swift"
            swift_file.write_text("struct RacePostReadMode {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[0] = True
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RacePostReadMode.swift", output)
            self.assertIn("cannot read post-read file mode metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_descriptor_ownership_field_is_non_integer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDescriptorOwnership.swift"
            swift_file.write_text("struct RaceDescriptorOwnership {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 0:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[4] = True
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceDescriptorOwnership.swift", output)
            self.assertIn("cannot read file ownership metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_post_read_ownership_field_is_negative(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RacePostReadOwnership.swift"
            swift_file.write_text("struct RacePostReadOwnership {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[5] = -1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RacePostReadOwnership.swift", output)
            self.assertIn("cannot read post-read file ownership metadata", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_file_size_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceSize.swift"
            swift_file.write_text("struct RaceSize {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[6] = descriptor_stat.st_size + 1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceSize.swift", output)
            self.assertIn("file size changed during read (possible race", output)
            self.assertRegex(
                output,
                r"file size changed during read \(possible race: \d+ -> \d+ bytes\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_identity_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceIdentity.swift"
            swift_file.write_text("struct RaceIdentity {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[1] = descriptor_stat.st_ino + 1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceIdentity.swift", output)
            self.assertIn("file identity changed during read (possible race", output)
            self.assertRegex(
                output,
                r"file identity changed during read \(possible race: \d+:\d+ -> \d+:\d+\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_device_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceDevice.swift"
            swift_file.write_text("struct RaceDevice {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[2] = descriptor_stat.st_dev + 1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceDevice.swift", output)
            self.assertIn("file identity changed during read (possible race", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_file_metadata_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceMetadata.swift"
            swift_file.write_text("struct RaceMetadata {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[8] = descriptor_stat.st_mtime + 1.0
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceMetadata.swift", output)
            self.assertIn("file metadata changed during read (possible race", output)
            self.assertRegex(
                output,
                r"file metadata changed during read \(possible race: mtime \d+ -> \d+, ctime \d+ -> \d+\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_file_link_count_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceLinks.swift"
            swift_file.write_text("struct RaceLinks {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[3] = descriptor_stat.st_nlink + 1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceLinks.swift", output)
            self.assertIn("file link count changed during read (possible race", output)
            self.assertRegex(
                output,
                r"file link count changed during read \(possible race: \d+ -> \d+\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_file_ownership_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceOwnership.swift"
            swift_file.write_text("struct RaceOwnership {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[4] = descriptor_stat.st_uid + 1
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceOwnership.swift", output)
            self.assertIn("file ownership changed during read (possible race", output)
            self.assertRegex(
                output,
                r"file ownership changed during read \(possible race: uid \d+ -> \d+, gid \d+ -> \d+\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_file_mode_changes_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RaceMode.swift"
            swift_file.write_text("struct RaceMode {}\n", encoding="utf-8")

            real_fstat = check_preview_macros.os.fstat
            fstat_call_count = 0

            def fake_fstat(descriptor: int) -> os.stat_result:
                nonlocal fstat_call_count
                descriptor_stat = real_fstat(descriptor)
                if fstat_call_count == 1:
                    descriptor_values = list(descriptor_stat)
                    descriptor_values[0] = descriptor_stat.st_mode ^ stat.S_IXUSR
                    descriptor_stat = os.stat_result(descriptor_values)
                fstat_call_count += 1
                return descriptor_stat

            with mock.patch.object(check_preview_macros.os, "fstat", side_effect=fake_fstat):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("RaceMode.swift", output)
            self.assertIn("file mode changed during read (possible race", output)
            self.assertRegex(
                output,
                r"file mode changed during read \(possible race: 0o[0-7]+ -> 0o[0-7]+\)",
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)
            self.assertIn("Scanned 1 Swift files before failure.", output)

    def test_fails_closed_when_swift_file_path_cannot_be_resolved(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "Loop.swift"
            try:
                swift_file.symlink_to(swift_file)
            except OSError as error:
                self.skipTest(f"Symlink creation not supported in environment: {error}")

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, "")
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Loop.swift", result.stdout)
            self.assertTrue(
                "cannot resolve path" in result.stdout
                or "Too many levels of symbolic links" in result.stdout
                or "symlinked Swift file not scanned" in result.stdout,
                msg=result.stdout,
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", result.stdout)

    def test_fails_closed_when_directory_traversal_hits_permission_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            blocked_dir = temp_path / "blocked"
            blocked_dir.mkdir(parents=True, exist_ok=True)
            hidden_swift = blocked_dir / "Hidden.swift"
            hidden_swift.write_text("struct Hidden {}\n", encoding="utf-8")

            try:
                os.chmod(blocked_dir, 0)
            except OSError as error:
                self.skipTest(f"Could not adjust directory permissions for traversal test: {error}")

            if os.access(blocked_dir, os.R_OK | os.X_OK):
                os.chmod(blocked_dir, 0o755)
                self.skipTest("Permission restrictions are not enforced in this environment.")

            try:
                result = self.run_script("--root", temp_dir, "--allow-empty")
            finally:
                os.chmod(blocked_dir, 0o755)

            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, "")
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("blocked", result.stdout)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", result.stdout)

    def test_fails_closed_when_directory_symlink_inspection_errors(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            problematic_subdirectory = temp_path / "problematic"
            problematic_subdirectory.mkdir(parents=True, exist_ok=True)

            original_is_symlink = pathlib.Path.is_symlink

            def raising_is_symlink(path: pathlib.Path) -> bool:
                if path == problematic_subdirectory:
                    raise OSError("simulated symlink inspection failure")
                return original_is_symlink(path)

            with mock.patch.object(pathlib.Path, "is_symlink", new=raising_is_symlink):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("problematic", output)
            self.assertIn("cannot inspect directory", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_formats_permission_denied_file_inspection_errors_with_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            problematic_file = temp_path / "Problematic.swift"
            problematic_file.write_text("struct Problematic {}\n", encoding="utf-8")

            original_is_symlink = pathlib.Path.is_symlink

            def raising_is_symlink(path: pathlib.Path) -> bool:
                if path == problematic_file:
                    raise OSError(errno.EACCES, "permission denied", str(problematic_file))
                return original_is_symlink(path)

            with mock.patch.object(pathlib.Path, "is_symlink", new=raising_is_symlink):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("Problematic.swift", output)
            self.assertIn("cannot inspect file (permission denied:", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_formats_symlink_loop_file_resolve_errors_with_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            problematic_file = temp_path / "ResolveLoop.swift"
            problematic_file.write_text("struct ResolveLoop {}\n", encoding="utf-8")

            original_resolve = pathlib.Path.resolve

            def raising_resolve(path: pathlib.Path, strict: bool = False) -> pathlib.Path:
                if path == problematic_file:
                    raise OSError(
                        errno.ELOOP,
                        "too many levels of symbolic links",
                        str(problematic_file),
                    )
                return original_resolve(path, strict=strict)

            with mock.patch.object(pathlib.Path, "resolve", new=raising_resolve):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("ResolveLoop.swift", output)
            self.assertIn("cannot resolve path (symlink loop:", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_formats_runtime_file_resolve_errors_with_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            problematic_file = temp_path / "ResolveRuntime.swift"
            problematic_file.write_text("struct ResolveRuntime {}\n", encoding="utf-8")

            original_resolve = pathlib.Path.resolve

            def raising_resolve(path: pathlib.Path, strict: bool = False) -> pathlib.Path:
                if path == problematic_file:
                    raise RuntimeError("simulated resolution recursion")
                return original_resolve(path, strict=strict)

            with mock.patch.object(pathlib.Path, "resolve", new=raising_resolve):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("ResolveRuntime.swift", output)
            self.assertIn(
                "cannot resolve path (runtime failure: simulated resolution recursion)",
                output,
            )
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_prunes_uninspectable_subdirectory_before_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            problematic_subdirectory = temp_path / "problematic"
            problematic_subdirectory.mkdir(parents=True, exist_ok=True)
            nested_swift = problematic_subdirectory / "NestedPreview.swift"
            nested_swift.write_text("#Preview { Text(\"should not be traversed\") }\n", encoding="utf-8")

            original_is_symlink = pathlib.Path.is_symlink

            def raising_is_symlink(path: pathlib.Path) -> bool:
                if path == problematic_subdirectory:
                    raise OSError("simulated symlink inspection failure")
                return original_is_symlink(path)

            with mock.patch.object(pathlib.Path, "is_symlink", new=raising_is_symlink):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("problematic", output)
            self.assertIn("cannot inspect directory", output)
            self.assertNotIn("Found unsupported token '#Preview'", output)
            self.assertNotIn("NestedPreview.swift", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_formats_permission_denied_symlink_inspection_errors_with_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            problematic_subdirectory = temp_path / "problematic"
            problematic_subdirectory.mkdir(parents=True, exist_ok=True)

            original_is_symlink = pathlib.Path.is_symlink

            def raising_is_symlink(path: pathlib.Path) -> bool:
                if path == problematic_subdirectory:
                    raise OSError(errno.EACCES, "permission denied", str(problematic_subdirectory))
                return original_is_symlink(path)

            with mock.patch.object(pathlib.Path, "is_symlink", new=raising_is_symlink):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("problematic", output)
            self.assertIn("cannot inspect directory (permission denied:", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_handles_bytes_walk_error_filename_without_crashing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            walk_error = OSError(errno.EACCES, "permission denied", b"/tmp/\xffbad")

            def fake_walk(
                _root: pathlib.Path,
                *,
                topdown: bool,
                onerror: object,
                followlinks: bool,
            ) -> object:
                _ = topdown
                _ = followlinks
                if onerror is not None:
                    onerror(walk_error)
                return iter(())

            with mock.patch.object(check_preview_macros.os, "walk", side_effect=fake_walk):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("permission denied", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_formats_symlink_loop_walk_errors_with_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            walk_error = OSError(errno.ELOOP, "too many levels of symbolic links", temp_dir)

            def fake_walk(
                _root: pathlib.Path,
                *,
                topdown: bool,
                onerror: object,
                followlinks: bool,
            ) -> object:
                _ = topdown
                _ = followlinks
                if onerror is not None:
                    onerror(walk_error)
                return iter(())

            with mock.patch.object(check_preview_macros.os, "walk", side_effect=fake_walk):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("cannot traverse directory (symlink loop:", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_formats_non_directory_walk_errors_with_context(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            walk_error = OSError(errno.ENOTDIR, "not a directory", temp_dir)

            def fake_walk(
                _root: pathlib.Path,
                *,
                topdown: bool,
                onerror: object,
                followlinks: bool,
            ) -> object:
                _ = topdown
                _ = followlinks
                if onerror is not None:
                    onerror(walk_error)
                return iter(())

            with mock.patch.object(check_preview_macros.os, "walk", side_effect=fake_walk):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not read one or more Swift files", output)
            self.assertIn("cannot traverse directory (non-directory path:", output)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", output)

    def test_fails_closed_when_root_contains_symlinked_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            symlinked_directory = temp_path / "linked"
            with tempfile.TemporaryDirectory() as target_dir:
                target_path = pathlib.Path(target_dir)
                (target_path / "Hidden.swift").write_text("struct Hidden {}\n", encoding="utf-8")
                try:
                    symlinked_directory.symlink_to(target_path, target_is_directory=True)
                except (NotImplementedError, OSError) as error:
                    self.skipTest(f"Symlink directory setup not supported in environment: {error}")

                result = self.run_script("--root", temp_dir, "--allow-empty")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, "")
                self.assertIn("Could not read one or more Swift files", result.stdout)
                self.assertIn("linked", result.stdout)
                self.assertIn("symlinked directory not traversed", result.stdout)
                self.assertIn(
                    "Failure summary: 1 unreadable, 0 parse errors, 0 token matches.",
                    result.stdout,
                )

    def test_deduplicates_symlinked_directory_error_across_mixed_root_forms(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            nested_dir = temp_path / "nested"
            nested_dir.mkdir(parents=True, exist_ok=True)
            symlinked_directory = nested_dir / "linked"

            with tempfile.TemporaryDirectory() as target_dir:
                try:
                    symlinked_directory.symlink_to(pathlib.Path(target_dir), target_is_directory=True)
                except (NotImplementedError, OSError) as error:
                    self.skipTest(f"Symlink directory setup not supported in environment: {error}")

                root_relative = os.path.relpath(temp_dir, pathlib.Path.cwd())
                result = self.run_script(
                    "--root",
                    root_relative,
                    "--root",
                    str(nested_dir),
                    "--allow-empty",
                )

            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertEqual(result.stdout.count("symlinked directory not traversed"), 1, msg=result.stdout)
            self.assertEqual(result.stdout.count("/nested/linked:"), 1, msg=result.stdout)
            self.assertIn(
                "Failure summary: 1 unreadable, 0 parse errors, 0 token matches.",
                result.stdout,
            )

    def test_fails_closed_when_root_contains_symlinked_swift_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            symlinked_swift = temp_path / "Linked.swift"
            with tempfile.TemporaryDirectory() as target_dir:
                target_file = pathlib.Path(target_dir) / "Real.swift"
                target_file.write_text("struct Real {}\n", encoding="utf-8")
                try:
                    symlinked_swift.symlink_to(target_file)
                except (NotImplementedError, OSError) as error:
                    self.skipTest(f"Symlink file setup not supported in environment: {error}")

                result = self.run_script("--root", temp_dir, "--allow-empty")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stderr, "")
                self.assertIn("Could not read one or more Swift files", result.stdout)
                self.assertIn("Linked.swift", result.stdout)
                self.assertIn("symlinked Swift file not scanned", result.stdout)
                self.assertIn(
                    "Failure summary: 1 unreadable, 0 parse errors, 0 token matches.",
                    result.stdout,
                )

    def test_deduplicates_symlinked_swift_file_across_overlapping_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            nested_root = temp_path / "nested"
            nested_root.mkdir(parents=True, exist_ok=True)
            symlinked_swift = nested_root / "Linked.swift"

            with tempfile.TemporaryDirectory() as target_dir:
                target_file = pathlib.Path(target_dir) / "Real.swift"
                target_file.write_text("struct Real {}\n", encoding="utf-8")
                try:
                    symlinked_swift.symlink_to(target_file)
                except (NotImplementedError, OSError) as error:
                    self.skipTest(f"Symlink file setup not supported in environment: {error}")

                result = self.run_script("--root", temp_dir, "--root", str(nested_root))

            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("symlinked Swift file not scanned", result.stdout)
            self.assertEqual(result.stdout.count("Linked.swift"), 1, msg=result.stdout)
            self.assertIn(
                "Failure summary: 1 unreadable, 0 parse errors, 0 token matches.",
                result.stdout,
            )
            self.assertIn("Scanned 1 Swift files before failure.", result.stdout)

    def test_deduplicates_symlinked_swift_file_across_mixed_root_forms(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            nested_root = temp_path / "nested"
            nested_root.mkdir(parents=True, exist_ok=True)
            symlinked_swift = nested_root / "Linked.swift"

            with tempfile.TemporaryDirectory() as target_dir:
                target_file = pathlib.Path(target_dir) / "Real.swift"
                target_file.write_text("struct Real {}\n", encoding="utf-8")
                try:
                    symlinked_swift.symlink_to(target_file)
                except (NotImplementedError, OSError) as error:
                    self.skipTest(f"Symlink file setup not supported in environment: {error}")

                root_relative = os.path.relpath(temp_dir, pathlib.Path.cwd())
                result = self.run_script("--root", root_relative, "--root", str(nested_root))

            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("symlinked Swift file not scanned", result.stdout)
            self.assertEqual(result.stdout.count("/nested/Linked.swift:"), 1, msg=result.stdout)
            self.assertIn(
                "Failure summary: 1 unreadable, 0 parse errors, 0 token matches.",
                result.stdout,
            )
            self.assertIn("Scanned 1 Swift files before failure.", result.stdout)

    def test_fails_closed_when_root_directory_is_unreadable(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            blocked_root = temp_path / "blocked_root"
            blocked_root.mkdir(parents=True, exist_ok=True)

            try:
                os.chmod(blocked_root, 0)
            except OSError as error:
                self.skipTest(f"Could not adjust root permissions for traversal test: {error}")

            if os.access(blocked_root, os.R_OK | os.X_OK):
                os.chmod(blocked_root, 0o755)
                self.skipTest("Permission restrictions are not enforced in this environment.")

            try:
                result = self.run_script("--root", str(blocked_root), "--allow-empty")
            finally:
                os.chmod(blocked_root, 0o755)

            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, "")
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("blocked_root", result.stdout)
            self.assertIn("Failure summary: 1 unreadable, 0 parse errors, 0 token matches.", result.stdout)

    def test_unreadable_root_does_not_emit_no_swift_discovered_message(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            blocked_root = temp_path / "blocked_root"
            blocked_root.mkdir(parents=True, exist_ok=True)

            try:
                os.chmod(blocked_root, 0)
            except OSError as error:
                self.skipTest(f"Could not adjust root permissions for traversal test: {error}")

            if os.access(blocked_root, os.R_OK | os.X_OK):
                os.chmod(blocked_root, 0o755)
                self.skipTest("Permission restrictions are not enforced in this environment.")

            try:
                result = self.run_script("--root", str(blocked_root))
            finally:
                os.chmod(blocked_root, 0o755)

            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertNotIn("No Swift files were discovered in configured roots", result.stdout)

    def test_reports_unreadable_and_parse_errors_together(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            unreadable_file = temp_path / "Corrupt.swift"
            unreadable_file.write_bytes(b"\xff\xfe\xfa")
            parse_error_file = temp_path / "UnmatchedCloser.swift"
            parse_error_file.write_text(
                "let value = 1\n*/\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not read one or more Swift files", result.stdout)
            self.assertIn("Corrupt.swift", result.stdout)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn("UnmatchedCloser.swift", result.stdout)
            self.assertIn("Failure summary: 1 unreadable, 1 parse errors, 0 token matches.", result.stdout)

    def test_reports_parse_errors_and_token_matches_together(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            parse_error_file = temp_path / "UnmatchedCloser.swift"
            parse_error_file.write_text(
                "let value = 1\n*/\n",
                encoding="utf-8",
            )
            preview_file = temp_path / "HasPreview.swift"
            preview_file.write_text(
                "#Preview { Text(\"flagged\") }\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn("UnmatchedCloser.swift", result.stdout)
            self.assertIn("Found unsupported token '#Preview' in Swift sources", result.stdout)
            self.assertIn("HasPreview.swift (lines: 1)", result.stdout)
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 1 token matches.", result.stdout)

    def test_fails_closed_on_unterminated_block_comment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "UnterminatedBlockComment.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    /* unterminated comment
                    #Preview {
                        Text("not reliably parseable")
                    }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn("UnterminatedBlockComment.swift", result.stdout)
            self.assertIn("unterminated block comment", result.stdout)

    def test_reports_parse_error_file_with_absolute_path_for_relative_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RelativeRootParseError.swift"
            swift_file.write_text("let value = 1\n*/\n", encoding="utf-8")

            relative_root = os.path.relpath(temp_dir, pathlib.Path.cwd())
            result = self.run_script("--root", relative_root)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn(os.path.abspath(swift_file), result.stdout)
            self.assertIn("unmatched block comment closer", result.stdout)

    def test_fails_closed_on_unterminated_multiline_string(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "UnterminatedMultilineString.swift"
            swift_file.write_text(
                textwrap.dedent(
                    '''
                    let value = """
                    still in string
                    #Preview {
                        Text("not reliably parseable")
                    }
                    '''
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn("UnterminatedMultilineString.swift", result.stdout)
            self.assertIn("unterminated multiline string literal", result.stdout)

    def test_fails_closed_on_unterminated_single_line_string(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "UnterminatedSingleLineString.swift"
            swift_file.write_text(
                textwrap.dedent(
                    '''
                    let value = "unterminated
                    #Preview {
                        Text("not reliably parseable")
                    }
                    '''
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn("UnterminatedSingleLineString.swift", result.stdout)
            self.assertIn("unterminated single-line string literal", result.stdout)

    def test_fails_closed_on_unmatched_block_comment_closer(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "UnmatchedBlockCloser.swift"
            swift_file.write_text(
                textwrap.dedent(
                    """
                    let value = 1
                    */
                    #Preview {
                        Text("not reliably parseable")
                    }
                    """
                ).strip() + "\n",
                encoding="utf-8",
            )

            result = self.run_script("--root", temp_dir)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not reliably parse one or more Swift files", result.stdout)
            self.assertIn("UnmatchedBlockCloser.swift", result.stdout)
            self.assertIn("unmatched block comment closer", result.stdout)

    def test_fails_closed_on_excessive_block_comment_nesting(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "NestedBlockCommentDepth.swift"
            swift_file.write_text(
                "/* /* /* */ */ */\n#Preview { Text(\"not reliably parseable\") }\n",
                encoding="utf-8",
            )

            with mock.patch.object(check_preview_macros, "MAX_BLOCK_COMMENT_NESTING", 2):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files", output)
            self.assertIn("NestedBlockCommentDepth.swift", output)
            self.assertIn(
                "block comment nesting exceeds maximum supported depth (2) at line 1",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)

    def test_fails_closed_on_excessive_raw_string_hash_delimiter(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "RawStringDelimiterDepth.swift"
            swift_file.write_text(
                '##"value"##\n#Preview { Text("not reliably parseable") }\n',
                encoding="utf-8",
            )

            with mock.patch.object(check_preview_macros, "MAX_RAW_STRING_DELIMITER_HASHES", 1):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files", output)
            self.assertIn("RawStringDelimiterDepth.swift", output)
            self.assertIn(
                "raw string delimiter exceeds maximum supported hash count (1) at line 1",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)

    def test_fails_closed_on_excessive_file_line_count(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "TooManyLines.swift"
            swift_file.write_text("line1\nline2\nline3\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_SWIFT_FILE_LINES", 2):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files", output)
            self.assertIn("TooManyLines.swift", output)
            self.assertIn("Swift file exceeds maximum supported line count (2)", output)
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)

    def test_fails_closed_on_excessive_file_line_length(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "TooLongLine.swift"
            swift_file.write_text("abcd\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_SWIFT_LINE_CHARS", 3):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#Preview",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files", output)
            self.assertIn("TooLongLine.swift", output)
            self.assertIn(
                "Swift line exceeds maximum supported character count (3) at line 1",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)

    def test_fails_closed_on_excessive_token_candidate_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "TooManyTokenCandidates.swift"
            swift_file.write_text("#a#a#a#a#a\n", encoding="utf-8")

            with mock.patch.object(check_preview_macros, "MAX_TOKEN_CANDIDATE_CHECKS_PER_LINE", 3):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#a",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files", output)
            self.assertIn("TooManyTokenCandidates.swift", output)
            self.assertIn(
                "token candidate checks exceed maximum supported count (3) at line 1",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)

    def test_fails_closed_on_excessive_total_token_candidate_checks(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            swift_file = temp_path / "TooManyTotalTokenCandidates.swift"
            swift_file.write_text("#a#a#a\n#a#a#a\n", encoding="utf-8")

            with (
                mock.patch.object(check_preview_macros, "MAX_TOKEN_CANDIDATE_CHECKS_PER_LINE", 10),
                mock.patch.object(check_preview_macros, "MAX_TOTAL_TOKEN_CANDIDATE_CHECKS", 5),
            ):
                return_code, output = self.run_main_with_args(
                    roots=[temp_dir],
                    token="#a",
                    allow_empty=True,
                )

            self.assertEqual(return_code, 1)
            self.assertIn("Could not reliably parse one or more Swift files", output)
            self.assertIn("TooManyTotalTokenCandidates.swift", output)
            self.assertIn(
                "total token candidate checks exceed maximum supported count (5) at line 2",
                output,
            )
            self.assertIn("Failure summary: 0 unreadable, 1 parse errors, 0 token matches.", output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
