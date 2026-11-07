import CryptoKit
import Darwin
import Foundation
@testable import IrisinInstaller
import IrisinPreparation
import IrisinProtocol
import Testing

/// A package installed by the real pipeline from a real `.deb`, made with the
/// Mac's tar and ar, then repacked and read back. What "almost the same" means
/// is the comparison in `same`: everything but the control fields' order, the
/// compression and a `md5sums` the original did not ship.
struct PackageRepackTests {
    private final class Work {
        let root: URL
        let database: URL
        let build: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("repack " + UUID().uuidString).resolvingSymlinksInPath()
            database = root.appendingPathComponent("Library/dpkg")
            build = root.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: database.appendingPathComponent("info"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            // what a bootstrap's firmware script leaves
            try "Package: firmware\nStatus: install ok installed\nArchitecture: all\nVersion: 26.0\nDescription: iOS\n"
                .write(to: database.appendingPathComponent("status"), atomically: true, encoding: .utf8)
            // a maintainer script's interpreter is the bootstrap's, and a
            // script's path is in vroot's vocabulary, which no Mac speaks
            let shell = root.appendingPathComponent("bin/sh")
            try FileManager.default.createDirectory(at: shell.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: shell, atomically: true, encoding: .utf8)
            #expect(chmod(shell.path, 0o755) == 0)
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
    }

    private static func output(_ tool: String, _ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// `prepare` lays the payload out under `data`, the control members under
    /// `control`.
    private static func deb(
        _ work: Work,
        identity: String = "com.example.repack",
        control fields: String = "Maintainer: Someone <someone@example.com>\nSection: Utilities\nDepends: firmware (>= 15.0)\n",
        prepare: (_ data: URL, _ control: URL) throws -> Void
    ) throws -> URL {
        let directory = work.build.appendingPathComponent(UUID().uuidString)
        let data = directory.appendingPathComponent("data")
        let control = directory.appendingPathComponent("control")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try ("Package: \(identity)\nVersion: 2:1.2-3\nArchitecture: all\n\(fields)"
            + "Installed-Size: 12\nDescription: Repack test\n Second line\n .\n Third line\n")
            .write(to: control.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try prepare(data, control)
        try "2.0\n".write(to: directory.appendingPathComponent("debian-binary"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-czf", "../control.tar.gz", "."], in: control)
        try run("/usr/bin/tar", ["-czf", "../data.tar.gz", "--uid", "0", "--gid", "0", "."], in: data)
        try run("/usr/bin/ar", ["rcS", "p.deb", "debian-binary", "control.tar.gz", "data.tar.gz"], in: directory)
        return directory.appendingPathComponent("p.deb")
    }

    /// `layout` is the one the package is installed under.
    private static func install(_ deb: URL, in work: Work, layout: BootstrapLayout? = nil, identity: String = "com.example.repack") throws {
        let prepared = work.build.appendingPathComponent(UUID().uuidString)
        let digest = try DebianPreparation.prepare(at: deb, in: prepared)
        let status = try Data(contentsOf: work.database.appendingPathComponent("status"))
        let item = try InstallerJob.Transaction.Item(
            identity: identity,
            path: deb.path,
            sha256: PackageArchive.digest(deb, md5: false),
            preparedPath: prepared.path,
            preparedSHA256: digest
        )
        let transaction = InstallerJob.Transaction(install: [item], remove: [], statusDigest: PackageArchive.sha256(status))
        let installer = PackageInstaller(
            installRoot: work.root.path,
            layout: layout ?? .init(kind: .roothide(jbroot: work.root.path)),
            databaseDirectory: work.database,
            scriptRoot: work.root.path,
            emit: { _ in }
        )
        try installer.run(transaction)
    }

    private struct Outcome {
        var status: Int32
        var events: [InstallerEvent]
        var file: URL

        var repacked: InstallerEvent.Repacked? {
            events.lazy.compactMap { event -> InstallerEvent.Repacked? in
                if case let .repacked(repacked) = event {
                    return repacked
                }
                return nil
            }.first
        }

        var notices: [String] {
            events.compactMap { event in
                if case let .notice(text) = event {
                    return text
                }
                return nil
            }
        }
    }

    private static func repack(
        _ work: Work,
        layout: BootstrapLayout? = nil,
        identity: String = "com.example.repack",
        onEvent: @escaping (InstallerEvent, URL) -> Void = { _, _ in }
    ) throws -> Outcome {
        let file = work.build.appendingPathComponent(UUID().uuidString + ".deb")
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        var events: [InstallerEvent] = []
        let runner = InstallerRunner(
            installRoot: work.root.path,
            layout: layout ?? .init(kind: .roothide(jbroot: work.root.path)),
            emit: { event in
                events.append(event)
                onEvent(event, file)
            },
            registrar: { _ in [:] },
            daemonManager: { _ in },
            signalProcesses: { _, _ in 0 }
        )
        runner.repackDescriptor = descriptor
        let status = runner.run(.repack(identity: identity))
        return Outcome(status: status, events: events, file: file)
    }

    private static func prepared(_ deb: URL, in work: Work) throws -> (PreparedPackage, URL) {
        let directory = work.build.appendingPathComponent(UUID().uuidString)
        _ = try DebianPreparation.prepare(at: deb, in: directory)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try (JSONDecoder().decode(PreparedPackage.self, from: manifest), directory)
    }

    /// The two packages say the same thing, entry by entry.
    private static func same(_ original: URL, _ repacked: URL, in work: Work) throws {
        let (before, beforeFiles) = try prepared(original, in: work)
        let (after, afterFiles) = try prepared(repacked, in: work)
        var fields = try DebianControl.parse(before.control, preservingLinesFor: ["description"])
        var rebuilt = try DebianControl.parse(after.control, preservingLinesFor: ["description"])
        fields["package"] = fields["package"]?.lowercased()
        rebuilt["package"] = rebuilt["package"]?.lowercased()
        #expect(fields == rebuilt)

        let oldEntries = Dictionary(uniqueKeysWithValues: before.entries.map { ($0.path, $0) })
        let newEntries = Dictionary(uniqueKeysWithValues: after.entries.map { ($0.path, $0) })
        #expect(oldEntries.keys.sorted() == newEntries.keys.sorted())
        // which name of a hard link holds the bytes is the archive's order
        func file(_ entry: PreparedEntry, in entries: [String: PreparedEntry]) -> PreparedFile? {
            entry.kind == .hardLink ? entries[entry.linkTarget ?? ""]?.file : entry.file
        }
        func kind(_ entry: PreparedEntry) -> PreparedEntry.Kind {
            entry.kind == .hardLink ? .file : entry.kind
        }
        for (path, old) in oldEntries {
            guard let new = newEntries[path] else { continue }
            #expect(kind(old) == kind(new), "\(path)")
            #expect(file(old, in: oldEntries)?.sha256 == file(new, in: newEntries)?.sha256, "\(path)")
            if old.kind == .symbolicLink {
                #expect(old.linkTarget == new.linkTarget, "\(path)")
            } else {
                #expect(old.mode == new.mode, "\(path)")
            }
            // a link keeps the time it was made, on a device as here
            if old.kind == .file || old.kind == .hardLink {
                #expect(old.modificationTime == new.modificationTime, "\(path)")
            }
        }
        for (name, old) in before.controlFiles where name != "control" {
            let new = after.controlFiles[name]
            #expect(old.sha256 == new?.sha256, "\(name)")
            #expect(FileManager.default.contentsEqual(
                atPath: beforeFiles.appendingPathComponent(old.name).path,
                andPath: afterFiles.appendingPathComponent(new?.name ?? "").path
            ))
        }
        #expect(Set(after.controlFiles.keys).subtracting(before.controlFiles.keys).isSubset(of: ["md5sums"]))
    }

    private static func standardPayload(_ data: URL, _ control: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: data.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        try files.createDirectory(at: data.appendingPathComponent("usr/share/repack"), withIntermediateDirectories: true)
        try files.createDirectory(at: data.appendingPathComponent("etc"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho repack\n".write(to: data.appendingPathComponent("usr/bin/tool"), atomically: true, encoding: .utf8)
        #expect(chmod(data.appendingPathComponent("usr/bin/tool").path, 0o4755) == 0)
        try "setting=1\n".write(to: data.appendingPathComponent("etc/repack.conf"), atomically: true, encoding: .utf8)
        try Data(repeating: 0xA5, count: 300_000).write(to: data.appendingPathComponent("usr/share/repack/blob"))
        try "résumé\n".write(to: data.appendingPathComponent("usr/share/repack/résumé 文件"), atomically: true, encoding: .utf8)
        // past the 100 bytes a plain tar name holds
        let long = String(repeating: "deep/", count: 30)
        try files.createDirectory(at: data.appendingPathComponent("usr/share/repack/" + long), withIntermediateDirectories: true)
        try "long\n".write(to: data.appendingPathComponent("usr/share/repack/\(long)leaf"), atomically: true, encoding: .utf8)
        // a link in the jbroot, a relative one, and a hard link
        try files.createSymbolicLink(atPath: data.appendingPathComponent("usr/bin/absolute").path, withDestinationPath: "/usr/bin/tool")
        try files.createSymbolicLink(atPath: data.appendingPathComponent("usr/bin/relative").path, withDestinationPath: "tool")
        try files.createSymbolicLink(atPath: data.appendingPathComponent("usr/bin/system").path, withDestinationPath: "/rootfs/usr/bin/true")
        #expect(link(
            data.appendingPathComponent("usr/share/repack/blob").path,
            data.appendingPathComponent("usr/share/repack/hard").path
        ) == 0)
        for (name, text) in [
            ("postinst", "#!/bin/sh\nexit 0\n"), ("prerm", "#!/bin/sh\nexit 0\n"), ("extrainst_", "#!/bin/sh\nexit 0\n"),
        ] {
            try text.write(to: control.appendingPathComponent(name), atomically: true, encoding: .utf8)
            #expect(chmod(control.appendingPathComponent(name).path, 0o755) == 0)
        }
        try "/etc/repack.conf\n".write(to: control.appendingPathComponent("conffiles"), atomically: true, encoding: .utf8)
        try "interest /usr/share/repack\n".write(to: control.appendingPathComponent("triggers"), atomically: true, encoding: .utf8)
    }

    @Test func theRepackedPackageSaysWhatTheOriginalSaid() throws {
        let work = try Work()
        let original = try Self.deb(work, prepare: Self.standardPayload)
        try Self.install(original, in: work)

        let outcome = try Self.repack(work)
        #expect(outcome.status == 0, "\(outcome.events)")
        #expect(outcome.repacked == .init(fileName: "com.example.repack_1.2-3_all.deb", leftOut: 0, changed: 0))
        #expect(outcome.events.last == .phase(.completed))
        try Self.same(original, outcome.file, in: work)

        // and it knows nothing dpkg's status added
        let (package, directory) = try Self.prepared(outcome.file, in: work)
        for field in ["Status:", "Conffiles:", "Config-Version:"] {
            #expect(!package.control.contains(field))
        }
        #expect(package.control.contains("Description: Repack test\n Second line\n .\n Third line\n"))
        let sums = try String(
            contentsOf: directory.appendingPathComponent(#require(package.controlFiles["md5sums"]).name),
            encoding: .utf8
        )
        // the conffile stays out, as it does from dpkg's own
        #expect(!sums.contains("etc/repack.conf"))
        #expect(sums.contains("  usr/share/repack/hard\n"))
        #expect(sums.contains("  usr/bin/tool\n"))
        // one name holds the bytes and the other links to it
        let kinds = package.entries.filter { ["usr/share/repack/hard", "usr/share/repack/blob"].contains($0.path) }.map(\.kind)
        #expect(Set(kinds) == [.file, .hardLink])
    }

    /// A package that shipped its own `md5sums` gets it back as it was, in
    /// its own order, while nothing changed; `same` compares the bytes.
    @Test func anUntouchedPackageKeepsItsOwnSums() throws {
        let work = try Work()
        let original = try Self.deb(work) { data, control in
            try FileManager.default.createDirectory(at: data.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
            var sums = ""
            for name in ["zebra", "apple"] {
                try name.write(to: data.appendingPathComponent("usr/bin/\(name)"), atomically: true, encoding: .utf8)
                let digest = Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
                sums += "\(digest)  usr/bin/\(name)\n"
            }
            try sums.write(to: control.appendingPathComponent("md5sums"), atomically: true, encoding: .utf8)
        }
        try Self.install(original, in: work)
        let outcome = try Self.repack(work)
        #expect(outcome.status == 0, "\(outcome.events)")
        try Self.same(original, outcome.file, in: work)
    }

    /// Nobody but this code wrote the archive: the system's ar and tar read
    /// it, and dpkg-deb where it is installed.
    @Test func otherToolsReadThePackage() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        let file = try Self.repack(work).file
        let members = try String(decoding: Self.output("/usr/bin/ar", ["-t", file.path], in: work.build), as: UTF8.self)
        #expect(members == "debian-binary\ncontrol.tar.xz\ndata.tar.xz\n")
        let bytes = try Data(contentsOf: file)
        #expect(bytes.starts(with: Data("!<arch>\ndebian-binary   ".utf8)))
        #expect(bytes.count % 2 == 0)

        let extracted = work.build.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ar", ["-x", file.path], in: extracted)
        let listing = try String(
            decoding: Self.output("/usr/bin/tar", ["-tvf", "data.tar.xz"], in: extracted),
            as: UTF8.self
        )
        #expect(listing.split(separator: "\n").first?.hasSuffix(" ./") == true)
        #expect(listing.contains("./usr/bin/tool"))
        #expect(listing.contains("rwsr-xr-x"))
        #expect(try String(
            decoding: Self.output("/usr/bin/tar", ["-xOf", "data.tar.xz", "./usr/share/repack/résumé 文件"], in: extracted),
            as: UTF8.self
        ) == "résumé\n")

        let dpkgDeb = "/opt/homebrew/bin/dpkg-deb"
        if FileManager.default.isExecutableFile(atPath: dpkgDeb) {
            let fields = try String(
                decoding: Self.output(dpkgDeb, ["--field", file.path, "Package", "Version"], in: extracted),
                as: UTF8.self
            )
            #expect(fields == "Package: com.example.repack\nVersion: 2:1.2-3\n")
            let contents = try String(decoding: Self.output(dpkgDeb, ["--contents", file.path], in: extracted), as: UTF8.self)
            #expect(contents.contains("./usr/bin/relative -> tool"))
        }
    }

    /// The whole way round: what was repacked installs into a fresh root and
    /// leaves the same files, and is repacked into the same package again.
    @Test func theRepackedPackageInstallsAndRepacksTheSame() throws {
        let first = try Work()
        try Self.install(try Self.deb(first, prepare: Self.standardPayload), in: first)
        let repacked = try Self.repack(first).file

        let second = try Work()
        let moved = second.build.appendingPathComponent("repacked.deb")
        try FileManager.default.copyItem(at: repacked, to: moved)
        try Self.install(moved, in: second)
        for path in ["usr/bin/tool", "usr/share/repack/blob", "etc/repack.conf", "usr/share/repack/résumé 文件"] {
            #expect(FileManager.default.contentsEqual(
                atPath: first.root.appendingPathComponent(path).path,
                andPath: second.root.appendingPathComponent(path).path
            ))
        }
        let scripts = second.database.appendingPathComponent("info/com.example.repack.postinst")
        #expect(FileManager.default.isExecutableFile(atPath: scripts.path))
        let again = try Self.repack(second)
        #expect(again.status == 0, "\(again.events)")
        #expect(again.repacked?.changed == 0)
        try Self.same(repacked, again.file, in: second)
    }

    @Test func oneInstallationRepacksToOneFile() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        let one = try Data(contentsOf: Self.repack(work).file)
        let two = try Data(contentsOf: Self.repack(work).file)
        #expect(one == two)
    }

    /// What dpkg writes on disk, read back: the jbroot goes, `/rootfs` comes
    /// back, and a relative link was never touched.
    @Test func aRoothideLinkIsSpelledAsTheArchiveSpelledIt() throws {
        let work = try Work()
        let original = try Self.deb(work, prepare: Self.standardPayload)
        try Self.install(original, in: work)
        var raw = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = readlink(work.root.appendingPathComponent("usr/bin/absolute").path, &raw, raw.count - 1)
        #expect(length > 0)
        #expect(String(cString: raw).hasPrefix(work.root.path))
        let (package, _) = try Self.prepared(Self.repack(work).file, in: work)
        let links = Dictionary(uniqueKeysWithValues: package.entries.map { ($0.path, $0.linkTarget) })
        #expect(links["usr/bin/absolute"] == "/usr/bin/tool")
        #expect(links["usr/bin/relative"] == "tool")
        #expect(links["usr/bin/system"] == "/rootfs/usr/bin/true")
    }

    @Test func archivedLinkTextIsTheReverseOfLinkText() {
        let jbroot = "/private/var/containers/Bundle/Application/.jbroot-000114514191980C"
        let layout = BootstrapLayout(kind: .roothide(jbroot: jbroot))
        for text in ["/usr/bin/tool", "/", "/rootfs", "/rootfs/usr/bin/true", "tool", "../lib/x"] {
            let round = layout.archivedLinkText(layout.linkText(text))
            #expect(round == text, "\(text)")
        }
        // another spelling of the same root, and the name it had last time
        #expect(layout.archivedLinkText("/var/containers/Bundle/Application/.jbroot-000114514191980C/usr/lib") == "/usr/lib")
        let rootless = BootstrapLayout(kind: .rootless(prefix: "/var/jb"))
        #expect(rootless.archivedLinkText("/var/jb/usr/lib") == "/var/jb/usr/lib")
    }

    /// RootHide's root sits among the app containers, group 33. `usr` and
    /// `Library`, which predate every package, keep that group, and so does a
    /// daemon's plist RootHide rewrote.
    @Test func aDirectoryDoesNotKeepTheGroupOfWhereTheRootSits() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        var info = stat()
        #expect(stat(work.root.path, &info) == 0)
        #expect(info.st_gid != 0, "the harness's temporary directory is not wheel's")
        let (package, _) = try Self.prepared(Self.repack(work).file, in: work)
        for entry in package.entries {
            #expect(entry.gid == 0, "\(entry.path)")
            #expect(entry.groupName == "wheel", "\(entry.path)")
        }
    }

    /// A rootless archive walks `/var` and `/var/jb`, which on a device are
    /// links: as links, they would replace `/var/jb` when it is installed.
    @Test func aRootlessArchiveKeepsItsDirectories() throws {
        let work = try Work()
        let layout = BootstrapLayout(kind: .rootless(prefix: "/var/jb"), mount: work.root.path)
        let original = try Self.deb(work) { data, _ in
            let files = FileManager.default
            try files.createDirectory(at: data.appendingPathComponent("var/jb/usr/bin"), withIntermediateDirectories: true)
            try "tool\n".write(to: data.appendingPathComponent("var/jb/usr/bin/tool"), atomically: true, encoding: .utf8)
            try files.createDirectory(at: data.appendingPathComponent("var/jb/Library/MobileSubstrate/DynamicLibraries"), withIntermediateDirectories: true)
            try "dylib\n".write(
                to: data.appendingPathComponent("var/jb/Library/MobileSubstrate/DynamicLibraries/tweak.dylib"),
                atomically: true,
                encoding: .utf8
            )
        }
        // what ElleKit leaves: the directory a tweak ships is a link by now
        let files = FileManager.default
        try files.createDirectory(at: work.root.appendingPathComponent("usr/lib/TweakInject"), withIntermediateDirectories: true)
        try files.createDirectory(at: work.root.appendingPathComponent("Library/MobileSubstrate"), withIntermediateDirectories: true)
        try files.createSymbolicLink(
            atPath: work.root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries").path,
            withDestinationPath: "/var/jb/usr/lib/TweakInject"
        )
        try Self.install(original, in: work, layout: layout)

        let outcome = try Self.repack(work, layout: layout)
        #expect(outcome.status == 0, "\(outcome.events)")
        #expect(outcome.repacked?.leftOut == 0)
        let (package, _) = try Self.prepared(outcome.file, in: work)
        let kinds = Dictionary(uniqueKeysWithValues: package.entries.map { ($0.path, $0.kind) })
        #expect(kinds["var"] == .directory)
        #expect(kinds["var/jb"] == .directory)
        #expect(kinds["var/jb/usr/bin/tool"] == .file)
        #expect(kinds["var/jb/Library/MobileSubstrate/DynamicLibraries"] == .directory)
        #expect(kinds["var/jb/Library/MobileSubstrate/DynamicLibraries/tweak.dylib"] == .file)
    }

    /// A package that changed since it was installed goes in as it is now, and
    /// the package agrees with itself: `md5sums` is of the bytes that went in.
    @Test func whatChangedIsKeptAndSaid() throws {
        let work = try Work()
        let original = try Self.deb(work, prepare: Self.standardPayload)
        try Self.install(original, in: work)
        try "setting=2\n".write(to: work.root.appendingPathComponent("etc/repack.conf"), atomically: true, encoding: .utf8)
        try "edited\n".write(to: work.root.appendingPathComponent("usr/share/repack/résumé 文件"), atomically: true, encoding: .utf8)
        #expect(unlink(work.root.appendingPathComponent("usr/bin/relative").path) == 0)

        let outcome = try Self.repack(work)
        #expect(outcome.status == 0, "\(outcome.events)")
        #expect(outcome.repacked?.changed == 2)
        #expect(outcome.repacked?.leftOut == 1)
        #expect(outcome.notices.contains("Left out /usr/bin/relative"))
        #expect(outcome.notices.contains("Changed since installation: /etc/repack.conf"))
        #expect(outcome.notices.contains("Changed since installation: /usr/share/repack/résumé 文件"))

        let (package, directory) = try Self.prepared(outcome.file, in: work)
        #expect(!package.entries.contains { $0.path == "usr/bin/relative" })
        let conf = try #require(package.entries.first { $0.path == "etc/repack.conf" }?.file)
        #expect(try String(contentsOf: directory.appendingPathComponent(conf.name), encoding: .utf8) == "setting=2\n")
        let edited = try #require(package.entries.first { $0.path == "usr/share/repack/résumé 文件" }?.file)
        let sums = try String(
            contentsOf: directory.appendingPathComponent(#require(package.controlFiles["md5sums"]).name),
            encoding: .utf8
        )
        #expect(sums.contains(edited.md5 + "  usr/share/repack/résumé 文件\n"))
    }

    /// dpkg-deb refuses a package that declares a conffile it does not hold.
    @Test func aDeletedConffileIsNoLongerDeclared() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        #expect(unlink(work.root.appendingPathComponent("etc/repack.conf").path) == 0)
        let outcome = try Self.repack(work)
        #expect(outcome.status == 0, "\(outcome.events)")
        #expect(outcome.repacked?.leftOut == 1)
        let (package, _) = try Self.prepared(outcome.file, in: work)
        #expect(package.controlFiles["conffiles"] == nil)
    }

    @Test func aMetapackageRepacksToNoFiles() throws {
        let work = try Work()
        let original = try Self.deb(work) { _, _ in }
        try Self.install(original, in: work)
        let outcome = try Self.repack(work)
        #expect(outcome.status == 0, "\(outcome.events)")
        try Self.same(original, outcome.file, in: work)
    }

    @Test func aPackageThatIsNotInstalledIsRefused() throws {
        let work = try Work()
        let outcome = try Self.repack(work)
        #expect(outcome.status == 1)
        #expect(outcome.repacked == nil)
        #expect(outcome.events.contains {
            if case let .failure(.repackFailed(identity, _)) = $0 {
                identity == "com.example.repack"
            } else {
                false
            }
        })
        #expect(try Data(contentsOf: outcome.file).isEmpty)
    }

    /// Cancel takes the file away, and that is all it can do to a helper
    /// running as root.
    @Test func removingTheFileStopsTheRepack() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        let outcome = try Self.repack(work) { event, file in
            if case .packageProgress = event {
                unlink(file.path)
            }
        }
        #expect(outcome.status == 1)
        #expect(outcome.repacked == nil)
        // nothing of root's stays behind
        let names = try FileManager.default.contentsOfDirectory(atPath: work.database.path)
        #expect(!names.contains { $0.hasPrefix("irisin-repack-") })
    }

    /// A helper that was killed leaves its members, root's, in dpkg's directory.
    @Test func whatAKilledRepackLeftGoes() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        let left = work.database.appendingPathComponent("irisin-repack-left")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        #expect(try Self.repack(work).status == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: work.database.path)
        #expect(!names.contains { $0.hasPrefix("irisin-repack-") })
    }

    /// Repacking is not a transaction: an install in progress is waited out
    /// by nobody, and it says so.
    @Test func aDatabaseInUseIsRefused() throws {
        let work = try Work()
        try Self.install(try Self.deb(work, prepare: Self.standardPayload), in: work)
        // a lock held by another process: this one's own would not conflict
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", """
        use Fcntl; open(my $f, '+>', shift) or die;
        my $lock = pack('s s l! l! l! l! l!', F_WRLCK, 0, 0, 0, 0, 0, 0);
        my $record = pack('q q l s s', 0, 0, 0, F_WRLCK, 0);
        fcntl($f, F_SETLK, $record) or die; print "ok\\n"; $| = 1; sleep 30;
        """, work.database.appendingPathComponent("lock-frontend").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        defer { process.terminate() }
        _ = pipe.fileHandleForReading.availableData
        let outcome = try Self.repack(work)
        #expect(outcome.status == 1)
        #expect(outcome.events.contains {
            if case let .failure(.repackFailed(_, detail)) = $0 {
                detail.contains("package database")
            } else {
                false
            }
        })
    }

    @Test func aJobThatNamesNoPackageIsInvalid() throws {
        #expect(throws: IrisinFailure.self) { try InstallerJob.repack(identity: "../etc/passwd").validate() }
        #expect(throws: IrisinFailure.self) { try InstallerJob.repack(identity: "x").validate() }
        let job = InstallerJob.repack(identity: "com.example.repack")
        #expect(try InstallerJob.decode(job.encoded()) == job)
        #expect(job.name == "repack")
    }
}
