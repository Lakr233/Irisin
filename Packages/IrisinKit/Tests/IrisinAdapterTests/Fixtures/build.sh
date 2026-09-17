#!/bin/bash
# Rebuilds the Mach-O fixtures in this directory. Not part of any build: the
# results are committed, and this is how they were made.
#
#   input/     what a rootless package ships: built here from fixture.c, then
#              signed on a jailbroken device by `ldid -S`, as Theos does.
#   expected/  the same files after the commands roothide's RootHidePatcher
#              (patch.sh, Compat Layer mode) runs on every Mach-O: the
#              device's install_name_tool for each /var/jb rpath and dylib,
#              then `ldid -Hsha256 -S`. The adapter's output is compared with
#              these byte for byte, signature included.
#
# usage: build.sh <ssh host of a rootless device with ldid and odcctools>
#        (mobile@host, key or sshpass authentication set up by the caller:
#        SSH="sshpass -p alpine ssh" SCP="sshpass -p alpine scp" build.sh host)
set -euo pipefail
cd "$(dirname "$0")"
HOST=mobile@$1
SSH=${SSH:-ssh}
SCP=${SCP:-scp}
CC="xcrun --sdk iphoneos clang -miphoneos-version-min=15.0 -Os"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/input"

$CC -arch arm64 -arch arm64e -DFIXTURE_DEPENDENCY fixture.c \
    -dynamiclib -install_name /var/jb/usr/lib/libfixturedep.dylib -o "$WORK/libfixturedep.dylib"

# fat, a weak /var/jb dependency, and an rpath whose rewritten spelling is
# already there: the patcher leaves the duplicate, and so must the adapter
$CC -arch arm64 -arch arm64e fixture.c -dynamiclib \
    -install_name /var/jb/usr/lib/libfixture.dylib \
    -Wl,-weak_library,"$WORK/libfixturedep.dylib" \
    -Wl,-rpath,/var/jb/usr/lib -Wl,-rpath,@loader_path/.jbroot/usr/lib \
    -Wl,-rpath,/var/jb/Library/Frameworks \
    -o "$WORK/input/Fixture.dylib"

# thin, a strong dependency, no rpath
$CC -arch arm64 fixture.c -bundle "$WORK/libfixturedep.dylib" -o "$WORK/input/FixtureBundle"

# never signed, by the linker or by ldid: the patcher's ldid adds the load
# command, and names the file, not what a signature it replaces said
$CC -arch arm64 -DFIXTURE_DEPENDENCY fixture.c -dynamiclib -Wl,-no_adhoc_codesign \
    -install_name /var/jb/usr/lib/libfixtureunsigned.dylib -o "$WORK/input/FixtureUnsigned.dylib"

# what the simple-tweak rule refuses
$CC -arch arm64 -DFIXTURE_EXECUTABLE fixture.c "$WORK/libfixturedep.dylib" -o "$WORK/input/fixture-tool"

REMOTE=/var/mobile/irisin-adapter-fixtures
PATHS='export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH;'
$SSH "$HOST" "rm -rf $REMOTE; mkdir -p $REMOTE"
$SCP -r "$WORK/input" "$HOST:$REMOTE/"
$SSH "$HOST" "$PATHS cd $REMOTE && for f in input/Fixture.dylib input/FixtureBundle input/fixture-tool; do ldid -S \$f; done && cp -R input expected && cd expected && for f in Fixture.dylib FixtureBundle FixtureUnsigned.dylib; do
    otool -l \$f | awk '\$1==\"cmd\"&&\$2==\"LC_RPATH\"{r=1} r&&\$1==\"path\"{print \$2; r=0}' | sort -u | while read -r p; do
        case \$p in /var/jb/*) install_name_tool -rpath \$p @loader_path/.jbroot/\${p#/var/jb/} \$f;; esac; done
    otool -L \$f | tail -n +2 | cut -d' ' -f1 | tr -d '[:blank:]' | while read -r p; do
        case \$p in /var/jb/*) install_name_tool -change \$p @loader_path/.jbroot/\${p#/var/jb/} \$f;; esac; done
    ldid -Hsha256 -S \$f; done; rm fixture-tool"
rm -rf input expected
$SCP -r "$HOST:$REMOTE/input" "$HOST:$REMOTE/expected" .
$SSH "$HOST" "rm -rf $REMOTE"
ls -l input expected
