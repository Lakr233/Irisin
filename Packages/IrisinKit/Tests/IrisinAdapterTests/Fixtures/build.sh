#!/bin/bash
# Rebuilds the Mach-O fixtures in this directory. Not part of any build: the
# results are committed, and this is how they were made.
#
#   input/     what a rootless package ships: built here from fixture.c, then
#              signed on a jailbroken device by `ldid -S`, as Theos does, or
#              here by `codesign`, as Xcode does.
#   expected/  the same files after the commands roothide's RootHidePatcher
#              (patch.sh, Compat Layer mode) runs on every Mach-O: the
#              device's install_name_tool for each /var/jb rpath and dylib,
#              then `ldid -Hsha256 -S`, or for what `file` calls an
#              executable `ldid -Hsha256 -M -S<roothide.entitlements>`. The
#              adapter's output is compared with these byte for byte,
#              signature included.
#
# usage: build.sh <ssh host of a rootless device with ldid, odcctools and file>
#        (mobile@host, key or sshpass authentication set up by the caller:
#        SSH="sshpass -p alpine ssh" SCP="sshpass -p alpine scp" build.sh host;
#        SSH="ssh -p 2333" SCP="scp -P 2333" build.sh 127.0.0.1 for a vphone)
set -euo pipefail
cd "$(dirname "$0")"
HOST=mobile@$1
SSH=${SSH:-ssh}
SCP=${SCP:-scp}
CC="xcrun --sdk iphoneos clang -miphoneos-version-min=15.0 -Os"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/input" "$WORK/signing"

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

# a program signed by ldid with no entitlements: roothide's are all it gets
$CC -arch arm64 -DFIXTURE_EXECUTABLE fixture.c "$WORK/libfixturedep.dylib" -o "$WORK/input/fixture-tool"

# an app's program as Theos leaves it: fat, signed by ldid with entitlements
# that exercise the merge (a key roothide sets, already there as false), the
# executable segment flags, every value an entitlement can hold, DER lengths
# past one byte, base64 lines at three depths, and an __info_plist section
# ldid hashes into the info slot
cat >"$WORK/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.example.fixture</string>
</dict>
</plist>
EOF
$CC -arch arm64 -arch arm64e -DFIXTURE_EXECUTABLE fixture.c \
    -Wl,-weak_library,"$WORK/libfixturedep.dylib" -Wl,-rpath,/var/jb/usr/lib \
    -Wl,-sectcreate,__TEXT,__info_plist,"$WORK/Info.plist" \
    -o "$WORK/input/FixtureApp"
LONG=$(printf 'x%.0s' {1..200})
BLOB=$(head -c 180 /dev/zero | tr '\0' 'r' | base64)
cat >"$WORK/signing/app.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>com.example.fixture &amp; &lt;app&gt; 'single' "double" 日本語</string>
	<key>platform-application</key>
	<false/>
	<key>get-task-allow</key>
	<true/>
	<key>com.apple.private.skip-library-validation</key>
	<true/>
	<key>dynamic-codesigning</key>
	<true/>
	<key>com.apple.private.amfi.can-execute-cdhash</key>
	<true/>
	<key>com.apple.private.cs.debugger</key>
	<false/>
	<key>com.apple.security.exception.files.absolute-path.read-write</key>
	<array>
		<string>/var/jb/</string>
		<string>/private/var/mobile/</string>
	</array>
	<key>keychain-access-groups</key>
	<array/>
	<key>com.example.nested</key>
	<dict>
		<key>level</key>
		<integer>300</integer>
		<key>blob</key>
		<data>$BLOB</data>
		<key>empty</key>
		<dict/>
		<key>deeper</key>
		<dict>
			<key>blob</key>
			<data>$BLOB</data>
		</dict>
	</dict>
	<key>com.example.blob</key>
	<data>$BLOB</data>
	<key>com.example.long</key>
	<string>$LONG</string>
</dict>
</plist>
EOF

# the same as Xcode leaves it: codesign keeps the entitlements file's own
# XML, which libplist and the adapter must both read as the same values
$CC -arch arm64 -DFIXTURE_EXECUTABLE fixture.c "$WORK/libfixturedep.dylib" -o "$WORK/input/FixtureCodesigned"
cat >"$WORK/apple.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- as a person writes it -->
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.example.fixture</string>
    </array>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>com.example.escaped</key>
    <string>&lt;escaped&gt; &amp; more</string>
</dict>
</plist>
EOF
codesign -f -s - --entitlements "$WORK/apple.entitlements" "$WORK/input/FixtureCodesigned"

# a program that was never signed: the merged entitlements are roothide's alone
$CC -arch arm64 -DFIXTURE_EXECUTABLE fixture.c "$WORK/libfixturedep.dylib" -Wl,-no_adhoc_codesign \
    -o "$WORK/input/FixtureUnsignedTool"

# fat with a program slice and a library slice, the library with an
# __info_plist: `file` calls the whole file an executable, so ldid merges
# roothide's entitlements into both slices, marks only the program's as the
# main binary, and hashes the library's info slot
$CC -arch arm64 -DFIXTURE_EXECUTABLE fixture.c "$WORK/libfixturedep.dylib" -o "$WORK/mixed-program"
$CC -arch arm64e fixture.c "$WORK/libfixturedep.dylib" -dynamiclib -install_name /var/jb/usr/lib/libfixturemixed.dylib \
    -Wl,-sectcreate,__TEXT,__info_plist,"$WORK/Info.plist" -o "$WORK/mixed-library"
lipo -create "$WORK/mixed-program" "$WORK/mixed-library" -output "$WORK/input/FixtureMixed"
cat >"$WORK/signing/mixed.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>get-task-allow</key>
	<true/>
	<key>com.apple.private.security.no-sandbox</key>
	<false/>
</dict>
</plist>
EOF

# roothide.entitlements as the patcher ships it
cat >"$WORK/signing/roothide.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>com.apple.private.security.storage.AppBundles</key>
    <true/>
    <key>com.apple.private.security.storage.AppDataContainers</key>
    <true/>
</dict>
</plist>
EOF

REMOTE=/var/mobile/irisin-adapter-fixtures
PATHS='export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH;'
$SSH "$HOST" "rm -rf $REMOTE; mkdir -p $REMOTE"
$SCP -r "$WORK/input" "$WORK/signing" "$HOST:$REMOTE/"
$SSH "$HOST" "$PATHS cd $REMOTE && for f in input/Fixture.dylib input/FixtureBundle input/fixture-tool; do ldid -S \$f; done &&
    ldid -Ssigning/app.entitlements input/FixtureApp && ldid -Ssigning/mixed.entitlements input/FixtureMixed &&
    cp -R input expected && cd expected && for f in *; do
    otool -l \$f | awk '\$1==\"cmd\"&&\$2==\"LC_RPATH\"{r=1} r&&\$1==\"path\"{print \$2; r=0}' | sort -u | while read -r p; do
        case \$p in /var/jb/*) install_name_tool -rpath \$p @loader_path/.jbroot/\${p#/var/jb/} \$f;; esac; done
    otool -L \$f | tail -n +2 | cut -d' ' -f1 | tr -d '[:blank:]' | while read -r p; do
        case \$p in /var/jb/*) install_name_tool -change \$p @loader_path/.jbroot/\${p#/var/jb/} \$f;; esac; done
    if file -b \$f | grep -q executable; then ldid -Hsha256 -M -S../signing/roothide.entitlements \$f; else ldid -Hsha256 -S \$f; fi; done"
rm -rf input expected
$SCP -r "$HOST:$REMOTE/input" "$HOST:$REMOTE/expected" .
$SSH "$HOST" "rm -rf $REMOTE"
ls -l input expected
