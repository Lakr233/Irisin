import Foundation
@testable import IrisinInstaller
import IrisinProtocol
import Testing

struct OrderedExecutionTests {
    /// The early configuration script needs the later package's executable,
    /// while the later package has a Pre-Depends on the first being configured.
    @Test func bootstrapInstallSeedsFilesBeforeNormalStages() throws {
        func run(bootstrap: Bool) throws -> (NativeInstallFixture, [InstallerEvent]) {
            let fixture = try NativeInstallFixture()
            let debianutils = try fixture.package(
                "debianutils",
                controls: ["postinst": "#!/bin/sh\ntest -f \"$DPKG_ROOT/bin/bash\"\n"]
            )
            let bash = try fixture.package(
                "bash",
                files: ["bin/bash": "available"],
                fields: ["pre-depends": "debianutils"]
            )
            let transaction = InstallerJob.Transaction(
                install: [debianutils, bash],
                remove: [],
                stages: [
                    .unpack(["debianutils"]), .configure(["debianutils"]),
                    .unpack(["bash"]), .configure(["bash"]),
                ],
                bootstrapInstall: bootstrap
            )
            var events: [InstallerEvent] = []
            let installer = PackageInstaller(
                installRoot: fixture.root.path,
                layout: .init(kind: .none),
                databaseDirectory: fixture.database,
                scriptRoot: fixture.root.path
            ) { events.append($0) }
            try installer.run(transaction)
            return (fixture, events)
        }

        let failure = #expect(throws: PackageStepFailure.self) { try run(bootstrap: false) }
        #expect(failure?.problem == .scriptFailed(
            identity: "debianutils",
            step: .configuring,
            script: "postinst",
            status: 1
        ))
        let (fixture, events) = try run(bootstrap: true)
        #expect(try fixture.status("debianutils") == "install ok installed")
        #expect(try fixture.status("bash") == "install ok installed")
        #expect(try fixture.text("bin/bash") == "available")
        #expect(events.contains(.notice("Bootstrap Install: placing all package files before the normal installation")))
    }

    /// Try Again after a Bootstrap Install that stopped at a script: the
    /// package it left unconfigured is configured beside the ones it never
    /// reached, whose files are placed first again.
    @Test func bootstrapInstallRetryConfiguresWhatTheFailedRunLeft() throws {
        let fixture = try NativeInstallFixture()
        let debianutils = try fixture.package(
            "debianutils",
            controls: ["postinst": "#!/bin/sh\ntest -f \"$DPKG_ROOT/bin/bash\" && test -f \"$DPKG_ROOT/ready\"\n"]
        )
        let bash = try fixture.package(
            "bash",
            files: ["bin/bash": "available"],
            fields: ["pre-depends": "debianutils"]
        )
        func installer() -> PackageInstaller {
            PackageInstaller(
                installRoot: fixture.root.path,
                layout: .init(kind: .none),
                databaseDirectory: fixture.database,
                scriptRoot: fixture.root.path
            ) { _ in }
        }
        func statusDigest() throws -> String {
            try PackageArchive.sha256(Data(contentsOf: fixture.database.appendingPathComponent("status")))
        }

        #expect(throws: PackageStepFailure.self) {
            try installer().run(.init(
                install: [debianutils, bash],
                remove: [],
                stages: [
                    .unpack(["debianutils"]), .configure(["debianutils"]),
                    .unpack(["bash"]), .configure(["bash"]),
                ],
                bootstrapInstall: true
            ))
        }
        #expect(try fixture.status("debianutils") == "install ok half-configured")
        #expect(try fixture.status("bash") == nil)

        try Data().write(to: fixture.root.appendingPathComponent("ready"))
        try installer().run(.init(
            install: [bash],
            remove: [],
            stages: [.configure(["debianutils"]), .unpack(["bash"]), .configure(["bash"])],
            configureExisting: ["debianutils"],
            statusDigest: statusDigest(),
            bootstrapInstall: true
        ))
        #expect(try fixture.status("debianutils") == "install ok installed")
        #expect(try fixture.status("bash") == "install ok installed")

        // a configured package is not a failed run's to finish
        let other = try fixture.package("other.package", files: ["bin/other": "other"])
        #expect(throws: PackageFailure.self) {
            try installer().run(.init(
                install: [other],
                remove: [],
                stages: [.unpack(["other.package"]), .configure(["other.package", "debianutils"])],
                configureExisting: ["debianutils"],
                statusDigest: statusDigest(),
                bootstrapInstall: true
            ))
        }
        #expect(try fixture.status("other.package") == nil)
    }

    @Test func bootstrapInstallChecksOwnershipBeforePlacingFiles() throws {
        let fixture = try NativeInstallFixture()
        let owner = try fixture.package("owner.package", files: ["bin/bash": "original"])
        try fixture.run(install: [owner])
        let incoming = try fixture.package("other.package", files: ["bin/bash": "replacement"])
        let status = try Data(contentsOf: fixture.database.appendingPathComponent("status"))
        let transaction = InstallerJob.Transaction(
            install: [incoming],
            remove: [],
            statusDigest: PackageArchive.sha256(status),
            bootstrapInstall: true
        )
        let installer = PackageInstaller(
            installRoot: fixture.root.path,
            layout: .init(kind: .none),
            databaseDirectory: fixture.database,
            scriptRoot: fixture.root.path
        ) { _ in }

        #expect(throws: PackageFailure.self) { try installer.run(transaction) }
        #expect(try fixture.text("bin/bash") == "original")
        #expect(try fixture.status("other.package") == nil)
    }

    @Test func changedStatusPreventsEveryCommand() throws {
        let root = try Scratch.installRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root + "/Library/dpkg/status"))
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: root) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [], remove: ["old"]))) != 0)
        #expect(!events.contains {
            if case .script = $0 {
                true
            } else {
                false
            }
        })
        #expect(!events.contains {
            if case .package = $0 {
                true
            } else {
                false
            }
        })
        #expect(events.contains {
            if case let .failure(.installationStopped(detail)) = $0 {
                detail.contains("Installed state changed")
            } else {
                false
            }
        })
    }

    @Test func changedArchiveStopsBeforeWriting() throws {
        let root = try Scratch.installRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("changed".utf8).write(to: URL(fileURLWithPath: root + "/new.deb"))
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: root) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [.init(identity: "new", path: root + "/new.deb")], remove: []))) != 0)
        // checked and nothing more: the failure names the archive and the step
        #expect(events.filter {
            if case .package = $0 {
                true
            } else {
                false
            }
        } == [.package(.verifying, identity: "new", version: "")])
        #expect(events.contains {
            if case .failure(.packageFailed("new", .verifying, _)) = $0 {
                true
            } else {
                false
            }
        })
    }

    /// A failing postinst stops the transaction at its package and step,
    /// named as the script it is, and the unpack before it counted its
    /// files up to the last.
    @Test func failureNamesItsPackageAndStep() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/a": "a", "usr/share/b": "b"], controls: ["postinst": "#!/bin/sh\nexit 1\n"])
        // the roothide layout keeps the database in the fixture; the Mac's
        // shell does not find the script by its jbroot path, and exits 127
        let shell = fixture.root.appendingPathComponent("bin/sh")
        try FileManager.default.createDirectory(at: shell.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: shell.path, withDestinationPath: "/bin/sh")
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) != 0)
        #expect(events.contains {
            if case .failure(.scriptFailed(package.identity, .configuring, "postinst", _)) = $0 {
                true
            } else {
                false
            }
        })
        let counts = events.compactMap {
            if case let .packageProgress(package.identity, completed, total) = $0 {
                (completed, total)
            } else {
                nil
            }
        }
        #expect(counts.last.map { $0.0 == $0.1 } == true)
    }

    /// A preinst that fails stops the unpack as a script, after the abort
    /// script ran, which is the last script the app hears of; a failure
    /// that is no script's stays the step's.
    @Test func preinstFailureIsTheScriptsAfterItsAbort() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(controls: ["preinst": "#!/bin/sh\nexit 3\n", "postrm": "#!/bin/sh\nexit 0\n"])
        var events: [InstallerEvent] = []
        let failure = #expect(throws: PackageStepFailure.self) { try fixture.run(install: [package]) { events.append($0) } }
        let scripts = events.compactMap {
            if case let .script(_, member, arguments) = $0 {
                "\(member) \(arguments.joined(separator: " "))"
            } else {
                nil
            }
        }
        #expect(scripts == ["preinst install", "postrm abort-install"])
        #expect(failure?.problem == .scriptFailed(identity: package.identity, step: .unpacking, script: "preinst", status: 3))

        try fixture.run(install: [fixture.package("owner.package", files: ["usr/share/taken": "theirs"])])
        let conflicting = try fixture.package("fresh.package", files: ["usr/share/taken": "mine"])
        let conflict = #expect(throws: PackageStepFailure.self) { try fixture.run(install: [conflicting]) }
        #expect(conflict.map {
            if case .packageFailed("fresh.package", .unpacking, _) = $0.problem {
                true
            } else {
                false
            }
        } == true)
    }

    /// The explicit recovery policy still attempts every package script and
    /// reports each failure, while the files and installed record reach their
    /// normal completed state. A script that cannot start follows the same
    /// recovery class as one that exits unsuccessfully.
    @Test func ignoredScriptFailuresStillRunAndWarn() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(
            files: ["usr/share/example": "native"],
            controls: [
                "preinst": "#!/bin/sh\necho preinst\nexit 3\n",
                "postinst": "#!/missing/interpreter\nexit 4\n",
            ]
        )
        var events: [InstallerEvent] = []

        try fixture.run(install: [package], ignoreScriptFailures: true) { events.append($0) }

        #expect(try fixture.status(package.identity) == "install ok installed")
        #expect(try fixture.text("usr/share/example") == "native")
        let scripts = events.compactMap {
            if case let .script(_, member, _) = $0 {
                member
            } else {
                nil
            }
        }
        #expect(scripts == ["preinst", "postinst"])
        let warnings = events.compactMap {
            if case let .warning(.scriptFailureIgnored(identity, script, detail)) = $0 {
                (identity, script, detail)
            } else {
                nil
            }
        }
        #expect(warnings.count == 2)
        #expect(warnings[0].0 == package.identity)
        #expect(warnings[0].1 == "preinst")
        #expect(warnings[0].2.contains("status 3"))
        #expect(warnings[1].0 == package.identity)
        #expect(warnings[1].1 == "postinst")
        #expect(!warnings[1].2.isEmpty)
    }

    /// Recovery Mode owns its complete relaxed policy: callers do not need a
    /// second flag for package-owned script failures to become warnings.
    @Test func recoveryModeIgnoresMaintainerScriptFailures() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(
            "recovery.scripts",
            files: ["usr/share/recovery-script": "installed"],
            controls: ["postinst": "#!/bin/sh\nexit 9\n"]
        )
        var ignoredScripts: [String] = []

        try fixture.run(install: [package], recoveryMode: true) { event in
            if case let .warning(.scriptFailureIgnored(_, script, _)) = event {
                ignoredScripts.append(script)
            }
        }

        #expect(try fixture.status(package.identity) == "install ok installed")
        #expect(try fixture.text("usr/share/recovery-script") == "installed")
        #expect(ignoredScripts == ["postinst"])
    }

    /// Recovery Mode bypasses package relationships. The same archive
    /// is rejected normally for its missing dependencies and conflict, then
    /// reaches the installed state under the explicit recovery policy.
    @Test func recoveryModeBypassesPackageRelationships() throws {
        let fixture = try NativeInstallFixture()
        let resident = try fixture.package("resident.package")
        try fixture.run(install: [resident])
        let recovery = try fixture.package(
            "recovery.package",
            files: ["usr/share/recovered": "yes"],
            fields: [
                "depends": "missing-dependency",
                "pre-depends": "missing-predependency",
                "conflicts": resident.identity,
            ]
        )

        #expect(throws: PackageFailure.self) {
            try fixture.run(install: [recovery])
        }
        try fixture.run(install: [recovery], recoveryMode: true)

        #expect(try fixture.status(recovery.identity) == "install ok installed")
        #expect(try fixture.text("usr/share/recovered") == "yes")
        #expect(try fixture.status(resident.identity) == "install ok installed")
    }

    /// The phases arrive in order, the count runs to the total, and every
    /// package step is a typed event the app can spell for itself.
    @Test func nativeRunnerReportsPhasesAndProgress() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/example": "native"])
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [package], remove: []))) == 0)
        #expect(try fixture.text("usr/share/example") == "native")
        let phases = events.compactMap {
            if case let .phase(phase) = $0 {
                phase
            } else {
                nil
            }
        }
        // Nothing under /Applications came or went, so no registration phase.
        #expect(phases == [.preparing, .verifying, .applying, .processingTriggers, .completed])
        let progress = events.compactMap {
            if case let .progress(completed, total) = $0 {
                (completed, total)
            } else {
                nil
            }
        }
        #expect(progress.map(\.0) == [0, 1, 2])
        #expect(progress.allSatisfy { $0.1 == 2 })
        #expect(events.contains(.package(.unpacking, identity: package.identity, version: "1")))
        #expect(events.contains(.package(.configuring, identity: package.identity, version: "1")))
        #expect(!events.contains { $0.description.contains("/usr/bin/dpkg") })
    }

    /// A script is announced with its arguments and every line it prints is
    /// output, in order, between the package steps it belongs to.
    @Test func scriptsAreAnnouncedAndTheirOutputRelayed() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/example": "native"], controls: ["postinst": "#!/bin/sh\necho configured\necho again >&2\n"])
        var events: [InstallerEvent] = []
        try fixture.run(install: [package]) { events.append($0) }
        let configure = try #require(events.firstIndex(of: .package(.configuring, identity: package.identity, version: "1")))
        #expect(events[(configure + 1)...].starts(with: [
            .script(identity: package.identity, member: "postinst", arguments: ["configure", ""]),
            .output("configured"),
            .output("again"),
        ]))
    }

    @Test func dryRunReportsStagesWithoutProgress() throws {
        let fixture = try NativeInstallFixture()
        let package = try fixture.package(files: ["usr/share/example": "native"])
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(installRoot: fixture.root.path, layout: .init(kind: .roothide(jbroot: fixture.root.path))) { events.append($0) }
        #expect(runner.run(.transaction(.init(install: [package], remove: [], dryRun: true))) == 0)
        #expect(events.contains {
            if case let .notice(text) = $0 {
                text.hasPrefix("Dry run: unpack")
            } else {
                false
            }
        })
        #expect(!events.contains {
            if case .progress = $0 {
                true
            } else {
                false
            }
        })
        // a dry run checks the archive and stops there
        #expect(events.filter {
            if case .package = $0 {
                true
            } else {
                false
            }
        } == [.package(.verifying, identity: package.identity, version: "")])
    }
}
