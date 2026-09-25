import AptRepository
import Foundation
import IrisinProtocol
import XCTest

final class LocalPackageTests: XCTestCase {
    /// A `.deb` assembled with the system `tar` and `ar` reads back as a
    /// repository-less package whose download link is the file itself.
    func testPackageFromDebianFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Package: Com.Example.Hello\nVersion: 1.2-3\nArchitecture: iphoneos-arm64\n"
            .write(to: dir.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "2.0\n".write(to: dir.appendingPathComponent("debian-binary"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-czf", "control.tar.gz", "control"], in: dir)
        try run("/usr/bin/tar", ["-czf", "data.tar.gz", "control"], in: dir)
        // S: no symbol table, the plain ar that dpkg-deb writes
        try run("/usr/bin/ar", ["rcS", "hello world.deb", "debian-binary", "control.tar.gz", "data.tar.gz"], in: dir)

        let deb = dir.appendingPathComponent("hello world.deb")
        let package = try Package(debianPackageAt: deb)
        XCTAssertEqual(package.identity, "com.example.hello")
        XCTAssertEqual(package.latestVersion, "1.2-3")
        XCTAssertNil(package.repoRef)
        XCTAssertEqual(package.localFileURL?.path, deb.path)
        XCTAssertEqual(package.obtainDownloadLink().path, deb.path)

        let remote = try Package(identity: "x", payload: ["1": ["filename": "./pool/x.deb"]], repoRef: XCTUnwrap(URL(string: "https://r.example")))
        XCTAssertNil(remote.localFileURL)
        XCTAssertThrowsError(try Package(debianPackageAt: dir.appendingPathComponent("control")))
    }

    /// A listing that leaves out what the file's control says (a repository
    /// whose index dropped Conflicts) is refused by name, field by field;
    /// the file against itself passes.
    func testListingThatDisagreesWithTheFileIsNamed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Package: a.b\nVersion: 1\nArchitecture: iphoneos-arm64\nConflicts: c.d\n"
            .write(to: dir.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "2.0\n".write(to: dir.appendingPathComponent("debian-binary"), atomically: true, encoding: .utf8)
        try run("/usr/bin/tar", ["-czf", "control.tar.gz", "control"], in: dir)
        try run("/usr/bin/tar", ["-czf", "data.tar.gz", "control"], in: dir)
        try run("/usr/bin/ar", ["rcS", "a.deb", "debian-binary", "control.tar.gz", "data.tar.gz"], in: dir)
        let deb = dir.appendingPathComponent("a.deb")

        XCTAssertNoThrow(try Package(debianPackageAt: deb).validateArchive(at: deb))
        let listed = try Package(
            identity: "a.b",
            payload: ["1": ["version": "1", "architecture": "iphoneos-arm64"]],
            repoRef: XCTUnwrap(URL(string: "https://r.example"))
        )
        XCTAssertThrowsError(try listed.validateArchive(at: deb)) { error in
            XCTAssertEqual(
                (error as? ArchiveMismatch)?.differences,
                [.init(field: "conflicts", listed: "", found: "c.d")]
            )
        }
    }

    /// The listing reads both inner archives through the outer one: every
    /// control member as bytes, the payload as absolute paths, directories
    /// apart from what is not one.
    func testDebianContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = dir.appendingPathComponent("var/jb/usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "Package: a.b\nVersion: 1\n".write(to: dir.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: dir.appendingPathComponent("postinst"), atomically: true, encoding: .utf8)
        try "2.0\n".write(to: dir.appendingPathComponent("debian-binary"), atomically: true, encoding: .utf8)
        // bigger than one read, so the member is streamed in several
        try Data(count: 300_000).write(to: bin.appendingPathComponent("hello"))
        try FileManager.default.createSymbolicLink(atPath: bin.path + "/hi", withDestinationPath: "hello")
        try run("/usr/bin/tar", ["-czf", "control.tar.gz", "./control", "./postinst"], in: dir)
        try run("/usr/bin/tar", ["-cf", "data.tar", "./var"], in: dir)
        try run("/usr/bin/ar", ["rcS", "a.deb", "debian-binary", "control.tar.gz", "data.tar"], in: dir)

        let contents = try ArchiveStream.debianContents(atPath: dir.appendingPathComponent("a.deb").path)
        XCTAssertEqual(Set(contents.controlFiles.keys), ["control", "postinst"])
        XCTAssertEqual(contents.controlFiles["postinst"], Data("#!/bin/sh\nexit 0\n".utf8))
        XCTAssertEqual(contents.files.sorted(), ["/var/jb/usr/bin/hello", "/var/jb/usr/bin/hi"])
        XCTAssertEqual(contents.directories.sorted(), ["/var", "/var/jb", "/var/jb/usr", "/var/jb/usr/bin"])
        XCTAssertThrowsError(try ArchiveStream.debianContents(atPath: dir.appendingPathComponent("control").path))

        // the member names alone, spelled without the archive's `./`
        let members = try ArchiveStream.debianControlMembers(atPath: dir.appendingPathComponent("a.deb").path)
        XCTAssertEqual(members, ["control", "postinst"])
        XCTAssertEqual(try ArchiveStream.debianControl(atPath: dir.appendingPathComponent("a.deb").path), "Package: a.b\nVersion: 1\n")
        XCTAssertThrowsError(try ArchiveStream.debianControlMembers(atPath: dir.appendingPathComponent("control").path))
    }

    /// dpkg installs an entry as the user its archive names, when the
    /// system knows the name, whatever number is stored beside it: a
    /// package packed on a Mac says `root` next to the builder's uid.
    func testPreparedOwnersAreReadByName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Package: a.b\nVersion: 1\nArchitecture: all\n".write(to: dir.appendingPathComponent("control"), atomically: true, encoding: .utf8)
        try "2.0\n".write(to: dir.appendingPathComponent("debian-binary"), atomically: true, encoding: .utf8)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a/named"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("a/unknown"))
        try run("/usr/bin/tar", ["-czf", "control.tar.gz", "./control"], in: dir)
        try run("/usr/bin/tar", ["-cf", "data.tar", "--uid", "501", "--gid", "20", "--uname", "root", "--gname", "wheel", "./a/named"], in: dir)
        try run("/usr/bin/tar", ["-rf", "data.tar", "--uid", "777", "--gid", "778", "--uname", "irisin-nobody", "--gname", "irisin-nobody", "./a/unknown"], in: dir)
        try run("/usr/bin/ar", ["rcS", "a.deb", "debian-binary", "control.tar.gz", "data.tar"], in: dir)

        let prepared = dir.appendingPathComponent("prepared")
        _ = try ArchiveStream.prepareDebianPackage(at: dir.appendingPathComponent("a.deb"), in: prepared)
        let manifest = try JSONDecoder().decode(PreparedPackage.self, from: Data(contentsOf: prepared.appendingPathComponent("manifest.json")))
        let owners = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, [$0.uid, $0.gid]) })
        XCTAssertEqual(owners, ["a/named": [0, 0], "a/unknown": [777, 778]])
    }

    private func run(_ tool: String, _ arguments: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
}
