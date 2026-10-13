#!/usr/bin/env python3
"""Fail on what the deployment target promises and the sources do not keep.

The compiler checks API availability against IPHONEOS_DEPLOYMENT_TARGET and
nothing else. Three things below it say no word on the floor:

- A local package whose `platforms` is above the floor. Xcode builds it at
  its own minimum, so its own guards are checked against the wrong version.
- An SF Symbol newer than the floor. `UIImage(systemName:)` answers nil and
  the control draws with no icon. Any string literal that names a symbol is
  checked, not only `systemName:`, since this app hands symbols around as
  `symbol:` and `icon:` too. A literal on the guarded side of an
  `#available(iOS N` check (on its line, or up to three lines after it, and
  before its `else`) may need iOS N, no more.
- A recommended repository list without a Procursus suite for some iOS
  release from the floor up: onboarding on that release recommends no
  bootstrap repository at all, or one built for another release.

Usage: check-floor-sources.py <floor> <repository root>
"""

import plistlib
import re
import sys
from pathlib import Path

GLYPHS = Path(
    "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
)
# Literals that are symbol names by accident: a file extension, a word.
NOT_SYMBOLS = {"fish"}
LITERAL = re.compile(r'"([a-z0-9]+(?:\.[a-z0-9]+)*)"')
PLATFORM = re.compile(r"\.iOS\(\s*(?:\.v(\d+)(?:_(\d+))?|\"([0-9.]+)\")\s*\)")
AVAILABLE = re.compile(r"#available\(iOS (\d+(?:\.\d+)?)")


def version_key(version: str) -> tuple:
    # padded, so 16 and 16.0 compare equal
    return (tuple(int(part) for part in version.split(".")) + (0, 0))[:3]


def check_packages(floor: tuple, root: Path) -> list:
    errors = []
    for manifest in sorted((root / "Packages").glob("*/Package.swift")):
        for match in PLATFORM.finditer(manifest.read_text(encoding="utf-8")):
            major, minor, literal = match.groups()
            version = version_key(literal) if literal else (int(major), int(minor or 0))
            if version[:2] != floor[:2]:
                errors.append(
                    f"{manifest.relative_to(root)}: platforms says iOS {'.'.join(map(str, version))}, "
                    f"the deployment target is {'.'.join(map(str, floor))}"
                )
    return errors


def check_symbols(floor: tuple, root: Path) -> list:
    try:
        table = plistlib.loads(GLYPHS.read_bytes())
    except OSError:
        print(f"note: {GLYPHS.name} is not available here; SF Symbols not checked", file=sys.stderr)
        return []
    symbols, releases = table["symbols"], table["year_to_release"]
    sources = [root / "Irisin"] + [
        package / "Sources" for package in sorted((root / "Packages").iterdir()) if (package / "Sources").is_dir()
    ]
    errors = []
    for source in sources:
        for path in sorted(source.rglob("*.swift")):
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
            for index, line in enumerate(lines):
                for name, allowed in guarded_literals(lines, index, floor):
                    if name in NOT_SYMBOLS:
                        continue
                    release = releases.get(symbols.get(name, ""), {}).get("iOS")
                    if release and version_key(release) > allowed:
                        errors.append(f"{path.relative_to(root)}:{index + 1}: {name} needs iOS {release}")
    return errors


def guarded_literals(lines: list, index: int, floor: tuple):
    """Each literal on the line with the iOS it may need: the version of the
    `#available` whose guarded side it is on, the floor otherwise."""
    line = lines[index]
    guard = AVAILABLE.search(line)
    if guard:
        # `if #available(iOS 16, *) { "a" } else { "b" }`: "a" is guarded
        head, _, tail = line[guard.end() :].partition("else")
        allowed = version_key(guard.group(1))
        return [(name, allowed) for name in LITERAL.findall(head)] + [(name, floor) for name in LITERAL.findall(tail)]
    for back in range(1, 4):
        previous = index - back
        if previous < 0:
            break
        between = lines[previous + 1 : index + 1]
        if any("else" in text for text in between):
            break
        guard = AVAILABLE.search(lines[previous])
        if guard and "else" not in lines[previous][guard.end() :]:
            return [(name, version_key(guard.group(1))) for name in LITERAL.findall(line)]
    return [(name, floor) for name in LITERAL.findall(line)]


def check_recommended(floor: tuple, root: Path) -> list:
    errors = []
    for path in sorted((root / "Irisin/Resources/Environments").glob("default-list-iphoneos-*.plist")):
        entries = plistlib.loads(path.read_bytes())
        suites = [entry for entry in entries if "procurs" in entry["source"]]
        # every bound named, and one past the highest, must be covered; one
        # suite left open at the top covers every release after it
        bounds = [entry.get(key, 0) for entry in suites for key in ("minimumSystemVersion", "maximumSystemVersion")]
        if not any("maximumSystemVersion" not in entry for entry in suites):
            errors.append(f"{path.relative_to(root)}: no Procursus suite is left open for the newest iOS")
        for major in range(floor[0], max(bounds + [floor[0]]) + 2):
            covered = [
                entry["source"]
                for entry in entries
                if "procurs" in entry["source"]
                and entry.get("minimumSystemVersion", 0) <= major <= entry.get("maximumSystemVersion", 99)
            ]
            if len(covered) != 1:
                errors.append(
                    f"{path.relative_to(root)}: iOS {major} is recommended "
                    f"{len(covered)} Procursus suites, not one: {covered}"
                )
    return errors


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    floor = version_key(sys.argv[1])
    root = Path(sys.argv[2])
    errors = check_packages(floor, root) + check_symbols(floor, root) + check_recommended(floor, root)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(f"error: {len(errors)} source(s) break the iOS {sys.argv[1]} floor", file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
