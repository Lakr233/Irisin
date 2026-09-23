#!/usr/bin/env python3
"""Collects every license the app ships under into one Licenses.json.

Runs as the "Collect Licenses" build phase of the Irisin target, so the
list is scanned from what this build actually links on every build, never a
hand-kept copy that drifts (adapted from iGhostVT's and Fila's):

  1. the app itself — the repository's LICENSE, versioned from
     Configuration/Version.xcconfig;
  2. code copied into the app's own targets — a Swift file whose header
     comment names a license (FluentIcon.swift, from Microsoft's Fluent UI
     System Icons) ships that header;
  3. the local packages under Packages/ that carry a LICENSE, and the
     notices nested in them for what they vendor (Runestone carries
     Tree-sitter's and each grammar's);
  4. every package pinned in Package.resolved — its checkout under
     SourcePackages, and its binary artifacts beside it, are walked for
     LICENSE / COPYING / NOTICE files and whatever sits in a Licenses
     folder, at the root and nested (libsolv.xcframework carries the
     upstream BSD terms, the WCDB binaries their own). A checkout with no
     such file ships the copyright header of its sources instead
     (ktiays/With has only that).

A pin whose checkout is missing, or whose checkout has neither a license
file nor a copyright header, fails the build: the list would be incomplete
and nobody would notice. So does GPL-family text anywhere in the set.

Output: a JSON array of {name, version?, license, url, text}, read by
LicenseController in the app.
"""

import argparse
import json
import os
import re
import sys

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|NOTICE)([-_.].*)?$", re.IGNORECASE)
SKIPPED_DIRECTORIES = {
    ".git", ".build", ".swiftpm", "Tests", "Test", "Example", "Examples",
    "docs", "Documentation", "node_modules", "Script", "Scripts", "Patches",
}
# The app's own targets, scanned for code copied in from elsewhere.
APP_SOURCES = ("Irisin", "IrisinDaemon", "IrisinInstall")
# Pins that owe the user no notice: icli is our own code, and
# swift-argument-parser serves only icli's command-line target, which the
# helper does not link.
NOT_SHIPPED = {"icli", "swift-argument-parser"}
# Identifier heuristics, first match wins; a text that matches none is shown
# as "Other" and still shipped whole.
LICENSE_KINDS = [
    ("GPL", re.compile(r"GNU (Affero |Lesser |Library )?General Public License|www\.gnu\.org/licenses/(a|l)?gpl", re.IGNORECASE)),
    ("Apache-2.0", re.compile(r"Apache License,? Version 2\.0", re.IGNORECASE)),
    ("MPL-2.0", re.compile(r"Mozilla Public License,? (Version |v\.? ?)2\.0", re.IGNORECASE)),
    ("OFL-1.1", re.compile(r"SIL OPEN FONT LICENSE", re.IGNORECASE)),
    ("MIT", re.compile(r"MIT License|Permission is hereby granted, free of charge", re.IGNORECASE)),
    ("BSD", re.compile(r"Redistribution and use in source and binary forms", re.IGNORECASE)),
    ("ISC", re.compile(r"ISC License|Permission to use, copy, modify, and/or distribute", re.IGNORECASE)),
    ("Unlicense", re.compile(r"This is free and unencumbered software", re.IGNORECASE)),
    ("Zlib", re.compile(r"This software is provided 'as-is', without any express or implied warranty", re.IGNORECASE)),
]


def fail(message):
    # Xcode reads "error:" lines into the issue navigator.
    print(f"error: collect-licenses: {message}", file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().strip("\n") + "\n"


def license_kind(text):
    for kind, pattern in LICENSE_KINDS:
        if pattern.search(text):
            return kind
    return "Other"


def entry(name, version, url, text):
    kind = license_kind(text)
    if kind == "GPL":
        fail(f"{name} carries GPL-family license text; the app does not ship GPL code")
    item = {"name": name, "license": kind, "url": url, "text": text}
    if version:
        item["version"] = version
    return item


def xcconfig_setting(path, key):
    for line in read(path).splitlines():
        head, sep, value = line.partition("=")
        if sep and head.strip() == key:
            return value.split("//")[0].strip()
    fail(f"{key} is missing from {path}")


def header_comment(path):
    """The leading `//` block of a Swift file, markers stripped."""
    lines = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("//"):
                break
            lines.append(line[2:].strip())
    return "\n".join(lines).strip()


def swift_files(root):
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
        for filename in sorted(files):
            if filename.endswith(".swift"):
                yield os.path.join(directory, filename)


def app_entry(project):
    manifest = json.load(open(os.path.join(project, "manifest.json"), encoding="utf-8"))
    return entry(
        manifest["name"],
        xcconfig_setting(os.path.join(project, "Configuration", "Version.xcconfig"), "MARKETING_VERSION"),
        manifest.get("homepage", ""),
        read(os.path.join(project, "LICENSE")),
    )


def copied_entries(project, homepage):
    entries = []
    for target in APP_SOURCES:
        for path in swift_files(os.path.join(project, target)):
            header = header_comment(path)
            if re.search(r"\blicen[cs]ed?\b", header, re.IGNORECASE):
                url = f"{homepage}/blob/main/{os.path.relpath(path, project)}"
                entries.append(entry(os.path.splitext(os.path.basename(path))[0], None, url, header + "\n"))
    return entries


def local_entries(project, homepage):
    root = os.path.join(project, "Packages")
    entries = []
    for package in sorted(os.listdir(root)):
        directory = os.path.join(root, package)
        if not os.path.isfile(os.path.join(directory, "LICENSE")):
            continue
        url = f"{homepage}/tree/main/Packages/{package}"
        # a vendored package names what it vendors beside it:
        # Runestone/Sources/TreeSitter/LICENSE
        for path in license_files(directory):
            parent = os.path.dirname(path)
            name = package if parent == directory else os.path.basename(parent)
            entries.append(entry(name, None, url, read(path)))
    return entries


def license_files(root):
    found = []
    for directory, subdirectories, files in os.walk(root):
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
        in_licenses = os.path.basename(directory).lower() == "licenses"
        for filename in sorted(files):
            if filename.endswith(".template") or filename.startswith("."):
                continue
            if in_licenses or LICENSE_FILE.match(filename):
                found.append(os.path.join(directory, filename))
    # The root license first, nested notices after it, so a package reads
    # as itself and then what it vendors.
    found.sort(key=lambda path: (os.path.dirname(path) != root, path))
    return found


def source_copyright(checkout):
    for path in swift_files(os.path.join(checkout, "Sources")):
        header = header_comment(path)
        if re.search(r"copyright", header, re.IGNORECASE):
            return header + "\n"
    return None


def package_entries(project, source_packages):
    # Irisin.xcworkspace is what builds, and it keeps its own pins; the
    # project's are there only when someone opened the project by itself.
    resolved_path = os.path.join(project, "Irisin.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
    if not os.path.isfile(resolved_path):
        resolved_path = os.path.join(
            project, "Irisin.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved"
        )
    resolved = json.load(open(resolved_path, encoding="utf-8"))
    entries = []
    for pin in sorted(resolved["pins"], key=lambda pin: pin["identity"]):
        if pin["identity"] in NOT_SHIPPED:
            continue
        location = pin["location"]
        url = location[:-4] if location.endswith(".git") else location
        package = url.rstrip("/").rsplit("/", 1)[-1]
        state = pin.get("state", {})
        version = state.get("version") or state.get("revision")
        checkout = os.path.join(source_packages, "checkouts", package)
        if not os.path.isdir(checkout):
            fail(f"{package} is pinned in Package.resolved but has no checkout under {source_packages}")
        found = license_files(checkout)
        if not found:
            header = source_copyright(checkout)
            if header is None:
                fail(f"{package} has no LICENSE, COPYING, or NOTICE file and no copyright header in its checkout")
            entries.append(entry(package, version, url, header))
            continue
        artifacts = os.path.join(source_packages, "artifacts", pin["identity"])
        if os.path.isdir(artifacts):
            found += license_files(artifacts)
        # an artifact often repeats a notice its checkout already has
        seen = set()
        for path in found:
            text = read(path)
            if text in seen:
                continue
            seen.add(text)
            stem = os.path.splitext(os.path.basename(path))[0]
            suffix = re.sub(r"^(LICEN[CS]E|COPYING|NOTICE)[-_.]?", "", stem, flags=re.IGNORECASE)
            if os.path.dirname(path) == checkout:
                entries.append(entry(package, version, url, text))
            elif suffix:
                entries.append(entry(suffix, None, url, text))
            else:
                # a notice beside what it covers: TreeSitter/LICENSE,
                # WCDBSwift.xcframework/LICENSE
                name = os.path.splitext(os.path.basename(os.path.dirname(path)))[0]
                entries.append(entry(name, None, url, text))
    return entries


def find_source_packages(build_dir):
    """Xcode keeps SourcePackages beside Build/ in the derived data folder;
    BUILD_DIR is Build/Products for a build and a deeper archive path for an
    archive, so walk up until the sibling appears."""
    directory = os.path.abspath(build_dir)
    # Xcode nests BUILD_DIR at most this far below the derived-data root; past
    # it the walk would leave derived data and test the user's home and /.
    for _ in range(8):
        candidate = os.path.join(directory, "SourcePackages")
        if os.path.isdir(os.path.join(candidate, "checkouts")):
            return candidate
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    fail(f"no SourcePackages/checkouts above {build_dir}; resolve the packages first")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True, help="the repository root (SRCROOT)")
    parser.add_argument("--build-dir", required=True, help="Xcode's BUILD_DIR, used to find SourcePackages")
    parser.add_argument("--output", required=True, help="where to write Licenses.json")
    arguments = parser.parse_args()

    source_packages = find_source_packages(arguments.build_dir)
    app = app_entry(arguments.project)
    entries = [app]
    entries += copied_entries(arguments.project, app["url"])
    entries += local_entries(arguments.project, app["url"])
    entries += package_entries(arguments.project, source_packages)

    os.makedirs(os.path.dirname(arguments.output), exist_ok=True)
    with open(arguments.output, "w", encoding="utf-8") as f:
        json.dump(entries, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"collect-licenses: {len(entries)} licenses -> {arguments.output}")


if __name__ == "__main__":
    main()
