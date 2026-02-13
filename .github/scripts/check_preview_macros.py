#!/usr/bin/env python3
"""
Fail if Swift source under `bitchat/` contains `#Preview` macros.

This enforces PreviewProvider-only previews to avoid toolchain-specific
`DeveloperToolsSupport.Preview` ambiguity issues seen in CI.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fail if unsupported preview macro tokens are found in Swift files."
    )
    parser.add_argument(
        "--root",
        action="append",
        default=[],
        help=(
            "Directory to recursively scan for Swift files. "
            "Can be provided multiple times."
        ),
    )
    parser.add_argument(
        "--token",
        default="#Preview",
        help="Token to flag as unsupported (default: #Preview).",
    )
    parser.add_argument(
        "--allow-empty",
        action="store_true",
        help=(
            "Allow success when no Swift files are discovered in scan roots. "
            "By default this is treated as a configuration error."
        ),
    )
    return parser.parse_args()


def find_token_line_numbers_with_state(content: str, token: str) -> tuple[list[int], str | None]:
    """
    Return 1-based line numbers where `token` appears as an invocation-like
    directive at start-of-code (ignoring comments and leading whitespace).
    """
    pattern = re.compile(rf"^\s*{re.escape(token)}\b")
    matches: list[int] = []
    block_comment_starts: list[int] = []
    active_string_hashes: int | None = None
    active_string_is_multiline = False
    active_string_start_line: int | None = None

    def parse_string_start(line: str, cursor: int) -> tuple[int, bool] | None:
        if cursor >= len(line):
            return None

        hashes = 0
        while cursor + hashes < len(line) and line[cursor + hashes] == "#":
            hashes += 1

        quote_index = cursor + hashes
        if quote_index >= len(line) or line[quote_index] != '"':
            return None

        is_multiline = line.startswith('"""', quote_index)
        quote_width = 3 if is_multiline else 1
        return hashes + quote_width, is_multiline

    def backslash_run_length_before(line: str, index: int) -> int:
        run_length = 0
        cursor = index - 1
        while cursor >= 0 and line[cursor] == "\\":
            run_length += 1
            cursor -= 1
        return run_length

    for line_number, line in enumerate(content.splitlines(), start=1):
        cursor = 0
        code_chars: list[str] = []

        while cursor < len(line):
            next_pair = line[cursor : cursor + 2]

            if active_string_hashes is not None:
                if active_string_is_multiline:
                    multiline_close = '"""' + ("#" * active_string_hashes)
                    if line.startswith(multiline_close, cursor):
                        if (
                            active_string_hashes == 0
                            and backslash_run_length_before(line, cursor) % 2 == 1
                        ):
                            cursor += 1
                            continue
                        cursor += len(multiline_close)
                        active_string_hashes = None
                        active_string_is_multiline = False
                        active_string_start_line = None
                        continue
                    cursor += 1
                    continue

                singleline_close = '"' + ("#" * active_string_hashes)
                if line.startswith(singleline_close, cursor):
                    cursor += len(singleline_close)
                    active_string_hashes = None
                    active_string_start_line = None
                    continue
                if active_string_hashes == 0 and line[cursor] == "\\" and cursor + 1 < len(line):
                    cursor += 2
                    continue
                cursor += 1
                continue

            if block_comment_starts:
                if next_pair == "/*":
                    block_comment_starts.append(line_number)
                    cursor += 2
                    continue
                if next_pair == "*/":
                    _ = block_comment_starts.pop()
                    cursor += 2
                    continue
                cursor += 1
                continue

            if next_pair == "//":
                break
            if next_pair == "/*":
                block_comment_starts.append(line_number)
                cursor += 2
                continue

            string_start = parse_string_start(line, cursor)
            if string_start is not None:
                consumed, is_multiline = string_start
                active_string_hashes = consumed - (3 if is_multiline else 1)
                active_string_is_multiline = is_multiline
                active_string_start_line = line_number
                cursor += consumed
                continue

            code_chars.append(line[cursor])
            cursor += 1

        if active_string_hashes is not None and not active_string_is_multiline:
            start_line = active_string_start_line or line_number
            return matches, f"unterminated single-line string literal (opened at line {start_line})"

        code_segment = "".join(code_chars)
        if pattern.search(code_segment):
            matches.append(line_number)

    if block_comment_starts:
        return matches, f"unterminated block comment (opened at line {block_comment_starts[0]})"
    if active_string_hashes is not None and active_string_is_multiline:
        start_line = active_string_start_line or 1
        return matches, f"unterminated multiline string literal (opened at line {start_line})"

    return matches, None


def find_token_line_numbers(content: str, token: str) -> list[int]:
    matches, _ = find_token_line_numbers_with_state(content, token)
    return matches


def main() -> int:
    args = parse_args()
    token = args.token.strip()
    if not token:
        print("Configured token is empty after trimming; provide a non-empty token.")
        return 1

    raw_roots = args.root or ["bitchat", "bitchatShareExtension"]
    roots: list[Path] = []
    seen_roots: set[Path] = set()
    invalid_roots: dict[str, str] = {}
    for raw_root in raw_roots:
        trimmed_root = raw_root.strip()
        if not trimmed_root:
            invalid_roots[raw_root] = "is empty after trimming"
            continue

        root = Path(trimmed_root)
        root_key = root.expanduser().resolve(strict=False)
        if root_key in seen_roots:
            continue
        seen_roots.add(root_key)
        roots.append(root)

        if not root.exists():
            invalid_roots[str(root)] = "does not exist"
        elif not root.is_dir():
            invalid_roots[str(root)] = "is not a directory"

    if invalid_roots:
        print("One or more scan roots are invalid:")
        for root in sorted(invalid_roots):
            print(f" - {root} ({invalid_roots[root]})")
        return 1

    matches: list[Path] = []
    matches_with_lines: dict[Path, list[int]] = {}
    scanned_files = 0
    seen_files: set[Path] = set()
    unreadable_files: dict[Path, str] = {}
    parse_error_files: dict[Path, str] = {}

    for root in roots:
        for swift_file in sorted(root.rglob("*.swift")):
            resolved_file = swift_file.resolve()
            if resolved_file in seen_files:
                continue
            seen_files.add(resolved_file)
            scanned_files += 1
            try:
                content = swift_file.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                unreadable_files[swift_file] = str(error)
                continue
            line_numbers, parse_error = find_token_line_numbers_with_state(content, token)
            if parse_error is not None:
                parse_error_files[swift_file] = parse_error
                continue
            if line_numbers:
                matches.append(swift_file)
                matches_with_lines[swift_file] = line_numbers

    if unreadable_files:
        print("Could not read one or more Swift files:")
        for swift_file in sorted(unreadable_files):
            print(f" - {swift_file}: {unreadable_files[swift_file]}")
        return 1

    if parse_error_files:
        print("Could not reliably parse one or more Swift files:")
        for swift_file in sorted(parse_error_files):
            print(f" - {swift_file}: {parse_error_files[swift_file]}")
        return 1

    if scanned_files == 0 and not args.allow_empty:
        joined_roots = ", ".join(str(root) for root in roots)
        print(
            "No Swift files were discovered in configured roots; "
            f"failing to avoid false green checks. Roots: [{joined_roots}]"
        )
        return 1

    if matches:
        print(f"Found unsupported token '{token}' in Swift sources:")
        for match in sorted(matches):
            line_list = ", ".join(str(line) for line in matches_with_lines.get(match, []))
            print(f" - {match} (lines: {line_list})")
        return 1

    joined_roots = ", ".join(str(root) for root in roots)
    print(
        f"No unsupported token '{token}' detected in roots [{joined_roots}] "
        f"across {scanned_files} Swift files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
