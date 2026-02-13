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


def find_token_line_numbers(content: str, token: str) -> list[int]:
    """
    Return 1-based line numbers where `token` appears as an invocation-like
    directive at start-of-code (ignoring comments and leading whitespace).
    """
    pattern = re.compile(rf"^\s*{re.escape(token)}\b")
    matches: list[int] = []
    in_block_comment = False

    for line_number, line in enumerate(content.splitlines(), start=1):
        cursor = 0
        line_has_match = False

        while cursor < len(line):
            if in_block_comment:
                block_end = line.find("*/", cursor)
                if block_end == -1:
                    cursor = len(line)
                    continue
                cursor = block_end + 2
                in_block_comment = False
                continue

            block_start = line.find("/*", cursor)
            code_segment = line[cursor:] if block_start == -1 else line[cursor:block_start]
            inline_comment = code_segment.find("//")
            if inline_comment != -1:
                code_segment = code_segment[:inline_comment]
                block_start = -1

            if pattern.search(code_segment):
                matches.append(line_number)
                line_has_match = True
                break

            if block_start == -1:
                cursor = len(line)
            else:
                cursor = block_start + 2
                in_block_comment = True

        if line_has_match:
            continue

    return matches


def main() -> int:
    args = parse_args()

    roots = [Path(raw) for raw in (args.root or ["bitchat", "bitchatShareExtension"])]
    missing_roots = [root for root in roots if not root.exists()]
    if missing_roots:
        print("One or more scan roots do not exist:")
        for root in missing_roots:
            print(f" - {root}")
        return 1

    matches: list[Path] = []
    matches_with_lines: dict[Path, list[int]] = {}
    scanned_files = 0

    for root in roots:
        for swift_file in root.rglob("*.swift"):
            scanned_files += 1
            content = swift_file.read_text(encoding="utf-8", errors="ignore")
            line_numbers = find_token_line_numbers(content, args.token)
            if line_numbers:
                matches.append(swift_file)
                matches_with_lines[swift_file] = line_numbers

    if scanned_files == 0 and not args.allow_empty:
        joined_roots = ", ".join(str(root) for root in roots)
        print(
            "No Swift files were discovered in configured roots; "
            f"failing to avoid false green checks. Roots: [{joined_roots}]"
        )
        return 1

    if matches:
        print(f"Found unsupported token '{args.token}' in Swift sources:")
        for match in sorted(matches):
            line_list = ", ".join(str(line) for line in matches_with_lines.get(match, []))
            print(f" - {match} (lines: {line_list})")
        return 1

    joined_roots = ", ".join(str(root) for root in roots)
    print(
        f"No unsupported token '{args.token}' detected in roots [{joined_roots}] "
        f"across {scanned_files} Swift files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
