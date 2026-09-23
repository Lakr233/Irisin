#!/usr/bin/env bash
# Verify a packaged Irisin .deb: control fields, payload layout, and the
# install prefix baked into the LaunchDaemon plist and maintainer scripts.

set -Eeuo pipefail

if [[ "$#" -ne 5 ]]; then
    echo "usage: $0 <deb> <package-id> <version> <architecture> <install-prefix>" >&2
    exit 64
fi

deb="$1"
package_id="$2"
version="$3"
architecture="$4"
install_prefix="$5"

[[ -f "$deb" ]] || { echo "error: missing package: $deb" >&2; exit 66; }

expect() {
    local label="$1" actual="$2" wanted="$3"
    [[ "$actual" == "$wanted" ]] || {
        echo "error: $label is '$actual', expected '$wanted'" >&2
        exit 65
    }
}

expect "Package" "$(dpkg-deb -f "$deb" Package)" "$package_id"
expect "Version" "$(dpkg-deb -f "$deb" Version)" "$version"
expect "Architecture" "$(dpkg-deb -f "$deb" Architecture)" "$architecture"
depends="$(dpkg-deb -f "$deb" Depends)"
if grep -Eq '(^|,)[[:space:]]*launchctl([[:space:](,]|$)' <<<"$depends"; then
    echo "error: package still depends on launchctl" >&2
    exit 65
fi

contents="$(dpkg-deb --contents "$deb")"
for payload in \
    "/Applications/irisin.app/irisin" \
    "/Applications/irisin.app/Info.plist" \
    "/Applications/irisin.app/Licenses.json" \
    "/Applications/irisin.app/zh-Hans.lproj/Localizable.strings" \
    "/usr/libexec/irisind" \
    "/usr/libexec/irisin-install" \
    "/Library/LaunchDaemons/wiki.qaq.irisind.plist"
do
    grep -F ".$install_prefix$payload" <<<"$contents" >/dev/null || {
        echo "error: package is missing $install_prefix$payload" >&2
        exit 65
    }
done

# Nothing may ship outside the prefix: on rootless every path lives under
# /var/jb, and a stray rootful path would install onto the sealed system.
if [[ -n "$install_prefix" ]]; then
    allowed=("./")
    walked="./"
    while IFS= read -r component; do
        walked="$walked$component/"
        allowed+=("$walked")
    done < <(tr '/' '\n' <<<"${install_prefix#/}")
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ "$path" == ".$install_prefix/"* ]] && continue
        printf '%s\n' "${allowed[@]}" | grep -Fxq "$path" || {
            echo "error: package ships '$path' outside $install_prefix" >&2
            exit 65
        }
    done < <(sed -E 's/^[^ ]+[[:space:]]+[^ ]+[[:space:]]+[^ ]+[[:space:]]+[^ ]+[[:space:]]+[^ ]+[[:space:]]+//' <<<"$contents")
fi

payload_root="$(mktemp -d "${TMPDIR:-/tmp}/irisin-verify.XXXXXX")"
trap 'rm -rf "$payload_root"' EXIT
dpkg-deb -x "$deb" "$payload_root"
installed="$payload_root$install_prefix"
app_info_plist="$installed/Applications/irisin.app/Info.plist"
launch_daemon_plist="$installed/Library/LaunchDaemons/wiki.qaq.irisind.plist"
expect "LaunchDaemon program" \
    "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$launch_daemon_plist")" \
    "$install_prefix/usr/libexec/irisind"
expect "LaunchDaemon user" \
    "$(/usr/libexec/PlistBuddy -c 'Print :UserName' "$launch_daemon_plist")" \
    "root"
expect "App architecture key" \
    "$(/usr/libexec/PlistBuddy -c 'Print :IrisinCurrentArchitecture' "$app_info_plist" 2>/dev/null || true)" \
    "$architecture"
expect "Recommended repository lists" \
    "$(cd "$installed/Applications/irisin.app" && ls default-list-*.plist | sort | tr '\n' ' ')" \
    "$(printf '%s\n' "default-list-$architecture.plist" default-list-managed.plist | sort | tr '\n' ' ')"
expect "App icon" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$app_info_plist" 2>/dev/null || true)" \
    "AppIcon"

for binary in \
    "$installed/Applications/irisin.app/irisin" \
    "$installed/usr/libexec/irisind" \
    "$installed/usr/libexec/irisin-install"
do
    if otool -l "$binary" | grep -E 'sectname __llvm_(prf|cov)' >/dev/null; then
        echo "error: $(basename "$binary") contains LLVM coverage instrumentation; rebuild with code coverage disabled" >&2
        exit 65
    fi
    # Every binary must run on the floor the control file promises: nothing may
    # link a library that arrived after it, other than weakly.
    if otool -L "$binary" | grep -v ', weak)' | grep -q 'libswiftXPC'; then
        echo "error: $(basename "$binary") links libswiftXPC non-weakly; iOS 15 does not have it" >&2
        exit 65
    fi
done

postinst="$(dpkg-deb -I "$deb" postinst)"
prerm="$(dpkg-deb -I "$deb" prerm)"
for script in postinst prerm; do
    if grep -F '@PREFIX@' <<<"${!script}" >/dev/null; then
        echo "error: $script kept an unsubstituted install prefix" >&2
        exit 65
    fi
done

grep -F '{"bootstrapIrisinDaemon":{}}' <<<"$postinst" >/dev/null || {
    echo "error: postinst does not ask the helper to bootstrap Irisin's daemon" >&2
    exit 65
}
grep -F "$install_prefix/usr/libexec/irisin-install" <<<"$postinst" >/dev/null || {
    echo "error: postinst does not register the app through the helper" >&2
    exit 65
}
grep -F '{"bootoutIrisinDaemon":{}}' <<<"$prerm" >/dev/null || {
    echo "error: prerm does not ask the helper to boot out Irisin's daemon" >&2
    exit 65
}
for script in postinst prerm; do
    if grep -Eq '(^|[/[:space:]])launchctl([[:space:]]|$)' <<<"${!script}"; then
        echo "error: $script still invokes launchctl" >&2
        exit 65
    fi
done
if ! otool -l "$installed/usr/libexec/irisin-install" | grep -F 'sectname __launchctl' >/dev/null; then
    echo "error: irisin-install is missing IcliKit's launchctl client marker" >&2
    exit 65
fi
# icli is linked into the helper; a copy of it on disk is a second tool for
# the user to wonder about.
if grep -E '/icli$' <<<"$contents" >/dev/null; then
    echo "error: package ships a standalone icli" >&2
    exit 65
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app_info_plist" 2>/dev/null)" == Irisin ]] || {
    echo "error: the app bundle's CFBundleName is not Irisin" >&2
    exit 65
}

echo "Verified $(basename "$deb") ($architecture, prefix '${install_prefix:-/}')"
