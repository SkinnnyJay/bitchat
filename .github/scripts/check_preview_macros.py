#!/usr/bin/env python3
"""
Fail if Swift source under `bitchat/` contains `#Preview` macros.

This enforces PreviewProvider-only previews to avoid toolchain-specific
`DeveloperToolsSupport.Preview` ambiguity issues seen in CI.
"""

from __future__ import annotations

import argparse
from pathlib import Path
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
    return parser.parse_args()


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
    scanned_files = 0

    for root in roots:
        for swift_file in root.rglob("*.swift"):
            scanned_files += 1
            if args.token in swift_file.read_text(encoding="utf-8", errors="ignore"):
                matches.append(swift_file)

    if matches:
        print(f"Found unsupported token '{args.token}' in Swift sources:")
        for match in sorted(matches):
            print(f" - {match}")
        return 1

    joined_roots = ", ".join(str(root) for root in roots)
    print(
        f"No unsupported token '{args.token}' detected in roots [{joined_roots}] "
        f"across {scanned_files} Swift files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
