#!/usr/bin/env bash

# Writes the marketing version into Configuration/Version.xcconfig, the single
# source of truth consumed by the Xcode project, the Debian control file, and
# the packaged .deb file name. The build number is not stored: make derives
# it (git commit count, or BUILD_NUMBER=n) and passes it to xcodebuild.

set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <version>" >&2
    exit 64
fi

version="${1#v}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: version must look like 4.0.1 (got '$1')" >&2
    exit 64
}

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
version_config="$root_dir/Configuration/Version.xcconfig"
[[ -f "$version_config" ]] || { echo "error: missing $version_config" >&2; exit 66; }

updated="$(mktemp "${TMPDIR:-/tmp}/irisin-version.XXXXXX")"
trap 'rm -f "$updated"' EXIT

awk -v version="$version" '
    /^[[:space:]]*MARKETING_VERSION[[:space:]]*=/ { print "MARKETING_VERSION = " version; seen = 1; next }
    { print }
    END { if (!seen) { exit 1 } }
' "$version_config" >"$updated" || {
    echo "error: Version.xcconfig must define MARKETING_VERSION" >&2
    exit 65
}

/usr/bin/ditto "$updated" "$version_config"

echo "MARKETING_VERSION = $version"
