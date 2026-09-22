#!/usr/bin/env python3
"""Tidy a string catalog after Xcode has marked entries stale.

Xcode's extractor only sees `String.LocalizationValue` literals handed to
functions of the same module. A literal handed straight to a package's API
(`AlertProgressIndicatorViewController(title: "Please Wait")`) still resolves
against the catalog at run time, but Xcode marks it stale and, while the
project sits open, deletes it together with its translations. This script
keeps those: a stale key whose quoted text still appears in a source file
becomes `manual`, which Xcode never touches.

**Stale does not mean dead, and this script does not delete by default.** The
extractor reports on the target it just built. An app with an iOS target, a
visionOS target and a macOS target marks every macOS-only string stale after
an iOS build, and every one of them is live. So is a key reached through
interpolation, one named in a xib, and one a package builds from a constant.
A key found nowhere in the roots given is therefore marked `manual` and
printed as an orphan *candidate*, for a person to look at. Nothing is removed
unless `--delete-orphans` says so, and that flag is for a single-target app
whose roots are known to be complete.

Pass EVERY target's sources, not just the app's. If a root is missing, its
strings look orphaned, and with `--delete-orphans` they and all their
translations are gone in one commit.

Usage: prune-xcstrings.py [--delete-orphans] <catalog> <source root> [<source root> ...]
       prune-xcstrings.py <App>/Resources/Localizable.xcstrings <App> Packages/<App>Kit/Sources
       prune-xcstrings.py <App>/Resources/Localizable.xcstrings <App> <App>Mac <App>Widgets Packages

The catalog is written back in Xcode's own layout (two-space indent, a space
before each colon), so the diff is only the entries that changed.
"""

import json
import os
import sys

# Anywhere a catalog key can be written literally. Not only Swift: a key can
# be named in a xib, a storyboard, an intent definition or an Info.plist, and
# an iOS-only sweep of *.swift calls all of those orphans.
SOURCE_SUFFIXES = (
    ".swift", ".m", ".mm", ".h",
    ".xib", ".storyboard", ".intentdefinition", ".plist", ".stringsdict",
)

SKIP_DIRS = {
    ".git", ".build", ".swiftpm", "DerivedData", "build", "Pods", "Carthage",
    "node_modules", "index-build", ".index-build",
}


def swift_sources(roots):
    seen = 0
    for root in roots:
        for directory, subdirs, files in os.walk(root):
            subdirs[:] = [d for d in subdirs if d not in SKIP_DIRS]
            for name in files:
                if name.endswith(SOURCE_SUFFIXES):
                    seen += 1
                    with open(
                        os.path.join(directory, name), encoding="utf-8", errors="replace"
                    ) as handle:
                        yield handle.read()
    if seen == 0:
        print(
            f"error: no source files under {' '.join(roots)} — every key would "
            "look orphaned",
            file=sys.stderr,
        )
        sys.exit(66)


def main(argv):
    argv = list(argv)
    delete_orphans = "--delete-orphans" in argv
    if delete_orphans:
        argv.remove("--delete-orphans")
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 64
    catalog_path, source_roots = argv[1], argv[2:]

    with open(catalog_path, encoding="utf-8") as handle:
        raw = handle.read()
    catalog = json.loads(raw)
    strings = catalog["strings"]

    sources = list(swift_sources(source_roots))

    def referenced(key):
        literal = '"' + key + '"'
        return any(literal in text for text in sources)

    kept, orphans, removed = [], [], []
    for key in list(strings):
        if strings[key].get("extractionState") != "stale":
            continue
        if referenced(key):
            strings[key]["extractionState"] = "manual"
            kept.append(key)
        elif delete_orphans:
            del strings[key]
            removed.append(key)
        else:
            # Found in none of the roots given — which may mean dead, or may
            # only mean the root that uses it was not passed. Keep it, and its
            # translations, and say so.
            strings[key]["extractionState"] = "manual"
            orphans.append(key)

    out = json.dumps(catalog, indent=2, separators=(",", " : "), ensure_ascii=False)
    if raw.endswith("\n"):
        out += "\n"
    with open(catalog_path, "w", encoding="utf-8") as handle:
        handle.write(out)

    for key in kept:
        print(f"manual   {key}")
    for key in orphans:
        print(f"orphan?  {key}")
    for key in removed:
        print(f"removed  {key}")
    print(
        f"{len(kept)} kept as manual, {len(orphans)} orphan candidates kept, "
        f"{len(removed)} removed, {len(strings)} entries left"
    )
    if orphans:
        print(
            f"\n{len(orphans)} key(s) appear in none of: {' '.join(source_roots)}\n"
            "Before deleting any of them, check that every target's sources were\n"
            "passed — a macOS-only or visionOS-only string looks exactly like this\n"
            "after an iOS build, and deleting it takes all of its translations with\n"
            "it. When the roots are complete, re-run with --delete-orphans.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
