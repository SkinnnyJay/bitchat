#!/usr/bin/env python3
"""
Fail if Swift source under `bitchat/` contains `#Preview` macros.

This enforces PreviewProvider-only previews to avoid toolchain-specific
`DeveloperToolsSupport.Preview` ambiguity issues seen in CI.
"""

from __future__ import annotations

import argparse
import errno
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata

MAX_TOKEN_BYTES = 256
MAX_SWIFT_FILE_BYTES = 5 * 1024 * 1024
MAX_SCANNED_SWIFT_FILES = 100000
MAX_ROOT_BYTES = 4096
MAX_ROOT_COUNT = 128
MAX_REPORTED_INVALID_ROOTS = 200
MAX_UNREADABLE_FILE_PATHS = 100000
MAX_TRACKED_UNREADABLE_FILES = 200
MAX_REPORTED_UNREADABLE_FILES = 200
MAX_PARSE_ERROR_FILE_PATHS = 100000
MAX_TRACKED_PARSE_ERROR_FILES = 200
MAX_REPORTED_PARSE_ERROR_FILES = 200
MAX_STORED_ERROR_REASON_CHARS = 2048
MAX_TRACKED_TOKEN_MATCH_FILES = 200
MAX_REPORTED_TOKEN_MATCH_FILES = 200
MAX_REPORTED_LINE_NUMBERS_PER_FILE = 50
MAX_TRACKED_LINE_NUMBERS_PER_FILE = 200
MAX_BLOCK_COMMENT_NESTING = 4096
MAX_RAW_STRING_DELIMITER_HASHES = 256
MAX_REPORTED_ROOTS_IN_SUMMARY = 20
MAX_DIAGNOSTIC_TEXT_CHARS = 512
DISALLOWED_CONTROL_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Cn"}


def escape_diagnostic_text(text: str) -> str:
    escaped = text.encode("unicode_escape").decode("ascii")
    if len(escaped) <= MAX_DIAGNOSTIC_TEXT_CHARS:
        return escaped
    omitted_chars = len(escaped) - MAX_DIAGNOSTIC_TEXT_CHARS
    return f"{escaped[:MAX_DIAGNOSTIC_TEXT_CHARS]}... +{omitted_chars} chars truncated"


def format_path_for_diagnostics(path: Path | str) -> str:
    return escape_diagnostic_text(str(path))


def utf8_byte_length_or_none(value: str) -> int | None:
    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError:
        return None


def contains_disallowed_control_characters(value: str) -> bool:
    return any(unicodedata.category(character) in DISALLOWED_CONTROL_CATEGORIES for character in value)


def format_line_numbers_for_diagnostics(
    line_numbers: list[int],
    total_line_number_count: int | None = None,
) -> str:
    if total_line_number_count is None:
        total_line_number_count = len(line_numbers)
    reported_line_numbers = line_numbers[:MAX_REPORTED_LINE_NUMBERS_PER_FILE]
    line_numbers_text = ", ".join(str(line) for line in reported_line_numbers)
    omitted_line_numbers = total_line_number_count - len(reported_line_numbers)
    if omitted_line_numbers > 0:
        return f"{line_numbers_text} ... +{omitted_line_numbers} more"
    return line_numbers_text


def format_roots_for_diagnostics(roots: list[Path]) -> str:
    root_texts = [format_path_for_diagnostics(root) for root in roots]
    reported_root_texts = root_texts[:MAX_REPORTED_ROOTS_IN_SUMMARY]
    roots_text = ", ".join(reported_root_texts)
    omitted_roots = len(root_texts) - MAX_REPORTED_ROOTS_IN_SUMMARY
    if omitted_roots > 0:
        return f"{roots_text} ... +{omitted_roots} more roots"
    return roots_text


def format_open_read_error(error: OSError) -> str:
    if error.errno == errno.ELOOP:
        return "symlinked Swift file not scanned"
    if error.errno in {errno.EACCES, errno.EPERM}:
        return f"cannot open/read file (permission denied: {error})"
    if error.errno == errno.ENOENT:
        return f"path disappeared during scan ({error})"
    return f"cannot open/read file ({error})"


def truncate_error_reason_for_storage(reason: str) -> str:
    if len(reason) <= MAX_STORED_ERROR_REASON_CHARS:
        return reason
    omitted_chars = len(reason) - MAX_STORED_ERROR_REASON_CHARS
    return f"{reason[:MAX_STORED_ERROR_REASON_CHARS]}... +{omitted_chars} chars truncated"


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


def find_token_matches_with_state(
    content: str,
    token: str,
    *,
    max_tracked_line_numbers: int | None = None,
) -> tuple[list[int], int, str | None]:
    """
    Return tracked 1-based line numbers, total match count, and parse state error.
    """
    if content.startswith("\ufeff"):
        content = content[1:]

    right_boundary = r"(?!\w)" if (token[-1].isalnum() or token[-1] == "_") else ""
    pattern = re.compile(rf"(?<![\w#]){re.escape(token)}{right_boundary}")
    matches: list[int] = []
    match_count = 0
    block_comment_starts: list[int] = []
    active_string_hashes: int | None = None
    active_string_is_multiline = False
    active_string_close_token: str | None = None
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
                    if active_string_close_token is not None and line.startswith(
                        active_string_close_token, cursor
                    ):
                        if is_string_closer_escaped(line, cursor, active_string_hashes):
                            cursor += 1
                            continue
                        cursor += len(active_string_close_token)
                        active_string_hashes = None
                        active_string_is_multiline = False
                        active_string_close_token = None
                        active_string_start_line = None
                        continue
                    cursor += 1
                    continue

                if active_string_close_token is not None and line.startswith(
                    active_string_close_token, cursor
                ):
                    if is_string_closer_escaped(line, cursor, active_string_hashes):
                        cursor += 1
                        continue
                    cursor += len(active_string_close_token)
                    active_string_hashes = None
                    active_string_close_token = None
                    active_string_start_line = None
                    continue
                if active_string_hashes == 0 and line[cursor] == "\\" and cursor + 1 < len(line):
                    cursor += 2
                    continue
                cursor += 1
                continue

            if block_comment_starts:
                if next_pair == "/*":
                    if len(block_comment_starts) >= MAX_BLOCK_COMMENT_NESTING:
                        return (
                            matches,
                            match_count,
                            "block comment nesting exceeds maximum supported depth "
                            f"({MAX_BLOCK_COMMENT_NESTING}) at line {line_number}",
                        )
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
                return matches, match_count, f"unmatched block comment closer at line {line_number}"
            if next_pair == "/*":
                if len(block_comment_starts) >= MAX_BLOCK_COMMENT_NESTING:
                    return (
                        matches,
                        match_count,
                        "block comment nesting exceeds maximum supported depth "
                        f"({MAX_BLOCK_COMMENT_NESTING}) at line {line_number}",
                    )
                block_comment_starts.append(line_number)
                cursor += 2
                continue

            if line[cursor] == "#" and cursor > 0 and line[cursor - 1] == "#":
                code_chars.append(line[cursor])
                cursor += 1
                continue

            string_start = parse_string_start(line, cursor)
            if string_start is not None:
                consumed, is_multiline = string_start
                active_string_hashes = consumed - (3 if is_multiline else 1)
                if active_string_hashes > MAX_RAW_STRING_DELIMITER_HASHES:
                    return (
                        matches,
                        match_count,
                        "raw string delimiter exceeds maximum supported hash count "
                        f"({MAX_RAW_STRING_DELIMITER_HASHES}) at line {line_number}",
                    )
                active_string_is_multiline = is_multiline
                active_string_close_token = (
                    ('"""' if is_multiline else '"') + ("#" * active_string_hashes)
                )
                active_string_start_line = line_number
                cursor += consumed
                continue

            code_chars.append(line[cursor])
            cursor += 1

        if active_string_hashes is not None and not active_string_is_multiline:
            start_line = active_string_start_line or line_number
            return (
                matches,
                match_count,
                f"unterminated single-line string literal (opened at line {start_line})",
            )

        code_segment = "".join(code_chars)
        if pattern.search(code_segment):
            match_count += 1
            if max_tracked_line_numbers is None or len(matches) < max_tracked_line_numbers:
                matches.append(line_number)

    if block_comment_starts:
        return (
            matches,
            match_count,
            f"unterminated block comment (opened at line {block_comment_starts[0]})",
        )
    if active_string_hashes is not None and active_string_is_multiline:
        start_line = active_string_start_line or 1
        return (
            matches,
            match_count,
            f"unterminated multiline string literal (opened at line {start_line})",
        )

    return matches, match_count, None


def find_token_line_numbers_with_state(content: str, token: str) -> tuple[list[int], str | None]:
    matches, _, parse_error = find_token_matches_with_state(content, token)
    return matches, parse_error


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
    token_utf8_bytes = utf8_byte_length_or_none(token)
    if token_utf8_bytes is None:
        print("Configured token must be valid UTF-8 text.")
        return 1
    if contains_disallowed_control_characters(token):
        print("Configured token must not contain control characters.")
        return 1
    if token_utf8_bytes > MAX_TOKEN_BYTES:
        print(
            "Configured token is too long; "
            f"must be at most {MAX_TOKEN_BYTES} UTF-8 bytes."
        )
        return 1

    raw_roots = args.root or ["bitchat", "bitchatShareExtension"]
    if len(raw_roots) > MAX_ROOT_COUNT:
        print(
            "Too many scan roots configured; "
            f"provide at most {MAX_ROOT_COUNT} root arguments."
        )
        return 1

    roots: list[Path] = []
    seen_roots: set[Path] = set()
    invalid_roots: dict[str, str] = {}
    for raw_root in raw_roots:
        trimmed_root = raw_root.strip()
        if not trimmed_root:
            invalid_roots[raw_root] = "is empty after trimming"
            continue
        root_utf8_bytes = utf8_byte_length_or_none(trimmed_root)
        if root_utf8_bytes is None:
            invalid_roots[raw_root] = "is not valid UTF-8 text"
            continue
        if root_utf8_bytes > MAX_ROOT_BYTES:
            invalid_roots[raw_root] = (
                "is too long; "
                f"must be at most {MAX_ROOT_BYTES} UTF-8 bytes"
            )
            continue
        if contains_disallowed_control_characters(trimmed_root):
            invalid_roots[raw_root] = "contains control characters"
            continue

        root = Path(trimmed_root).expanduser()
        try:
            root_lstat = root.lstat()
        except FileNotFoundError:
            invalid_roots[str(root)] = "does not exist"
            continue
        except OSError as error:
            invalid_roots[str(root)] = f"cannot access path ({error})"
            continue

        if stat.S_ISLNK(root_lstat.st_mode):
            invalid_roots[str(root)] = "is a symlinked directory (not traversed)"
            continue
        if not stat.S_ISDIR(root_lstat.st_mode):
            invalid_roots[str(root)] = "is not a directory"
            continue

        try:
            root_key = root.resolve(strict=False)
        except RuntimeError as error:
            invalid_roots[str(root)] = f"cannot resolve path ({error})"
            continue
        except OSError:
            root_key = Path(os.path.abspath(root))
        if root_key in seen_roots:
            continue
        seen_roots.add(root_key)
        roots.append(root)

    if invalid_roots:
        print("One or more scan roots are invalid:")
        sorted_invalid_roots = sorted(invalid_roots)
        for root in sorted_invalid_roots[:MAX_REPORTED_INVALID_ROOTS]:
            print(
                " - "
                f"{format_path_for_diagnostics(root)} "
                f"({escape_diagnostic_text(invalid_roots[root])})"
            )
        omitted_invalid_roots = len(sorted_invalid_roots) - MAX_REPORTED_INVALID_ROOTS
        if omitted_invalid_roots > 0:
            print(f" ... and {omitted_invalid_roots} more invalid roots not shown.")
        return 1

    tracked_matches: list[Path] = []
    matches_with_lines: dict[Path, list[int]] = {}
    matches_with_line_counts: dict[Path, int] = {}
    token_match_count = 0
    scanned_files = 0
    seen_files: set[Path] = set()
    seen_file_identities: set[tuple[int, int]] = set()
    tracked_unreadable_files: dict[Path, str] = {}
    unreadable_file_paths: set[Path] = set()
    tracked_parse_error_files: dict[Path, str] = {}
    parse_error_file_paths: set[Path] = set()
    scan_limit_reached = False
    unreadable_limit_reached = False
    parse_error_limit_reached = False

    def report_path(path: Path) -> Path:
        try:
            return Path(os.path.abspath(path))
        except OSError:
            return path

    def record_unreadable(path: Path, reason: str) -> bool:
        nonlocal unreadable_limit_reached
        stored_reason = truncate_error_reason_for_storage(reason)
        reported_path = report_path(path)
        if reported_path in unreadable_file_paths:
            if reported_path in tracked_unreadable_files:
                tracked_unreadable_files[reported_path] = stored_reason
            return True
        if len(unreadable_file_paths) >= MAX_UNREADABLE_FILE_PATHS:
            unreadable_limit_reached = True
            return False
        unreadable_file_paths.add(reported_path)
        if len(tracked_unreadable_files) < MAX_TRACKED_UNREADABLE_FILES:
            tracked_unreadable_files[reported_path] = stored_reason
        return True

    def record_parse_error(path: Path, reason: str) -> bool:
        nonlocal parse_error_limit_reached
        stored_reason = truncate_error_reason_for_storage(reason)
        if path in parse_error_file_paths:
            if path in tracked_parse_error_files:
                tracked_parse_error_files[path] = stored_reason
            return True
        if len(parse_error_file_paths) >= MAX_PARSE_ERROR_FILE_PATHS:
            parse_error_limit_reached = True
            return False
        parse_error_file_paths.add(path)
        if len(tracked_parse_error_files) < MAX_TRACKED_PARSE_ERROR_FILES:
            tracked_parse_error_files[path] = stored_reason
        return True

    def try_increment_scanned_files() -> bool:
        nonlocal scanned_files, scan_limit_reached
        if scanned_files >= MAX_SCANNED_SWIFT_FILES:
            scan_limit_reached = True
            return False
        scanned_files += 1
        return True

    def should_abort_scan() -> bool:
        return scan_limit_reached or unreadable_limit_reached or parse_error_limit_reached

    for root in roots:
        def record_walk_error(error: OSError) -> None:
            error_path = Path(error.filename) if error.filename is not None else root
            _ = record_unreadable(error_path, str(error))

        for directory, subdirectories, filenames in os.walk(
            root,
            topdown=True,
            onerror=record_walk_error,
            followlinks=False,
        ):
            if should_abort_scan():
                break
            symlinked_subdirectories: list[Path] = []
            for subdirectory in list(subdirectories):
                subdirectory_path = Path(directory) / subdirectory
                try:
                    if subdirectory_path.is_symlink():
                        symlinked_subdirectories.append(subdirectory_path)
                except OSError as error:
                    traversal_errors[subdirectory_path] = f"cannot inspect directory ({error})"

            for symlinked_subdirectory in sorted(symlinked_subdirectories):
                if not record_unreadable(
                    symlinked_subdirectory,
                    "symlinked directory not traversed (followlinks disabled)",
                ):
                    break
                subdirectories.remove(symlinked_subdirectory.name)
            if should_abort_scan():
                break

            subdirectories.sort()
            filenames.sort()
            for filename in filenames:
                if not filename.lower().endswith(".swift"):
                    continue

                swift_file = Path(directory) / filename
                unresolved_key = report_path(swift_file)
                try:
                    if swift_file.is_symlink():
                        if unresolved_key in seen_files:
                            continue
                        seen_files.add(unresolved_key)
                        if not try_increment_scanned_files():
                            break
                        if not record_unreadable(swift_file, "symlinked Swift file not scanned"):
                            break
                        continue
                except OSError as error:
                    if unresolved_key in seen_files:
                        continue
                    seen_files.add(unresolved_key)
                    if not try_increment_scanned_files():
                        break
                    if not record_unreadable(swift_file, f"cannot inspect file ({error})"):
                        break
                    continue
                try:
                    resolved_file = swift_file.resolve()
                except (RuntimeError, OSError) as error:
                    if unresolved_key in seen_files:
                        continue
                    seen_files.add(unresolved_key)
                    if not try_increment_scanned_files():
                        break
                    if not record_unreadable(swift_file, f"cannot resolve path ({error})"):
                        break
                    continue
                if resolved_file in seen_files:
                    continue
                seen_files.add(resolved_file)
                try:
                    resolved_stat = resolved_file.stat()
                except OSError as error:
                    if not try_increment_scanned_files():
                        break
                    if not record_unreadable(swift_file, f"cannot inspect file metadata ({error})"):
                        break
                    continue
                file_identity = (resolved_stat.st_dev, resolved_stat.st_ino)
                if file_identity in seen_file_identities:
                    continue
                if not try_increment_scanned_files():
                    break
                seen_file_identities.add(file_identity)
                open_flags = os.O_RDONLY
                open_requires_nonblocking_support = hasattr(os, "O_NONBLOCK")
                if open_requires_nonblocking_support:
                    open_flags |= os.O_NONBLOCK
                if hasattr(os, "O_CLOEXEC"):
                    open_flags |= os.O_CLOEXEC
                if hasattr(os, "O_NOFOLLOW"):
                    open_flags |= os.O_NOFOLLOW
                if not open_requires_nonblocking_support:
                    try:
                        pre_open_stat = swift_file.lstat()
                    except OSError as error:
                        if not record_unreadable(swift_file, f"cannot inspect file metadata ({error})"):
                            break
                        continue
                    if not stat.S_ISREG(pre_open_stat.st_mode):
                        if not record_unreadable(swift_file, "unsupported non-regular Swift path"):
                            break
                        continue
                descriptor = -1
                try:
                    descriptor = os.open(swift_file, open_flags)
                    descriptor_stat = os.fstat(descriptor)
                    if not stat.S_ISREG(descriptor_stat.st_mode):
                        if not record_unreadable(swift_file, "unsupported non-regular Swift path"):
                            break
                        continue
                    file_size_bytes = descriptor_stat.st_size
                    if file_size_bytes > MAX_SWIFT_FILE_BYTES:
                        if not record_unreadable(
                            swift_file,
                            (
                                "file exceeds max supported size "
                                f"({file_size_bytes} bytes > {MAX_SWIFT_FILE_BYTES} bytes)"
                            ),
                        ):
                            break
                        continue
                    with os.fdopen(descriptor, "rb") as file_handle:
                        descriptor = -1
                        raw_content = file_handle.read(MAX_SWIFT_FILE_BYTES + 1)
                except OSError as error:
                    if not record_unreadable(swift_file, format_open_read_error(error)):
                        break
                    continue
                finally:
                    if descriptor >= 0:
                        os.close(descriptor)
                if len(raw_content) > MAX_SWIFT_FILE_BYTES:
                    if not record_unreadable(
                        swift_file,
                        (
                            "file exceeds max supported size "
                            f"(>= {len(raw_content)} bytes > {MAX_SWIFT_FILE_BYTES} bytes)"
                        ),
                    ):
                        break
                    continue
                try:
                    content = raw_content.decode("utf-8")
                except UnicodeDecodeError as error:
                    if not record_unreadable(swift_file, str(error)):
                        break
                    continue
                line_numbers, line_number_count, parse_error = find_token_matches_with_state(
                    content,
                    token,
                    max_tracked_line_numbers=MAX_TRACKED_LINE_NUMBERS_PER_FILE,
                )
                reported_swift_file = report_path(swift_file)
                if parse_error is not None:
                    if not record_parse_error(reported_swift_file, parse_error):
                        break
                    continue
                if line_number_count > 0:
                    token_match_count += 1
                    if len(tracked_matches) < MAX_TRACKED_TOKEN_MATCH_FILES:
                        tracked_matches.append(reported_swift_file)
                        matches_with_lines[reported_swift_file] = line_numbers
                        matches_with_line_counts[reported_swift_file] = line_number_count
            if should_abort_scan():
                break

        if should_abort_scan():
            break

    has_failure = False

    if unreadable_file_paths:
        has_failure = True
        print("Could not read one or more Swift files:")
        sorted_tracked_unreadable_files = sorted(tracked_unreadable_files)
        reported_unreadable_files = sorted_tracked_unreadable_files[:MAX_REPORTED_UNREADABLE_FILES]
        for swift_file in reported_unreadable_files:
            print(
                " - "
                f"{format_path_for_diagnostics(swift_file)}: "
                f"{escape_diagnostic_text(tracked_unreadable_files[swift_file])}"
            )
        omitted_unreadable_count = len(unreadable_file_paths) - len(reported_unreadable_files)
        if omitted_unreadable_count > 0:
            print(f" ... and {omitted_unreadable_count} more unreadable files not shown.")

    if parse_error_file_paths:
        has_failure = True
        print("Could not reliably parse one or more Swift files:")
        sorted_tracked_parse_error_files = sorted(tracked_parse_error_files)
        reported_parse_error_files = sorted_tracked_parse_error_files[:MAX_REPORTED_PARSE_ERROR_FILES]
        for swift_file in reported_parse_error_files:
            print(
                " - "
                f"{format_path_for_diagnostics(swift_file)}: "
                f"{escape_diagnostic_text(tracked_parse_error_files[swift_file])}"
            )
        omitted_parse_error_count = len(parse_error_file_paths) - len(reported_parse_error_files)
        if omitted_parse_error_count > 0:
            print(f" ... and {omitted_parse_error_count} more parse-error files not shown.")

    if scanned_files == 0 and not args.allow_empty and not unreadable_file_paths:
        has_failure = True
        joined_roots = format_roots_for_diagnostics(roots)
        print(
            "No Swift files were discovered in configured roots; "
            f"failing to avoid false green checks. Roots: [{joined_roots}]"
        )

    if token_match_count > 0:
        has_failure = True
        print(f"Found unsupported token '{token}' in Swift sources:")
        sorted_tracked_matches = sorted(tracked_matches)
        reported_matches = sorted_tracked_matches[:MAX_REPORTED_TOKEN_MATCH_FILES]
        for match in reported_matches:
            line_list = format_line_numbers_for_diagnostics(
                matches_with_lines.get(match, []),
                matches_with_line_counts.get(match),
            )
            print(f" - {format_path_for_diagnostics(match)} (lines: {line_list})")
        omitted_match_count = token_match_count - len(reported_matches)
        if omitted_match_count > 0:
            print(f" ... and {omitted_match_count} more files not shown.")

    if scan_limit_reached:
        has_failure = True
        print(
            "Scan aborted after reaching maximum Swift file limit "
            f"({MAX_SCANNED_SWIFT_FILES})."
        )
    if unreadable_limit_reached:
        has_failure = True
        print(
            "Scan aborted after reaching maximum unreadable-path tracking limit "
            f"({MAX_UNREADABLE_FILE_PATHS})."
        )
    if parse_error_limit_reached:
        has_failure = True
        print(
            "Scan aborted after reaching maximum parse-error tracking limit "
            f"({MAX_PARSE_ERROR_FILE_PATHS})."
        )

    if has_failure:
        print(
            "Failure summary: "
            f"{len(unreadable_file_paths)} unreadable, "
            f"{len(parse_error_file_paths)} parse errors, "
            f"{token_match_count} token matches."
        )
        print(f"Scanned {scanned_files} Swift files before failure.")
        return 1

    joined_roots = format_roots_for_diagnostics(roots)
    print(
        f"No unsupported token '{token}' detected in roots [{joined_roots}] "
        f"across {scanned_files} Swift files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
