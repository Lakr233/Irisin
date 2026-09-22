#!/usr/bin/env python3
"""Fails when text a user reads says "jailbreak", in any language.

The app calls what it runs on custom firmware. Every value of every locale in
the string catalogs is read, with Irisin's page in the Settings app and the
package's control file: a translation is where the word comes back, since a
translator reaches for it on their own. The pages a user reads on the web are
read too: the manual in Documentation/Manual, both languages, and the site's
pages in Documentation/Site. A file whose name starts with `_` is a template,
not a page, and a tree that has no manual yet has nothing to read.

usage: check-wording.py <repository root>
"""

import json
import re
import sys
from pathlib import Path

FORBIDDEN = re.compile(
    r"jailbr|越狱|越獄|脱獄|탈옥|джейлбрейк|جيلبريك|كسر الحماية|bẻ khóa"
    r"|जेल\s*ब्रेक|জেল\s*ব্রেক",
    re.IGNORECASE,
)


def catalog_values(path: Path):
    for key, entry in json.loads(path.read_text())["strings"].items():
        if FORBIDDEN.search(key):
            yield "key", key
        for locale, localization in entry.get("localizations", {}).items():
            yield from unit_values(locale, localization)


def unit_values(locale, node):
    """Every `value` under a localization: plain, plural or by device."""
    if isinstance(node, dict):
        for name, child in node.items():
            if name == "value" and isinstance(child, str):
                yield locale, child
            else:
                yield from unit_values(locale, child)


def web_pages(directory: Path):
    """Every page under a directory; `rglob` finds none where there is none."""
    return [
        page
        for page in sorted(directory.rglob("*.html"))
        if not page.name.startswith("_")
    ]


def main() -> int:
    root = Path(sys.argv[1])
    resources = root / "Irisin" / "Resources"
    hits = []
    for catalog in sorted(resources.glob("*.xcstrings")):
        hits += [
            f"{catalog.relative_to(root)} [{locale}]: {value}"
            for locale, value in catalog_values(catalog)
            if FORBIDDEN.search(value)
        ]
    texts = sorted((resources / "Settings.bundle").rglob("*.strings"))
    texts += sorted((resources / "Settings.bundle").rglob("*.plist"))
    texts.append(root / "Packaging" / "DEBIAN" / "control")
    for pages in ("Manual", "Site"):
        texts += web_pages(root / "Documentation" / pages)
    for text in texts:
        content = text.read_bytes().decode("utf-16" if text.read_bytes()[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", "replace")
        hits += [
            f"{text.relative_to(root)}:{number}: {line.strip()}"
            for number, line in enumerate(content.splitlines(), 1)
            if FORBIDDEN.search(line)
        ]
    if hits:
        print('error: user-facing text says "custom firmware", never "jailbreak"', file=sys.stderr)
        print("\n".join(hits), file=sys.stderr)
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main())
