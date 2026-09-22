#!/usr/bin/env python3
"""Fail the build when a string catalog carries a key Xcode has marked stale.

`extractionState: stale` is Xcode saying it built the target and could not find
a call site for this key any more. Either the string is dead and should go, or
its call site hides the literal from the extractor and should be rewritten so
it does not. Neither is a thing to leave lying around: a stale key still ships,
still carries thirteen translations, and the next person to open the project in
Xcode may have it silently deleted from under them, translations and all.

Nothing catches it on its own. The marker appears in a catalog during an
ordinary build, so it lands in the working tree of whoever built last, in a
file too large to read, and rides into a commit as one green line in a diff of
several thousand. That is how it gets in.

This refuses it. It does not touch `manual`, which is a deliberate choice in
the apps that keep unseen keys by hand — it is only the state Xcode assigns by
itself that must not survive a build.

The fix is `prune-xcstrings.py`, which deletes a stale key that appears nowhere
in the sources and marks one that does as `manual` so Xcode stops reaping it.

Usage: check-stale-strings.py <root> [<root> ...]
       check-stale-strings.py .

Exit 0 clean, 65 when a stale key is found, 66 when a catalog will not parse.
"""

import json
import os
import sys

SKIP_DIRS = {
    ".git", ".build", ".swiftpm", "DerivedData", "build", "Pods", "Carthage",
    "node_modules", ".index-build", "index-build",
}


def catalogs(roots):
    """Every .xcstrings under the roots, minus anything a build wrote."""
    for root in roots:
        if os.path.isfile(root) and root.endswith(".xcstrings"):
            yield root
            continue
        for directory, subdirs, files in os.walk(root):
            subdirs[:] = [d for d in subdirs if d not in SKIP_DIRS]
            for name in sorted(files):
                if name.endswith(".xcstrings"):
                    yield os.path.join(directory, name)


def stale_keys(path):
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        return []
    return [
        key
        for key, entry in strings.items()
        if isinstance(entry, dict) and entry.get("extractionState") == "stale"
    ]


def main(argv):
    roots = argv[1:] or ["."]
    found = False
    seen = 0
    for path in catalogs(roots):
        seen += 1
        try:
            keys = stale_keys(path)
        except (json.JSONDecodeError, OSError) as error:
            print(f"error: {path} will not parse: {error}", file=sys.stderr)
            return 66
        if not keys:
            continue
        found = True
        shown = keys[:10]
        print(
            f"error: {path} carries {len(keys)} key(s) Xcode marked stale:",
            file=sys.stderr,
        )
        for key in shown:
            print(f"    {key!r}", file=sys.stderr)
        if len(keys) > len(shown):
            print(f"    … and {len(keys) - len(shown)} more", file=sys.stderr)

    if found:
        print(
            "\n    A stale key is one Xcode extracted before and can no longer find a\n"
            "    call site for. Delete it if the string is dead; if the call site is\n"
            "    real and the extractor cannot see the literal — a bare literal at a\n"
            "    `String.LocalizationValue` parameter, say — make it visible there.\n"
            "    `Scripts/prune-xcstrings.py <catalog> <source root> …` does both.\n"
            "    Do not hand-edit the state to `manual` to get past this.",
            file=sys.stderr,
        )
        return 65

    if seen == 0:
        print(f"error: no string catalog under {' '.join(roots)}", file=sys.stderr)
        return 66
    print(f"ok: no key marked stale in {seen} string catalog(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
