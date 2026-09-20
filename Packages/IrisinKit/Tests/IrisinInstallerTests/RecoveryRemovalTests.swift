import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

struct RecoveryRemovalTests {
    @Test func recoveryReinstallationContinuesWhenMaintainerInterpreterIsMissing() throws {
        let fixture = try NativeInstallFixture()
        let missingShell = "#!/missing/irisin-test-shell\nexit 1\n"
        let package = try fixture.package(
            "repair", files: ["usr/share/repair": "restored"],
            controls: ["prerm": missingShell, "preinst": missingShell, "postinst": missingShell]
        )
        try fixture.run(install: [package], recoveryMode: true)
        #expect(throws: (any Error).self) { try fixture.run(install: [package]) }
        var ignored: Set<String> = []
        try fixture.run(install: [package], recoveryMode: true) { event in
            if case let .warning(.scriptFailureIgnored(_, script, _)) = event {
                ignored.insert(script)
            }
        }
        #expect(ignored == ["prerm", "preinst", "postinst"])
        #expect(try fixture.status("repair") == "install ok installed")
        #expect(try fixture.text("usr/share/repair") == "restored")
    }

    @Test func removesHalfInstalledPackageDespiteMissingInterpreterAndDependents() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(
            "broken",
            files: ["usr/share/broken": "payload"],
            controls: ["postrm": "#!/missing/irisin-test-shell\nexit 1\n"]
        )
        let dependent = try fixture.package("dependent", fields: ["depends": "broken"])
        try fixture.run(install: [package, dependent])
        let database = try PackageDatabase(directory: fixture.database)
        var fields = try #require(database.records["broken"])
        fields["status"] = "install reinstreq half-installed"
        try database.commit("broken", fields)
        var ignored = false
        try fixture.run(remove: ["broken"], recoveryMode: true) { event in
            if case .warning(.scriptFailureIgnored("broken", "postrm", _)) = event {
                ignored = true
            }
        }
        #expect(ignored)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("usr/share/broken").path))
        #expect(try fixture.status("broken") == "deinstall ok config-files")
        #expect(try fixture.status("dependent") == "install ok installed")
    }

    @Test(arguments: ["essential", "protected"])
    func recoveryRemovalRequiresSystemRemovalPermission(field: String) throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(fields: [field: "yes"])
        try fixture.run(install: [package])
        #expect(throws: (any Error).self) {
            try fixture.run(remove: [package.identity], recoveryMode: true)
        }
        #expect(try fixture.status() == "install ok installed")
        try fixture.run(remove: [package.identity], allowSystemRemoval: true, recoveryMode: true)
        #expect(try fixture.status() == nil)
    }

    @Test func recoveryRemovalNeverRemovesHeldPackage() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package()
        try fixture.run(install: [package])
        let database = try PackageDatabase(directory: fixture.database)
        var fields = try #require(database.records[package.identity])
        fields["status"] = "hold ok installed"
        try database.commit(package.identity, fields)
        #expect(throws: (any Error).self) {
            try fixture.run(remove: [package.identity], allowSystemRemoval: true, recoveryMode: true)
        }
        #expect(try fixture.status() == "hold ok installed")
    }
}
