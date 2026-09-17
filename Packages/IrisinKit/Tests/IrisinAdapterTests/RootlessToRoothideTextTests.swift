@testable import IrisinAdapter
import XCTest

/// The expected texts are what the sed lines of roothide's `patch.sh`, run
/// by GNU sed 4.9 on a device, made of the same inputs.
final class RootlessToRoothideTextTests: XCTestCase {
    func testMaintainerScript() {
        let script = """
        #! /bin/sh
        set -e
        if [ "$1" = configure ] && [ -d /var/jb/Library/Fixture ]; then
            chown -R mobile /var/jb/Library/Fixture "/var/jb"
            cp /Library/Fonts/x.ttf /var/jb/usr/share/ && ls /usr/lib /var/mobile/ /private/var/ /etc/hosts
            DIR="/Library/PreferenceLoader"; echo iphoneos-arm64 >/dev/null
            /var/jb/usr/bin/uicache -p /var/jb/Applications/Fixture.app; PATH=/usr/bin:/bin
        fi
        exit 0

        """
        let expected = """
        #! /bin/sh
        set -e
        if [ "$1" = configure ] && [ -d /Library/Fixture ]; then
            chown -R mobile /Library/Fixture "/var/jb"
            cp /rootfs/Library/Fonts/x.ttf /usr/share/ && ls /rootfs/usr/lib /rootfs/var/mobile/ /rootfs/private/var/ /rootfs/etc/hosts
            DIR="/rootfs/Library/PreferenceLoader"; echo iphoneos-arm64e >/dev/null
            /usr/bin/uicache -p /Applications/Fixture.app; PATH=/usr/bin:/bin
        fi
        exit 0

        """
        XCTAssertEqual(String(decoding: RootlessToRoothide.maintainerScript(Data(script.utf8)), as: UTF8.self), expected)
    }

    /// A shebang with no space is never touched, and neither is the missing
    /// newline at the end.
    func testMaintainerScriptWithTheBootstrapsInterpreter() {
        let script = Data("#!/var/jb/bin/sh\n/bin/ls /System/Library".utf8)
        XCTAssertEqual(
            String(decoding: RootlessToRoothide.maintainerScript(script), as: UTF8.self),
            "#!/bin/sh\n/bin/ls /rootfs/System/Library"
        )
    }

    func testBytesThatAreNotTextSurvive() {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x80]) + Data(" /usr/bin\n".utf8) + Data([0xC3, 0x28])
        XCTAssertEqual(
            RootlessToRoothide.maintainerScript(bytes),
            Data([0xFF, 0xFE, 0x00, 0x80]) + Data(" /rootfs/usr/bin\n".utf8) + Data([0xC3, 0x28])
        )
    }

    func testControlWithPreDepends() {
        let control = """
        Package: com.example.fixture
        Architecture: iphoneos-arm64

        Conflicts: com.example.roothide, roothide-thing
        Depends: mobilesubstrate, roothide
        Pre-Depends: firmware (>= 15.0)
        Description: built for iphoneos-arm64

        """
        XCTAssertEqual(RootlessToRoothide.control(control, preDepends: "rootless-compat(>= 0.9)"), """
        Package: com.example.fixture
        Architecture: iphoneos-arm64e
        Conflicts: com.example.r-o-o-t-l-e-s-s-, r-o-o-t-l-e-s-s--thing
        Depends: mobilesubstrate, roothide
        Pre-Depends: rootless-compat(>= 0.9), firmware (>= 15.0)
        Description: built for iphoneos-arm64e

        """)
    }

    /// The one place the patcher is not followed: it appends the field with
    /// `echo >>`, onto the last line of a control file that does not end in
    /// a newline ("Version: 1.0Pre-Depends: ..."), and the package it builds
    /// from that has lost both fields.
    func testControlWithoutPreDependsOrAFinalNewline() {
        XCTAssertEqual(
            RootlessToRoothide.control("Package: com.example.fixture\nArchitecture: iphoneos-arm64\nVersion: 1.0", preDepends: "rootless-compat(>= 0.9)"),
            "Package: com.example.fixture\nArchitecture: iphoneos-arm64e\nVersion: 1.0\nPre-Depends: rootless-compat(>= 0.9)\n"
        )
    }
}
