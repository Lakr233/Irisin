#!/usr/bin/env bash
# What Irisin's Apple TV package must hold, read back from the .deb itself
# (Scripts/package-appletv-deb.sh makes it; Documentation/AppleTV.md).

set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: $0 <deb> <package-id> <version> <architecture> <minimum-tvos>" >&2
    exit 64
fi
deb="$1"
package_id="$2"
version="$3"
architecture="$4"
minimum_tvos="$5"

fail() {
    echo "error: $*" >&2
    exit 65
}
field() { dpkg-deb -f "$deb" "$1"; }

[[ -f "$deb" ]] || fail "no package at $deb"
[[ "$(field Package)" == "$package_id" ]] || fail "Package is not $package_id"
[[ "$(field Version)" == "$version" ]] || fail "Version is not $version"
[[ "$(field Architecture)" == "$architecture" ]] || fail "Architecture is not $architecture"
[[ "$(field Depends)" == "firmware (>= $minimum_tvos)" ]] || fail "Depends is not firmware (>= $minimum_tvos)"
LC_ALL=C field Description | grep -qi 'jailbreak' && fail "the description says jailbreak; it is custom firmware"

contents="$(dpkg-deb --contents "$deb" 2>/dev/null)"
expected=(./usr/libexec/irisind ./usr/libexec/irisin-install ./Library/LaunchDaemons/wiki.qaq.irisind.plist)
for path in "${expected[@]}"; do
    grep -qE "root/(root|wheel) .* $path\$" <<<"$contents" || fail "$path is missing or not root's"
done
# No app, no command line, no icli, nothing at a rootless prefix.
files="$(awk '$1 !~ /^d/ { print $NF }' <<<"$contents")"
[[ "$(wc -l <<<"$files" | tr -d ' ')" == "${#expected[@]}" ]] || fail "unexpected files: $(tr '\n' ' ' <<<"$files")"
grep -q '\./var/jb' <<<"$contents" && fail "a RootHide package holds a rootless path"

work="$(mktemp -d "${TMPDIR:-/tmp}/irisin-appletv-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$deb" "$work/root" 2>/dev/null
dpkg-deb -e "$deb" "$work/DEBIAN" 2>/dev/null
for script in postinst prerm; do
    [[ -x "$work/DEBIAN/$script" ]] || fail "$script is missing or not executable"
    grep -q '/var/jb' "$work/DEBIAN/$script" && fail "$script names a rootless path"
done
for binary in "$work/root/usr/libexec/irisind" "$work/root/usr/libexec/irisin-install"; do
    build="$(vtool -show-build "$binary")"
    [[ "$(awk '/platform/ { print $2; exit }' <<<"$build")" == TVOS ]] || fail "$(basename "$binary") is not tvOS's"
    [[ "$(awk '/minos/ { print $2; exit }' <<<"$build")" == "$minimum_tvos" ]] || fail "$(basename "$binary") is not built for tvOS $minimum_tvos"
    ldid -e "$binary" | grep -q '<key>platform-application</key>' || fail "$(basename "$binary") is not signed with its entitlements"
    nm -u "$binary" | grep -qx '_posix_spawn' || fail "$(basename "$binary") does not start processes through libSystem's posix_spawn"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$work/root/Library/LaunchDaemons/wiki.qaq.irisind.plist")" == /usr/libexec/irisind ]] \
    || fail "the launchd plist does not point at /usr/libexec/irisind"
# icli (and IOKit with it) is the helper's alone: the daemon links IrisinProtocol.
otool -L "$work/root/usr/libexec/irisind" | grep -q 'IOKit' && fail "irisind links icli; only the helper may"

echo "Verified Irisin (Apple TV): $deb"
