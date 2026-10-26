#!/usr/bin/env bash
# Irisin's Apple TV package: irisind, irisin-install and the daemon's launchd
# plist, for RootHide (Documentation/AppleTV.md). No app yet. The iOS
# package is Scripts/package-deb.sh.

set -Eeuo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd "$scripts/.." && pwd -P)"

if [[ "$#" -ne 11 ]]; then
    echo "usage: $0 <daemon> <helper> <launch-plist> <packaging-dir> <daemon-entitlements> <helper-entitlements> <output-deb> <package-id> <version> <architecture> <minimum-tvos>" >&2
    exit 64
fi

daemon_binary="$1"
helper_binary="$2"
launch_plist="$3"
packaging="$4"
daemon_entitlements="$5"
helper_entitlements="$6"
output_deb="$7"
package_id="$8"
version="$9"
architecture="${10}"
minimum_tvos="${11}"

[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
[[ -x "$helper_binary" ]] || { echo "error: helper binary is missing" >&2; exit 66; }
for input in "$launch_plist" "$packaging/control" "$packaging/postinst" "$packaging/prerm" "$daemon_entitlements" "$helper_entitlements"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
[[ "$minimum_tvos" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "error: invalid minimum tvOS version" >&2; exit 64; }
# Each binary is tvOS's, at the floor the package claims.
for binary in "$daemon_binary" "$helper_binary"; do
    build="$(vtool -show-build "$binary")"
    [[ "$(awk '/platform/ { print $2; exit }' <<<"$build")" == TVOS ]] || {
        echo "error: $(basename "$binary") is not built for tvOS" >&2
        exit 65
    }
    [[ "$(awk '/minos/ { print $2; exit }' <<<"$build")" == "$minimum_tvos" ]] || {
        echo "error: $(basename "$binary") is not built for tvOS $minimum_tvos" >&2
        exit 65
    }
done
# The daemon and the helper make path decisions on physical paths; a vroot
# dependency would silently change that contract.
if otool -L "$daemon_binary" "$helper_binary" | grep -q 'libvroot'; then
    echo "error: native daemon uses physical paths; unexpected vroot dependency" >&2
    exit 65
fi

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/irisin-appletv-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
daemon_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/irisin-daemon-entitlements.XXXXXX")"
helper_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/irisin-helper-entitlements.XXXXXX")"
trap 'rm -rf "$staging"; rm -f "$temporary_deb" "$daemon_signed_entitlements" "$helper_signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_daemon="$staging/usr/libexec/irisind"
installed_helper="$staging/usr/libexec/irisin-install"
installed_plist="$staging/Library/LaunchDaemons/wiki.qaq.irisind.plist"
mkdir -p "$debian" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
/usr/bin/ditto "$helper_binary" "$installed_helper"
# RootHide: files at rootful paths, which its dpkg relocates.
sed -e "s|@PREFIX@||g" "$launch_plist" >"$installed_plist"
chmod 0755 "$installed_daemon" "$installed_helper"
chmod 0644 "$installed_plist"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == /usr/libexec/irisind ]] || {
    echo "error: launch daemon plist does not point at the installed daemon" >&2
    exit 65
}

for binary in "$installed_daemon" "$installed_helper"; do
    /usr/bin/strip -xS "$binary"
    for private_path in "$repository_root" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}"; do
        [[ -z "$private_path" || "$private_path" == / ]] && continue
        if LC_ALL=C grep -aF "$private_path" "$binary" >/dev/null; then
            echo "error: $(basename "$binary") embeds a private build path" >&2
            exit 65
        fi
    done
done

ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
ldid -S"$helper_entitlements" -Cadhoc "$installed_helper"
ldid -e "$installed_daemon" >"$daemon_signed_entitlements"
ldid -e "$installed_helper" >"$helper_signed_entitlements"

require_true() {
    local plist="$1"
    local key="$2"
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" == true ]] || {
        echo "error: signed executable is missing entitlement: $key" >&2
        exit 65
    }
}
for entitlement in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers; do
    require_true "$daemon_signed_entitlements" "$entitlement"
    require_true "$helper_signed_entitlements" "$entitlement"
done
for entitlement in com.apple.private.coreservices.lsaw com.apple.lsapplicationworkspace.rebuildappdatabases com.apple.frontboard.shutdown com.apple.private.xpc.service-configure com.apple.private.xpc.launchd.per-user-lookup; do
    require_true "$helper_signed_entitlements" "$entitlement"
done

# DEBIAN is still empty at this point, so this measures only the payload.
installed_size="$(du -sk "$staging" | awk '{print $1}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@MINIMUM_TVOS_VERSION@/$minimum_tvos/g" \
    "$packaging/control" >"$debian/control"
cp "$packaging/postinst" "$packaging/prerm" "$debian/"
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm"

dpkg-deb --root-owner-group -Zxz -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]

mv -f "$temporary_deb" "$output_deb"
echo "Packaged Irisin (Apple TV, RootHide): $output_deb"
shasum -a 256 "$output_deb"
