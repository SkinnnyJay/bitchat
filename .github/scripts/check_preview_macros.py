#!/usr/bin/env python3
"""
Fail if Swift source under `bitchat/` contains `#Preview` macros.

This enforces PreviewProvider-only previews to avoid toolchain-specific
`DeveloperToolsSupport.Preview` ambiguity issues seen in CI.
"""

from __future__ import annotations

import argparse
import os
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
    directive at declaration boundaries (ignoring comments and string literals).
    """
    if content.startswith("\ufeff"):
        content = content[1:]

    right_boundary = r"(?!\w)" if (token[-1].isalnum() or token[-1] == "_") else ""
    pattern = re.compile(rf"(?<![\w#]){re.escape(token)}{right_boundary}")
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

    def is_string_closer_escaped(
        line: str,
        index: int,
        string_hashes: int,
    ) -> bool:
        if string_hashes == 0:
            return backslash_run_length_before(line, index) % 2 == 1

        escape_prefix = "\\" + ("#" * string_hashes)
        if index < len(escape_prefix):
            return False
        return line[index - len(escape_prefix) : index] == escape_prefix

    for line_number, line in enumerate(content.splitlines(), start=1):
        cursor = 0
        code_chars: list[str] = []

        while cursor < len(line):
            next_pair = line[cursor : cursor + 2]

            if active_string_hashes is not None:
                if active_string_is_multiline:
                    multiline_close = '"""' + ("#" * active_string_hashes)
                    if line.startswith(multiline_close, cursor):
                        if is_string_closer_escaped(line, cursor, active_string_hashes):
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
                    if is_string_closer_escaped(line, cursor, active_string_hashes):
                        cursor += 1
                        continue
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
            if next_pair == "*/":
                return matches, f"unmatched block comment closer at line {line_number}"
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
    if "\n" in token or "\r" in token:
        print("Configured token must be single-line; newline characters are not allowed.")
        return 1
    if any(character.isspace() for character in token):
        print("Configured token must not contain whitespace characters.")
        return 1
    if any(ord(character) < 32 or ord(character) == 127 for character in token):
        print("Configured token must not contain control characters.")
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

        root = Path(trimmed_root).expanduser()
        try:
            root_key = root.resolve(strict=False)
        except RuntimeError as error:
            invalid_roots[str(root)] = f"cannot resolve path ({error})"
            continue
        except OSError:
            root_key = root.absolute()
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
        traversal_errors: dict[Path, str] = {}

        def record_walk_error(error: OSError) -> None:
            error_path = Path(error.filename) if error.filename is not None else root
            traversal_errors[error_path] = str(error)

        for directory, subdirectories, filenames in os.walk(
            root,
            topdown=True,
            onerror=record_walk_error,
            followlinks=False,
        ):
            symlinked_subdirectories: list[Path] = []
            for subdirectory in list(subdirectories):
                subdirectory_path = Path(directory) / subdirectory
                try:
                    if subdirectory_path.is_symlink():
                        symlinked_subdirectories.append(subdirectory_path)
                except OSError as error:
                    traversal_errors[subdirectory_path] = f"cannot inspect directory ({error})"

            for symlinked_subdirectory in sorted(symlinked_subdirectories):
                traversal_errors[
                    symlinked_subdirectory
                ] = "symlinked directory not traversed (followlinks disabled)"
                subdirectories.remove(symlinked_subdirectory.name)

            subdirectories.sort()
            filenames.sort()
            for filename in filenames:
                if not filename.lower().endswith(".swift"):
                    continue

                swift_file = Path(directory) / filename
                try:
                    resolved_file = swift_file.resolve()
                except (RuntimeError, OSError) as error:
                    unresolved_key = swift_file.absolute()
                    if unresolved_key in seen_files:
                        continue
                    seen_files.add(unresolved_key)
                    scanned_files += 1
                    unreadable_files[swift_file] = f"cannot resolve path ({error})"
                    continue
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

        for error_path, error_message in traversal_errors.items():
            unreadable_files[error_path] = error_message

    has_failure = False

    if unreadable_files:
        has_failure = True
        print("Could not read one or more Swift files:")
        for swift_file in sorted(unreadable_files):
            print(f" - {swift_file}: {unreadable_files[swift_file]}")

    if parse_error_files:
        has_failure = True
        print("Could not reliably parse one or more Swift files:")
        for swift_file in sorted(parse_error_files):
            print(f" - {swift_file}: {parse_error_files[swift_file]}")

    if scanned_files == 0 and not args.allow_empty and not unreadable_files:
        has_failure = True
        joined_roots = ", ".join(str(root) for root in roots)
        print(
            "No Swift files were discovered in configured roots; "
            f"failing to avoid false green checks. Roots: [{joined_roots}]"
        )

    if matches:
        has_failure = True
        print(f"Found unsupported token '{token}' in Swift sources:")
        for match in sorted(matches):
            line_list = ", ".join(str(line) for line in matches_with_lines.get(match, []))
            print(f" - {match} (lines: {line_list})")

    if has_failure:
        print(
            "Failure summary: "
            f"{len(unreadable_files)} unreadable, "
            f"{len(parse_error_files)} parse errors, "
            f"{len(matches)} token matches."
        )
        print(f"Scanned {scanned_files} Swift files before failure.")
        return 1

    joined_roots = ", ".join(str(root) for root in roots)
    print(
        f"No unsupported token '{token}' detected in roots [{joined_roots}] "
        f"across {scanned_files} Swift files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
