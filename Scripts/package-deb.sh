#!/usr/bin/env bash

set -Eeuo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd "$scripts/.." && pwd -P)"

if [[ "$#" -ne 15 ]]; then
    echo "usage: $0 <app> <daemon> <helper> <control> <app-entitlements> <daemon-entitlements> <launch-plist> <output-deb> <package-id> <version> <architecture> <flavor> <install-prefix> <minimum-ios> <helper-entitlements>" >&2
    exit 64
fi

app_bundle="$1"
daemon_binary="$2"
helper_binary="$3"
control_template="$4"
app_entitlements="$5"
daemon_entitlements="$6"
launch_plist="$7"
output_deb="$8"
package_id="$9"
version="${10}"
architecture="${11}"
flavor="${12}"
install_prefix="${13}"
minimum_ios="${14}"
helper_entitlements="${15}"

[[ -d "$app_bundle" && -f "$app_bundle/Info.plist" ]] || { echo "error: incomplete app bundle" >&2; exit 66; }
[[ -x "$daemon_binary" ]] || { echo "error: daemon binary is missing" >&2; exit 66; }
[[ -x "$helper_binary" ]] || { echo "error: helper binary is missing" >&2; exit 66; }
for input in "$control_template" "$app_entitlements" "$daemon_entitlements" "$helper_entitlements" "$launch_plist"; do
    [[ -f "$input" ]] || { echo "error: missing packaging input: $input" >&2; exit 66; }
done
[[ "$output_deb" == *.deb ]] || { echo "error: output must end in .deb" >&2; exit 64; }
[[ "$package_id" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || { echo "error: invalid package id" >&2; exit 64; }
[[ "$version" =~ ^[0-9A-Za-z.+:~_-]+$ ]] || { echo "error: invalid version" >&2; exit 64; }
[[ "$architecture" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || { echo "error: invalid architecture" >&2; exit 64; }
[[ "$minimum_ios" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "error: invalid minimum iOS version" >&2; exit 64; }
case "$flavor" in
    roothide) [[ -z "$install_prefix" ]] || { echo "error: roothide packages install at rootful paths" >&2; exit 64; } ;;
    rootless) [[ "$install_prefix" == /var/jb ]] || { echo "error: rootless packages install under /var/jb" >&2; exit 64; } ;;
    *) echo "error: flavor must be roothide or rootless" >&2; exit 64 ;;
esac

case "$architecture:$install_prefix" in
iphoneos-arm64:/var/jb | iphoneos-arm64e:) ;;
*) echo "error: architecture and install prefix name different bootstrap layouts" >&2; exit 64 ;;
esac

# The daemon and the helper make path decisions on physical paths; a vroot
# dependency would silently change that contract.
if otool -L "$daemon_binary" "$helper_binary" | grep -q 'libvroot'; then
    echo "error: native daemon uses physical paths; unexpected vroot dependency" >&2
    exit 65
fi

app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_bundle/Info.plist")"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Info.plist")"
[[ "$bundle_identifier" == wiki.qaq.irisin && "$app_executable" == irisin && -x "$app_bundle/$app_executable" ]] || {
    echo "error: unexpected app identity" >&2
    exit 65
}

# The package version comes from Configuration/Version.xcconfig, which is also
# what the app was built with; refuse to ship a .deb that disagrees.
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Info.plist")"
[[ "$app_version" == "$version" ]] || {
    echo "error: app version '$app_version' does not match package version '$version'" >&2
    exit 65
}

output_name="$(basename "$output_deb")"
mkdir -p "$(dirname "$output_deb")"
output_directory="$(cd "$(dirname "$output_deb")" && pwd -P)"
output_deb="$output_directory/$output_name"
staging="$(mktemp -d "${TMPDIR:-/tmp}/irisin-deb.XXXXXX")"
temporary_deb="$output_directory/.$output_name.tmp.$$"
app_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/irisin-app-entitlements.XXXXXX")"
daemon_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/irisin-daemon-entitlements.XXXXXX")"
helper_signed_entitlements="$(mktemp "${TMPDIR:-/tmp}/irisin-helper-entitlements.XXXXXX")"
trap 'rm -rf "$staging"; rm -f "$temporary_deb" "$app_signed_entitlements" "$daemon_signed_entitlements" "$helper_signed_entitlements"' EXIT
chmod 0755 "$staging"

debian="$staging/DEBIAN"
installed_app="$staging$install_prefix/Applications/irisin.app"
installed_daemon="$staging$install_prefix/usr/libexec/irisind"
installed_helper="$staging$install_prefix/usr/libexec/irisin-install"
installed_plist="$staging$install_prefix/Library/LaunchDaemons/wiki.qaq.irisind.plist"
mkdir -p "$debian" "$(dirname "$installed_app")" "$(dirname "$installed_daemon")" "$(dirname "$installed_plist")"
/usr/bin/ditto "$app_bundle" "$installed_app"
# CFBundleName is what the system's own sheets call the app (a vendor
# sign-in reads "\"Irisin\" Wants to Use…"); Xcode derives it from the product
# name, so the shipped bundle is told its name here.
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Irisin' "$installed_app/Info.plist"
# One binary is packaged once per flavor; the plist tells the app which
# bootstrap this copy is for (PackagedArchitecture.infoKey),
# and startup refuses a copy installed on a different bootstrap.
/usr/libexec/PlistBuddy -c "Add :IrisinCurrentArchitecture string $architecture" "$installed_app/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :IrisinCurrentArchitecture $architecture" "$installed_app/Info.plist"
# The build carries every flavor's recommended repositories
# (Irisin/Resources/Environments); this copy keeps its own and the empty
# managed list the jailbreak may fill (RecommendedRepositories).
[[ -f "$installed_app/default-list-$architecture.plist" && -f "$installed_app/default-list-managed.plist" ]] || {
    echo "error: app bundle is missing default-list-$architecture.plist or default-list-managed.plist" >&2
    exit 65
}
for list in "$installed_app"/default-list-*.plist; do
    case "$(basename "$list")" in
    "default-list-$architecture.plist" | default-list-managed.plist) ;;
    *) rm -f "$list" ;;
    esac
done
/usr/bin/ditto "$daemon_binary" "$installed_daemon"
/usr/bin/ditto "$helper_binary" "$installed_helper"
sed -e "s|@PREFIX@|$install_prefix|g" "$launch_plist" >"$installed_plist"
rm -rf "$installed_app/_CodeSignature"
rm -f "$installed_app/embedded.mobileprovision"
chmod 0755 "$installed_daemon" "$installed_helper"
chmod 0644 "$installed_plist"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$installed_plist")" == "$install_prefix/usr/libexec/irisind" ]] || {
    echo "error: launch daemon plist does not point at the installed daemon" >&2
    exit 65
}

for binary in "$installed_app/$app_executable" "$installed_daemon" "$installed_helper"; do
    /usr/bin/strip -xS "$binary"
    for private_path in "$repository_root" "${GITHUB_WORKSPACE:-}" "${RUNNER_TEMP:-}"; do
        [[ -z "$private_path" || "$private_path" == / ]] && continue
        if LC_ALL=C grep -aF "$private_path" "$binary" >/dev/null; then
            echo "error: $(basename "$binary") embeds a private build path" >&2
            exit 65
        fi
    done
done

bash "$scripts/sign-frameworks.sh" "$installed_app"
ldid -S"$app_entitlements" -Cadhoc "$installed_app/$app_executable"
# The helper is the daemon's child and runs as root, so it carries the
# daemon's freedom from the sandbox and platform status, and on top of them
# what icli needs to talk to LaunchServices and FrontBoard from inside it.
ldid -S"$daemon_entitlements" -Cadhoc "$installed_daemon"
ldid -S"$helper_entitlements" -Cadhoc "$installed_helper"
ldid -e "$installed_app/$app_executable" >"$app_signed_entitlements"
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

# The daemon admits a client only if the kernel says it carries these, so a
# build that lost one would ship an app the daemon silently refuses to serve.
for entitlement in platform-application com.apple.private.security.no-sandbox wiki.qaq.irisin.client; do
    require_true "$app_signed_entitlements" "$entitlement"
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.exception.mach-lookup.global-name:0' "$app_signed_entitlements")" == wiki.qaq.irisin.service ]] || {
    echo "error: app is missing the daemon mach lookup entitlement" >&2
    exit 65
}
for entitlement in platform-application com.apple.private.security.no-sandbox com.apple.private.security.storage.AppBundles com.apple.private.security.storage.AppDataContainers; do
    require_true "$daemon_signed_entitlements" "$entitlement"
    require_true "$helper_signed_entitlements" "$entitlement"
done
# Without these the helper installs packages and LaunchServices ignores it.
for entitlement in com.apple.private.coreservices.lsaw com.apple.lsapplicationworkspace.rebuildappdatabases com.apple.private.MobileContainerManager.allowed com.apple.frontboard.shutdown; do
    require_true "$helper_signed_entitlements" "$entitlement"
done
# IcliKit talks to launchd in-process; no launchctl executable is installed or
# required. Listing verifies the load/unload result in both visible domains.
for entitlement in com.apple.private.xpc.service-configure com.apple.private.xpc.launchd.per-user-lookup; do
    require_true "$helper_signed_entitlements" "$entitlement"
done

# DEBIAN is still empty at this point, so this measures only the payload.
installed_size="$(du -sk "$staging" | awk '{print $1}')"
sed \
    -e "s/@PACKAGE_ID@/$package_id/g" \
    -e "s/@VERSION@/$version/g" \
    -e "s/@ARCHITECTURE@/$architecture/g" \
    -e "s/@INSTALLED_SIZE@/$installed_size/g" \
    -e "s/@FLAVOR@/$flavor/g" \
    -e "s/@MINIMUM_IOS_VERSION@/$minimum_ios/g" \
    "$control_template" >"$debian/control"

for script in postinst prerm; do
    sed -e "s|@PREFIX@|$install_prefix|g" "$(dirname "$control_template")/$script" >"$debian/$script"
done
chmod 0644 "$debian/control"
chmod 0755 "$debian/postinst" "$debian/prerm"

dpkg-deb --root-owner-group -Zxz -b "$staging" "$temporary_deb"
[[ "$(dpkg-deb -f "$temporary_deb" Package)" == "$package_id" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Version)" == "$version" ]]
[[ "$(dpkg-deb -f "$temporary_deb" Architecture)" == "$architecture" ]]
contents="$(dpkg-deb --contents "$temporary_deb")"
grep -F ".$install_prefix/Applications/irisin.app/irisin" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/libexec/irisind" <<<"$contents" >/dev/null
grep -F ".$install_prefix/usr/libexec/irisin-install" <<<"$contents" >/dev/null
grep -F ".$install_prefix/Library/LaunchDaemons/wiki.qaq.irisind.plist" <<<"$contents" >/dev/null

mv -f "$temporary_deb" "$output_deb"
echo "Packaged Irisin ($flavor): $output_deb"
shasum -a 256 "$output_deb"
