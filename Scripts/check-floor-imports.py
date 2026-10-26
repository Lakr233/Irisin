#!/usr/bin/env python3
"""Fail on a strong import the iOS floor may not export.

The linker resolves every symbol against this year's SDK, whose .tbd files
export what later systems added, and dyld refuses the process at launch when
a strong import is missing from the running OS. Nothing in the build says so:
icli's `xpc_user_sessions_get_foreground_uid` (iOS 16) stopped Xrash on iOS
15.8.6 that way, from a binary that had built clean since 0.2.0.

An API an SDK header declares is covered by the compiler: built for the
floor, anything newer is weak-linked from its availability. What no header
declares has no availability (a private symbol, a runtime entry point the
compiler emits by name), so each one must be listed in the allowlist once it
is known to be exported by the floor, or resolved with dlsym. Mangled Swift
and C++ symbols are left to the compiler, which weak-links them from the
availability their headers carry (libc++'s included).
Class references are checked by the class name a header spells, and a
header's comments declare nothing: `proc_pidinfo` is spelled in one and
declared in none.

A library or framework iOS 16 or later introduced, loaded strongly, stops the
process in dyld the same way; the list below names the ones that could reach
an app like this one (an import of theirs is a mangled Swift symbol, which
the symbol check leaves alone).

icli's scripts/verify-binary.py is where this came from.

Usage: check-floor-imports.py [--sdk <sdk>] [--floor <version>] [--headers <dir>]...
                              [--allow <allowlist>]... <allowlist> <path> [<path> ...]
       <path> is a Mach-O or a bundle, which is walked. --sdk is iphoneos
       unless given (appletvos for the Apple TV build), --floor 15.0; a
       --headers directory is read as the SDK's own is: the IOKit stub the
       tvOS helper links against, whose headers the AppleTVOS SDK lacks.
       Apple TV's floor is newer than iOS's, so the allowlist's iOS 15.0
       symbols are exported there too; --allow names a further list, such
       as what a tvOS 17 target adds (floor-imports-appletv.txt).
"""

import os
import re
import subprocess
import sys
from pathlib import Path


# Loaded strongly, each of these is a launch failure below the version it
# names, which iOS and tvOS share.
LATE_LIBRARIES = {
    "/usr/lib/swift/libswift_StringProcessing.dylib": "16.0",
    "/usr/lib/swift/libswift_RegexParser.dylib": "16.0",
    "/usr/lib/swift/libswiftRegexBuilder.dylib": "16.0",
    "/usr/lib/swift/libswiftDistributed.dylib": "16.0",
    "/usr/lib/swift/libswiftXPC.dylib": "16.0",
    "/usr/lib/swift/libswiftObservation.dylib": "17.0",
    "/usr/lib/swift/libswiftSynchronization.dylib": "18.0",
    "/System/Library/Frameworks/AppIntents.framework/AppIntents": "16.0",
    "/System/Library/Frameworks/Charts.framework/Charts": "16.0",
    "/System/Library/Frameworks/SharedWithYou.framework/SharedWithYou": "16.0",
    "/System/Library/Frameworks/ActivityKit.framework/ActivityKit": "16.1",
    "/System/Library/Frameworks/SwiftData.framework/SwiftData": "17.0",
    "/System/Library/Frameworks/TipKit.framework/TipKit": "17.0",
    "/System/Library/Frameworks/Translation.framework/Translation": "17.4",
}
COMMENTS = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)


def version_key(version: str) -> tuple:
    return tuple(int(part) for part in (version.split(".") + ["0", "0"])[:3])


def sdk_declared_names(sdk_name: str, extra: list) -> set:
    sdk = Path(subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip())
    names = set()
    # os.walk, not rglob: several frameworks in the SDK are symlinks, and
    # rglob does not follow a symlinked directory (SafariServices is one)
    for folder in [sdk / "usr/include", sdk / "System/Library/Frameworks"] + extra:
        for directory, _, files in os.walk(folder, followlinks=True):
            for file in files:
                if file.endswith(".h"):
                    text = COMMENTS.sub(" ", (Path(directory) / file).read_text(errors="ignore"))
                    names.update(re.findall(r"[A-Za-z_$][A-Za-z0-9_$]*", text))
    return names


def allowlist(path: Path) -> set:
    allowed = set()
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            allowed.add(line)
    return allowed


def binaries(path: Path):
    candidates = [path] if path.is_file() else sorted(p for p in path.rglob("*") if p.is_file() and not p.is_symlink())
    for candidate in candidates:
        with candidate.open("rb") as handle:
            magic = handle.read(4)
        if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            yield candidate


def strong_imports(binary: Path) -> set:
    output = subprocess.check_output(["nm", "-m", "-u", str(binary)], text=True, stderr=subprocess.DEVNULL)
    names = set()
    for line in output.splitlines():
        if "(undefined)" not in line or " weak " in line:
            continue
        symbol = line.split()[2]
        name = symbol[1:] if symbol.startswith("_") else symbol
        name = re.sub(r"^OBJC_(?:META)?CLASS_\$_", "", name)
        if name.startswith(("$s", "_Tt", "_Z")):
            continue
        names.add(name)
    return names


def late_libraries(binary: Path, floor: str) -> list:
    output = subprocess.check_output(["otool", "-L", str(binary)], text=True, stderr=subprocess.DEVNULL)
    late = []
    for line in output.splitlines()[1:]:
        library = line.strip().split(" (", 1)[0]
        introduced = LATE_LIBRARIES.get(library)
        if introduced and version_key(introduced) > version_key(floor) and ", weak)" not in line:
            late.append(f"{library} ({introduced})")
    return late


def main() -> int:
    arguments = sys.argv[1:]
    sdk_name, floor, extra, further = "iphoneos", "15.0", [], []
    while arguments and arguments[0].startswith("--"):
        if len(arguments) < 2 or arguments[0] not in ("--sdk", "--floor", "--headers", "--allow"):
            raise SystemExit(__doc__)
        option, value = arguments[0], arguments[1]
        arguments = arguments[2:]
        if option == "--sdk":
            sdk_name = value
        elif option == "--floor":
            floor = value
        elif option == "--allow":
            further.append(Path(value))
        else:
            extra.append(Path(value))
    if len(arguments) < 2:
        raise SystemExit(__doc__)
    allowlist_path = arguments[0]
    allowed = allowlist(Path(allowlist_path))
    for path in further:
        allowed |= allowlist(path)
    declared = sdk_declared_names(sdk_name, extra)
    failures = 0
    for argument in arguments[1:]:
        path = Path(argument)
        if not path.exists():
            print(f"error: no such path: {path}", file=sys.stderr)
            return 66
        found = False
        for binary in binaries(path):
            found = True
            unknown = sorted(name for name in strong_imports(binary) if name not in declared and name not in allowed)
            for name in unknown:
                print(f"error: {binary} imports {name} strongly; no SDK header declares it and the allowlist does not list it", file=sys.stderr)
            failures += len(unknown)
            for library in late_libraries(binary, floor):
                print(f"error: {binary} loads {library} strongly", file=sys.stderr)
                failures += 1
        if not found:
            print(f"error: no Mach-O under {path}", file=sys.stderr)
            return 66
    if failures:
        print(
            f"error: {failures} strong import(s) the floor may not have. Confirm the floor exports each symbol "
            f"and list it in {allowlist_path}, or resolve it with dlsym; weak-link a late library",
            file=sys.stderr,
        )
        return 65
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
