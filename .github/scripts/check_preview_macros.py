#!/usr/bin/env python3
"""
Fail if Swift source under `bitchat/` contains `#Preview` macros.

This enforces PreviewProvider-only previews to avoid toolchain-specific
`DeveloperToolsSupport.Preview` ambiguity issues seen in CI.
"""

from __future__ import annotations

from pathlib import Path
import sys


def has_preview_macro(path: Path) -> bool:
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        content = path.read_text(encoding="utf-8", errors="ignore")
    return "#Preview" in content


def main() -> int:
    root = Path("bitchat")
    matches: list[Path] = []

    for swift_file in root.rglob("*.swift"):
        if has_preview_macro(swift_file):
            matches.append(swift_file)

    if matches:
        print("Found unsupported #Preview macro usage:")
        for match in sorted(matches):
            print(f" - {match}")
        return 1

    print("No #Preview macro usage detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
