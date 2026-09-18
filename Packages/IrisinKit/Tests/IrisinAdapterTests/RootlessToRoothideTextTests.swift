@testable import IrisinAdapter
import XCTest

/// The expected texts are what the sed lines of roothide's `patch.sh`, run
/// by GNU sed 4.9 on a device, made of the same inputs.
final class RootlessToRoothideTextTests: XCTestCase {
    func testMaintainerScript() throws {
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
        XCTAssertEqual(String(decoding: try RootlessToRoothide.maintainerScript(Data(script.utf8)), as: UTF8.self), expected)
    }

    /// A shebang with no space is never touched, and neither is the missing
    /// newline at the end.
    func testMaintainerScriptWithTheBootstrapsInterpreter() throws {
        let script = Data("#!/var/jb/bin/sh\n/bin/ls /System/Library".utf8)
        XCTAssertEqual(
            String(decoding: try RootlessToRoothide.maintainerScript(script), as: UTF8.self),
            "#!/bin/sh\n/bin/ls /rootfs/System/Library"
        )
    }

    /// sed's `\s` takes in every ASCII space after `#!`, and a space the
    /// locale might call one is refused.
    func testShebangSpaces() throws {
        for space in ["\t", "\u{B}", "\u{C}", "\r", "  "] {
            XCTAssertEqual(
                String(decoding: try RootlessToRoothide.maintainerScript(Data("#!\(space) /bin/sh\n".utf8)), as: UTF8.self),
                "#! /bin/sh\n", space.debugDescription
            )
        }
        for space in ["\u{A0}", "\u{3000}"] {
            XCTAssertThrowsError(try RootlessToRoothide.maintainerScript(Data("#!\(space) /bin/sh\n".utf8)), space.debugDescription)
        }
        XCTAssertEqual(try RootlessToRoothide.maintainerScript(Data("#!\u{A0}x /bin/sh\n".utf8)), Data("#!\u{A0}x /rootfs/bin/sh\n".utf8))
    }

    func testBytesThatAreNotTextSurvive() throws {
        let bytes = Data([0xFF, 0xFE, 0x00, 0x80]) + Data(" /usr/bin\n".utf8) + Data([0xC3, 0x28])
        XCTAssertEqual(
            try RootlessToRoothide.maintainerScript(bytes),
            Data([0xFF, 0xFE, 0x00, 0x80]) + Data(" /rootfs/usr/bin\n".utf8) + Data([0xC3, 0x28])
        )
    }

    /// The patcher's loose tests of a name and of a directory, as bash's
    /// `=~` on the device answered them.
    func testWhatThePatcherEditsByName() throws {
        XCTAssertEqual(["postinst", "extrainst_", "rm", "inst", "in", "s", "postinst.sh"].map(RootlessToRoothide.isScript), [
            true, true, true, true, false, false, false,
        ])
        // an Arabic number sign makes one character with the dot after it
        XCTAssertEqual(["x.plist", "plist", ".plist", "x.plist.bak", "xplist", "\u{600}.plist"].map(RootlessToRoothide.isPropertyList), [
            true, true, true, false, false, true,
        ])
        // the last row are directories where ICU and POSIX part ways
        let rules: [String: RootlessToRoothide.PropertyListRule?] = [
            "Library/LaunchDaemons/x.plist": .daemon, "x.plist": .daemon, "Library/x.plist": .daemon, "Lib/x.plist": .daemon,
            "Library/LaunchDaemon./x.plist": .daemon, "Library/libSandy/x.plist": .sandbox,
            "Library/LaunchDaemons/sub/x.plist": nil, "Library/Preferences/x.plist": nil,
            "Library/Fixture (1)/x.plist": nil, "Library/[/x.plist": nil, "Library/Préférences/x.plist": nil,
            "(?i)library/x.plist": nil, "zz|/x.plist": nil, #"\x4cibrary/x.plist"#: nil, #"L\Qibrary\E/x.plist"#: nil,
            "(a|)/x.plist": nil, "a)|/L/x.plist": .daemon, "Library/LaunchDaemons}/x.plist": .daemon,
        ]
        for (path, rule) in rules {
            XCTAssertEqual(try RootlessToRoothide.propertyListRule(at: path), rule, path)
        }
        XCTAssertThrowsError(try RootlessToRoothide.propertyListRule(at: "Library/é(x)?/x.plist"))
    }

    /// One string of a list, as the patcher's sed lines leave it in the
    /// XML: a profile's paths only where the string starts.
    func testPathsInAPropertyList() {
        XCTAssertEqual(RootlessToRoothide.path("--root=/var/jb/x /var/jb", .daemon), "--root=/x /var/jb")
        let profile = [
            "/var/jb/Library/x": "/Library/x", "/Library/x": "/rootfs/Library/x", "/": "/rootfs/", "/usr": "/usr",
            "see /usr/lib": "see /usr/lib", "/var/jb": "/var/jb", "/var/jbx": "/var/jbx", "/var/mobile": "/rootfs/var/mobile",
            "/-var/jb-": "/var/jb", "/usr/\u{301}x": "/rootfs/usr/\u{301}x",
        ]
        for (string, respelled) in profile {
            XCTAssertEqual(RootlessToRoothide.path(string, .sandbox), respelled, string)
        }
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

    /// sed's lines end at a newline byte, a carriage return left on them.
    func testControlWithCarriageReturns() {
        XCTAssertEqual(
            RootlessToRoothide.control("Package: x\r\nConflicts: roothide\r\n\r\n", preDepends: nil),
            "Package: x\r\nConflicts: r-o-o-t-l-e-s-s-\r\n\r\n"
        )
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
