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
expected=(./usr/libexec/irisind ./usr/libexec/irisin-install ./Library/LaunchDaemons/wiki.qaq.irisind.plist ./Applications/irisin.app/irisin)
for path in "${expected[@]}"; do
    grep -qE "root/(root|wheel) .* $path\$" <<<"$contents" || fail "$path is missing or not root's"
done
# Beside the launchpad's bundle, the daemon, the helper and its plist and
# nothing else: no command line, no icli, nothing at a rootless prefix.
files="$(awk '$1 !~ /^d/ { print $NF }' <<<"$contents" | grep -v '^\./Applications/irisin\.app/')"
[[ "$(wc -l <<<"$files" | tr -d ' ')" == 3 ]] || fail "unexpected files: $(tr '\n' ' ' <<<"$files")"
grep -qE '/icli$' <<<"$contents" && fail "the package holds an icli"
grep -q '\./var/jb' <<<"$contents" && fail "a RootHide package holds a rootless path"

work="$(mktemp -d "${TMPDIR:-/tmp}/irisin-appletv-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
dpkg-deb -x "$deb" "$work/root" 2>/dev/null
dpkg-deb -e "$deb" "$work/DEBIAN" 2>/dev/null
for script in postinst prerm; do
    [[ -x "$work/DEBIAN/$script" ]] || fail "$script is missing or not executable"
    grep -q '/var/jb' "$work/DEBIAN/$script" && fail "$script names a rootless path"
done
app="$work/root/Applications/irisin.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")" == wiki.qaq.irisin ]] || fail "the launchpad is not wiki.qaq.irisin"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :IrisinCurrentArchitecture' "$app/Info.plist")" == "$architecture" ]] \
    || fail "the launchpad does not say it is for $architecture"
for page in index.html app.js app.css; do
    [[ -f "$app/WebUI/$page" ]] || fail "the launchpad has no WebUI/$page"
done
for list in "$app"/default-list-*.plist; do
    case "$(basename "$list")" in
    "default-list-$architecture.plist" | default-list-managed.plist) ;;
    *) fail "the launchpad carries another bootstrap's $(basename "$list")" ;;
    esac
done
build="$(vtool -show-build "$app/irisin")"
[[ "$(awk '/platform/ { print $2; exit }' <<<"$build")" == TVOS ]] || fail "the launchpad is not tvOS's"
[[ "$(awk '/minos/ { print $2; exit }' <<<"$build")" == "$minimum_tvos" ]] || fail "the launchpad is not built for tvOS $minimum_tvos"
ldid -e "$app/irisin" | grep -q '<key>wiki.qaq.irisin.client</key>' || fail "the launchpad is not signed as irisind's client"
ldid -e "$app/irisin" | grep -q 'keychain-access-groups' && fail "the launchpad carries keychain groups; the page signs in to no vendor"

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
