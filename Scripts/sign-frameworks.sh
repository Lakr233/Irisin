#!/usr/bin/env bash
# Ad-hoc sign every library embedded in irisin.app/Frameworks.
#
# An unsigned Xcode build leaves two kinds of library there: the linked
# frameworks, which the linker already ad-hoc signed, and the Swift
# compatibility dylibs the toolchain copies in for OS versions older than the
# SDK, which still carry Apple's own signature. A jailbroken iOS 18 refuses
# that signature at a path outside the system ("code signature invalid") and
# dyld halts the app at launch, while a newer iOS never loads the library, so
# the crash shows only on the older device. Signing all of them the way the
# app itself is signed puts every library on one footing, and the read-back
# below fails the build if one did not take.
set -Eeuo pipefail
[[ $# == 1 ]] || { echo 'usage: sign-frameworks.sh <irisin.app>' >&2; exit 64; }
frameworks="$1/Frameworks"
[[ -d "$frameworks" ]] || exit 0

libraries=()
for library in "$frameworks"/*.dylib; do
    [[ -f "$library" ]] && libraries+=("$library")
done
for framework in "$frameworks"/*.framework; do
    [[ -d "$framework" ]] || continue
    name="$(basename "$framework" .framework)"
    [[ -f "$framework/$name" ]] && libraries+=("$framework/$name")
done

for library in "${libraries[@]}"; do
    ldid -S -Cadhoc "$library"
    description="$(/usr/bin/codesign --display --verbose=2 "$library" 2>&1)"
    grep -q '^Signature=adhoc$' <<<"$description" || {
        echo "error: $library is not ad-hoc signed after signing" >&2
        exit 65
    }
done
echo "Signed ${#libraries[@]} embedded libraries in $(basename "$1")"
