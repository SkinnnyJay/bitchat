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
        default="bitchat",
        help="Directory to recursively scan for Swift files (default: bitchat).",
    )
    parser.add_argument(
        "--token",
        default="#Preview",
        help="Token to flag as unsupported (default: #Preview).",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root)
    if not root.exists():
        print(f"Scan root does not exist: {root}")
        return 1

    matches: list[Path] = []

    for swift_file in root.rglob("*.swift"):
        if args.token in swift_file.read_text(encoding="utf-8", errors="ignore"):
            matches.append(swift_file)

    if matches:
        print(f"Found unsupported token '{args.token}' in Swift sources:")
        for match in sorted(matches):
            print(f" - {match}")
        return 1

    print(f"No unsupported token '{args.token}' detected in {root}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
