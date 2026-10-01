#!/usr/bin/env bash
# Prove that a built product can actually launch on the OS version it claims.
#
# A clean build against this year's SDK says nothing about an old deployment
# target: the linker believes the SDK's availability metadata, and where that
# metadata is wrong or absent the app dies in dyld before `main` on the old
# device, with no warning anywhere in the build.
#
# Usage: audit-ios-floor.sh <floor> <path> [<path> …]
#   <floor>  the oldest iOS you claim, e.g. 15.0
#   <path>   an .app bundle, a framework, or a Mach-O; bundles are walked
#
# Exit 0 when everything checks out, 65 when something cannot run on the floor.
# Findings are printed as `error:` (cannot launch) or `note:` (must be guarded
# in source; this script cannot see whether it is).

set -Eeuo pipefail

[[ $# -ge 2 ]] || { echo "usage: $0 <floor> <path> [<path> …]" >&2; exit 64; }

floor="$1"
shift
fail=0

# 15.0 -> 150000, for string-free comparison of two dotted versions.
version_key() {
    local IFS=.
    # shellcheck disable=SC2206
    local parts=($1 0 0)
    printf '%d' $(( ${parts[0]} * 10000 + ${parts[1]} * 100 + ${parts[2]} ))
}
floor_key="$(version_key "$floor")"

# Every Mach-O under a path: the payload and every embedded library of an
# .app / .appex / .framework, because each one is loaded by the same dyld.
# `file` is asked one path at a time on purpose — its aligned, multi-line
# output for a universal binary cannot be split back into paths.
binaries() {
    local path="$1" candidate
    while IFS= read -r -d '' candidate; do
        [[ "$(file -b "$candidate" 2>/dev/null)" == Mach-O* ]] && printf '%s\n' "$candidate"
    done < <(find "$path" -type f -print0 2>/dev/null)
}

# 1. Required libraries. Anything here that arrived after the floor is a launch
#    failure on the floor: dyld refuses to build the process.
#
#    The list is deliberately explicit rather than clever. Add a line when the
#    SDK adds an overlay; the point is that these have bitten a shipped build.
declare -a late_libraries=(
    "libswiftXPC.dylib:16.0"          # iOS 27 SDK overlay; killed a shipped 0.1.6 on iOS 15 (SKILL.md)
    "libswiftObservation.dylib:17.0"
    "libswiftSpatial.dylib:17.0"
    "libswiftSynchronization.dylib:18.0"
    "libswiftRealityKit.dylib:18.0"
)

check_libraries() {
    local binary="$1" line entry library minimum
    while IFS= read -r line; do
        [[ "$line" == *", weak)"* ]] && continue
        for entry in "${late_libraries[@]}"; do
            library="${entry%%:*}"
            minimum="${entry##*:}"
            if [[ "$line" == *"/$library"* ]] \
                && (( $(version_key "$minimum") > floor_key )); then
                echo "error: $binary requires $library (iOS $minimum) but claims iOS $floor" >&2
                fail=1
            fi
        done
    done < <(otool -L "$binary" | tail -n +2)
}

# 2. The binary's own build version. An embedded framework with a higher minos
#    than the app is refused by dyld on the old device.
check_minos() {
    local binary="$1" minos
    minos="$(vtool -show-build "$binary" 2>/dev/null | awk '/minos/ { print $2; exit }')" || return 0
    [[ -n "$minos" ]] || return 0
    (( $(version_key "$minos") > floor_key )) || return 0
    # An app extension is allowed a higher floor of its own: an OS that predates
    # it simply never loads it, and the app still launches. Anything the app
    # itself loads is not allowed one.
    if [[ "$binary" == *.appex/* ]]; then
        echo "note: $binary is an extension built for iOS $minos; it will not load below that" >&2
        return 0
    fi
    echo "error: $binary is built for iOS $minos, above the claimed floor $floor" >&2
    fail=1
}

# 3. Weak symbols are null on an OS older than the one that introduced them.
#    Each has to be null-checked in source; this only says which they are.
check_weak_symbols() {
    local binary="$1" symbols
    symbols="$(nm -m "$binary" 2>/dev/null | grep 'weak external' | grep -v 'FORCE_LOAD' || true)"
    if [[ -n "$symbols" ]]; then
        echo "note: $binary weak-imports symbols that are NULL below their own floor:" >&2
        echo "$symbols" | sed 's/^/    /' >&2
    fi
}

# 4. Swift runtime symbols imported non-weakly. The library is on the floor but
#    the symbol is not, and dyld refuses the process just the same:
#
#      "Symbol not found: _swift_initBorrow"
#      "Expected in: /usr/lib/swift/libswiftCore.dylib"
#
#    Nothing in the build says so: the compiler can reference a runtime entry
#    point newer than the deployment target from code that never names it.
#    Two checks. The list below always runs; add a line with the symbol and the
#    iOS that first exports it. The comparison after it runs where an iOS
#    simulator runtime at or above the floor is installed with its libraries
#    as files (18.x is; 26 and later keep them only in a shared cache): every
#    symbol imported from /usr/lib/swift must be one that runtime exports, and
#    the Swift ABI only ever adds, so what that runtime lacks the floor lacks.
declare -a late_runtime_symbols=(
    "_swift_initBorrow:27.0"          # Swift 6.4 can import it strongly from code that never names it
)

# The oldest iOS simulator runtime at or above the floor whose Swift libraries
# are files: "<version> <RuntimeRoot>", or nothing. AUDIT_RUNTIME_ROOT and
# AUDIT_RUNTIME_VERSION name one by hand.
baseline_runtime() {
    if [[ -n "${AUDIT_RUNTIME_ROOT:-}" ]]; then
        printf '%s %s\n' "${AUDIT_RUNTIME_VERSION:?set it to the iOS version of AUDIT_RUNTIME_ROOT}" "$AUDIT_RUNTIME_ROOT"
        return 0
    fi
    xcrun simctl runtime list -j 2>/dev/null | python3 -c '
import json, os, sys
key = lambda v: tuple(int(p) for p in v.split("."))
floor = key(sys.argv[1])
found = []
for runtime in json.load(sys.stdin).values():
    if not runtime.get("platformIdentifier", "").endswith("iphonesimulator"):
        continue
    root = os.path.join(runtime.get("runtimeBundlePath", ""), "Contents/Resources/RuntimeRoot")
    if key(runtime["version"]) >= floor and os.path.isfile(os.path.join(root, "usr/lib/swift/libswiftCore.dylib")):
        found.append((key(runtime["version"]), runtime["version"], root))
if found:
    print(*min(found)[1:])
' "$floor" 2>/dev/null || true
}

runtime_line="$(baseline_runtime)"
runtime_version="${runtime_line%% *}"
runtime_root="${runtime_line#* }"
export_cache="$(mktemp -d)"
trap 'rm -rf "$export_cache"' EXIT

check_runtime_symbols() {
    local binary="$1" imports entry symbol minimum library exports
    # `(undefined) external`, not `(undefined) weak external`: a weak import is
    # the third check's business.
    imports="$(nm -m "$binary" 2>/dev/null \
        | awk '$1 == "(undefined)" && $2 == "external" && $4 == "(from" { sub(/\)$/, "", $5); print $5, $3 }' \
        | sort -u)"
    [[ -n "$imports" ]] || return 0

    for entry in "${late_runtime_symbols[@]}"; do
        symbol="${entry%%:*}"
        minimum="${entry##*:}"
        if grep -q " ${symbol}\$" <<<"$imports" \
            && (( $(version_key "$minimum") > floor_key )); then
            echo "error: $binary imports $symbol (iOS $minimum) non-weakly but claims iOS $floor" >&2
            fail=1
        fi
    done

    [[ -n "$runtime_line" ]] || return 0
    while IFS= read -r library; do
        [[ -f "$runtime_root/usr/lib/swift/$library.dylib" ]] || continue
        exports="$export_cache/$library"
        if [[ ! -f "$exports" ]]; then
            # An overlay (libswiftUIKit, libswiftDarwin, …) re-exports its
            # framework, and what it re-exports is not in its own symbol table.
            # Only a library that re-exports nothing can be read this way; the
            # runtime itself (libswiftCore, libswift_Concurrency, …) is one.
            if otool -l "$runtime_root/usr/lib/swift/$library.dylib" | grep -q LC_REEXPORT_DYLIB; then
                : >"$exports.skip"
            fi
            nm -gU "$runtime_root/usr/lib/swift/$library.dylib" 2>/dev/null | awk '{ print $NF }' | sort -u >"$exports"
        fi
        [[ ! -f "$exports.skip" ]] || continue
        while IFS= read -r symbol; do
            echo "error: $binary imports $symbol from $library non-weakly; iOS $runtime_version does not export it" >&2
            fail=1
        done < <(awk -v library="$library" '$1 == library { print $2 }' <<<"$imports" | comm -23 - "$exports")
    done < <(otool -L "$binary" | awk '$1 ~ /^\/usr\/lib\/swift\/libswift.*\.dylib$/ { n = split($1, p, "/"); sub(/\.dylib$/, "", p[n]); print p[n] }' | sort -u)
}

if [[ -z "$runtime_line" ]]; then
    echo "note: no iOS simulator runtime at or above $floor with its Swift libraries as files; only the listed runtime symbols are checked" >&2
fi

for path in "$@"; do
    [[ -e "$path" ]] || { echo "error: no such path: $path" >&2; exit 66; }
    binary_count=0
    while IFS= read -r binary; do
        [[ -n "$binary" ]] || continue
        binary_count=$((binary_count + 1))
        check_libraries "$binary"
        check_minos "$binary"
        check_weak_symbols "$binary"
        check_runtime_symbols "$binary"
    done < <(binaries "$path")
    if (( binary_count == 0 )); then
        echo "error: no Mach-O binaries found in: $path" >&2
        fail=1
    fi
done

# 5. SF Symbols. Not a link error and not a crash: `UIImage(systemName:)`
#    returns nil and the control draws nothing. Source-level, so it runs only
#    when a source root is given as the last argument's sibling — call
#    check-symbol-availability from `make check` instead; see SKILL.md.

if (( fail )); then
    echo "error: this product cannot launch on iOS $floor" >&2
    exit 65
fi

echo "ok: every required library, runtime symbol, build version and framework fits iOS $floor"
