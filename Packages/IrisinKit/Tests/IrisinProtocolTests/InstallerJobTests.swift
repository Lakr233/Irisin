@testable import IrisinProtocol
import XCTest

final class InstallerJobTests: XCTestCase {
    func testPackageIdentities() {
        XCTAssertTrue(InstallerJob.isPackageIdentity("wiki.qaq.irisin"))
        XCTAssertTrue(InstallerJob.isPackageIdentity("libc++6"))
        XCTAssertTrue(InstallerJob.isPackageIdentity("0ad"))
        XCTAssertFalse(InstallerJob.isPackageIdentity("a"))
        XCTAssertFalse(InstallerJob.isPackageIdentity("-lead"))
        XCTAssertFalse(InstallerJob.isPackageIdentity("Has.Upper"))
        XCTAssertFalse(InstallerJob.isPackageIdentity("space here"))
        XCTAssertFalse(InstallerJob.isPackageIdentity("../../etc"))
        XCTAssertFalse(InstallerJob.isPackageIdentity(""))
    }

    /// A path is bytes to the kernel and to dpkg's lists: `..` with a
    /// combining mark after its slash is still `..`, and `\r\n` still ends a
    /// line.
    func testPathsAndLinesAreBytes() throws {
        for path in ["../\u{301}x", "a/../\u{301}b", "a\r\nb", "/\u{301}x"] {
            XCTAssertThrowsError(try PreparedPackage.relativePath(path), path.debugDescription)
        }
        XCTAssertEqual(try PreparedPackage.relativePath("./a//\u{301}b/./c"), "a/\u{301}b/c")
        // a value takes no line of its own into the paragraph
        let fields = try DebianControl.parse("Package: x\r\r\nDescription: y\r\nInjected: z\r\n")
        XCTAssertEqual(fields["package"], "x\r")
        XCTAssertEqual(fields["injected"], "z")
        XCTAssertEqual(try DebianControl.parse("A:\u{301}b\n \u{301}c\n")["a"], "\u{301}b \u{301}c")
    }

    func testTransactionValidation() throws {
        let good = InstallerJob.transaction(.init(
            install: [.init(identity: "com.example.tweak", path: "/var/mobile/Documents/x.deb")],
            remove: ["com.example.old"]
        ))
        XCTAssertNoThrow(try good.validate())

        let empty = InstallerJob.transaction(.init(install: [], remove: []))
        XCTAssertThrowsError(try empty.validate())

        let relative = InstallerJob.transaction(.init(install: [.init(identity: "a.b", path: "x.deb")], remove: []))
        XCTAssertThrowsError(try relative.validate())

        let climbing = InstallerJob.transaction(.init(install: [.init(identity: "a.b", path: "/tmp/../x.deb")], remove: []))
        XCTAssertThrowsError(try climbing.validate())

        let notADeb = InstallerJob.transaction(.init(install: [.init(identity: "a.b", path: "/tmp/x.tar")], remove: []))
        XCTAssertThrowsError(try notADeb.validate())

        let badIdentity = InstallerJob.transaction(.init(install: [], remove: ["rm -rf /"]))
        XCTAssertThrowsError(try badIdentity.validate())

        let tweak = InstallerJob.Transaction.Item(identity: "com.example.tweak", path: "/var/mobile/Documents/x.deb")
        let automatic = InstallerJob.transaction(.init(install: [tweak], remove: [], autoInstalled: [tweak.identity]))
        XCTAssertNoThrow(try automatic.validate())
        let markedTwice = InstallerJob.transaction(.init(
            install: [tweak], remove: [], autoInstalled: [tweak.identity, tweak.identity]
        ))
        XCTAssertThrowsError(try markedTwice.validate())
        let markedRemoval = InstallerJob.transaction(.init(
            install: [tweak], remove: ["com.example.old"], autoInstalled: ["com.example.old"]
        ))
        XCTAssertThrowsError(try markedRemoval.validate())
        XCTAssertNoThrow(try InstallerJob.transaction(.init(install: [tweak], remove: [], bootstrapInstall: true)).validate())
        XCTAssertThrowsError(try InstallerJob.transaction(.init(
            install: [tweak], remove: ["com.example.old"], bootstrapInstall: true
        )).validate())

        XCTAssertNoThrow(try InstallerJob.respring.validate())
        XCTAssertNoThrow(try InstallerJob.bootstrapIrisinDaemon.validate())
        XCTAssertNoThrow(try InstallerJob.bootoutIrisinDaemon.validate())
    }

    func testRoundTrip() throws {
        let job = InstallerJob.transaction(.init(
            install: [.init(identity: "com.example.tweak", path: "/var/mobile/Documents/x.deb")],
            remove: ["com.example.old"],
            dryRun: true
        ))
        let decoded = try InstallerJob.decode(job.encoded())
        XCTAssertEqual(decoded, job)
        let bootstrap = InstallerJob.transaction(.init(
            install: [.init(identity: "com.example.tweak", path: "/var/mobile/Documents/x.deb")],
            remove: [],
            bootstrapInstall: true
        ))
        XCTAssertEqual(try InstallerJob.decode(bootstrap.encoded()), bootstrap)
        XCTAssertThrowsError(try InstallerJob.decode(Data(repeating: 0x41, count: IrisinWire.maximumJobByteCount + 1)))
        XCTAssertThrowsError(try InstallerJob.decode(Data("{}".utf8)))

        for maintenance in [InstallerJob.bootstrapIrisinDaemon, .bootoutIrisinDaemon] {
            XCTAssertEqual(try InstallerJob.decode(maintenance.encoded()), maintenance)
        }

        // autoInstalled is a required key, as every other transaction field is
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: job.encoded()) as? [String: [String: [String: Any]]])
        object["transaction"]?["_0"]?.removeValue(forKey: "autoInstalled")
        XCTAssertThrowsError(try InstallerJob.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testTouchesSelf() {
        XCTAssertTrue(InstallerJob.Transaction(install: [], remove: ["wiki.qaq.irisin"]).touchesSelf)
        XCTAssertTrue(InstallerJob.Transaction(
            install: [.init(identity: "wiki.qaq.irisin.rootless", path: "/a.deb")], remove: []
        ).touchesSelf)
        XCTAssertFalse(InstallerJob.Transaction(install: [], remove: ["com.example.old"]).touchesSelf)
    }

    func testExitLine() {
        XCTAssertEqual(InstallerOutput.decode(InstallerOutput.encode(.exit(0))), .exit(0))
        XCTAssertEqual(InstallerOutput.decode(InstallerOutput.encode(.exit(2))), .exit(2))
        XCTAssertEqual(InstallerOutput.decode(#"{"exit":{"_0":"x"}}"#), .output(#"{"exit":{"_0":"x"}}"#))
        XCTAssertEqual(InstallerOutput.decode(InstallerOutput.encode(.notice("exit 0"))), .notice("exit 0"))
    }

    /// One event per line, and a line that is not one is output verbatim.
    func testEventFraming() {
        let events: [InstallerEvent] = [
            .started(.init(job: "transaction", uid: 0, installRoot: "/var/jb", timestamp: 1)),
            .phase(.applying),
            .progress(completed: 2, total: 5),
            .package(.configuring, identity: "com.example.tweak", version: "1.0-1"),
            .script(identity: "com.example.tweak", member: "postinst", arguments: ["configure", ""]),
            .output("a line\nwith a newline"),
            .notice("note"),
            .warning(.registrationFailed(bundle: "/Applications/X.app", detail: "LaunchServices said no")),
            .warning(.refreshFailed(detail: "1 failed, 0 unverified")),
            .failure(.installationStopped(detail: "Archive changed: a.b")),
            .packageProgress(identity: "com.example.tweak", completed: 3, total: 40),
            .failure(.packageFailed(identity: "a.b", step: .configuring, detail: "postinst returned 1")),
            .package(.verifying, identity: "a.b", version: ""),
            .failure(.packageFailed(identity: "a.b", step: .verifying, detail: "Archive changed: a.b")),
            .failure(.invalidJob),
            .exit(1),
        ]
        for event in events {
            let line = InstallerOutput.encode(event)
            XCTAssertFalse(line.contains("\n"), line)
            XCTAssertEqual(InstallerOutput.decode(line), event)
        }
        XCTAssertEqual(InstallerOutput.decode("Setting up x"), .output("Setting up x"))
        XCTAssertEqual(InstallerOutput.decode("{not json"), .output("{not json"))
        XCTAssertEqual(InstallerOutput.decode(#"{"unknown":{"_0":1}}"#), .output(#"{"unknown":{"_0":1}}"#))
        XCTAssertEqual(InstallerEvent.package(.unpacking, identity: "a.b", version: "1").description, "Unpacking a.b (1)")
        XCTAssertEqual(InstallerEvent.exit(3).description, "===> irisin-install exit 3")
    }
}
