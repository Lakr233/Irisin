@testable import AptRepository
import Darwin
import Foundation
import XCTest

/// The command line reads the catalogue the app writes, as root, from
/// mobile's folder: it answers what the writer's index answered, opens
/// nothing that is not there, and leaves the folder as it found it.
///
/// The app is another process here as it is on a device. WCDB keeps one
/// core per database file in a process, whatever the path's spelling, and a
/// read-only open of a file the process already has open makes its writable
/// handle read-only too: so the catalogue is written by an `AptDatabase`
/// that is gone before the reader opens, and held open and written after
/// that by `sqlite3`, the app's stand-in, which keeps the `-wal` and `-shm`
/// files there as the app's open handle does.
final class ReadOnlyCatalogueTests: XCTestCase {
    private static let repository = URL(string: "https://reader.example")!

    private var directory: URL!
    private var app: OtherProcess!
    /// What the writer's own index answered, read before it closed.
    private var written: (sunset: Package?, search: [String], packages: Set<String>, revision: Int64)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = TestEnvironment.root.appendingPathComponent("reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent(AptDatabase.fileName)
        try autoreleasepool {
            let writer = AptDatabase(at: database)
            seed(writer)
            let index = PackageIndex(db: writer)
            let snapshot = try index.resolutionSnapshot()
            written = (
                index.obtainPackage(with: "com.example.sunset", in: Self.repository),
                index.search("sun").map(\.identity),
                Set(snapshot.packages.map { "\($0.identity) \($0.latestVersion ?? "")" }),
                snapshot.catalogueRevision
            )
            // the stand-in opens before the writer closes, so the last
            // connection to close is never one that takes the two files
            app = try OtherProcess(database: database)
            XCTAssertEqual(app.run("PRAGMA journal_mode;"), "wal")
        }
    }

    override func tearDown() {
        app?.close()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func package(_ identity: String, _ version: String, _ fields: [String: String] = [:]) -> Package {
        var meta = fields
        meta["package"] = identity
        meta["version"] = version
        meta["architecture"] = "iphoneos-arm64"
        return Package(identity: identity, payload: [version: meta], repoRef: Self.repository)
    }

    private func seed(_ writer: AptDatabase) {
        writer.save(Repository(source: RepositorySource(url: Self.repository)))
        writer.replacePackages(of: Self.repository, with: [
            "com.example.sunset": package("com.example.sunset", "1.0", [
                "name": "Sunset", "author": "Alice", "section": "Tweaks",
                "description": "红色日落 for the lock screen",
            ]),
            "com.example.library": package("com.example.library", "2.0", [
                "name": "Library", "section": "System", "provides": "virtual-library",
            ]),
        ])
    }

    private func reader() throws -> PackageIndex {
        try PackageIndex.readOnly(in: directory, owner: getuid())
    }

    /// Every entry in the folder and its owner.
    private func listing(_ url: URL) throws -> [String: uid_t] {
        var result = [String: uid_t]()
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            var info = stat()
            XCTAssertEqual(lstat(url.appendingPathComponent(name).path, &info), 0)
            result[name] = info.st_uid
        }
        return result
    }

    func testReaderAnswersAsTheWriter() throws {
        let read = try reader()
        XCTAssertEqual(read.obtainRepositories().map(\.url), [Self.repository])
        XCTAssertEqual(read.obtainPackage(with: "com.example.sunset", in: Self.repository), written.sunset)
        XCTAssertEqual(read.obtainVirtualPackageReference(withIdentity: "virtual-library"), ["com.example.library"])
        // the verbatim tokenizer, registered on the reader, splits the key
        XCTAssertEqual(read.search("日落").map(\.identity), ["com.example.sunset"])
        XCTAssertEqual(read.search("sun").map(\.identity), written.search)

        let snapshot = try read.resolutionSnapshot()
        XCTAssertEqual(Set(snapshot.packages.map { "\($0.identity) \($0.latestVersion ?? "")" }), written.packages)
        XCTAssertEqual(snapshot.catalogueRevision, written.revision)
    }

    /// Nothing appears in the folder and nothing in it changes owner.
    func testOpenMakesNothingNew() throws {
        let before = try listing(directory)
        let read = try reader()
        _ = read.search("sunset")
        _ = try read.resolutionSnapshot()
        _ = read.obtainRepositories()
        XCTAssertEqual(try listing(directory), before)
    }

    /// The app goes on writing while the command line reads: each read
    /// answers the last commit.
    func testReaderSeesWhatTheWriterCommitsWhileOpen() throws {
        let read = try reader()
        XCTAssertEqual(read.obtainVirtualPackageReference(withIdentity: "virtual-library"), ["com.example.library"])
        let revision = try read.resolutionSnapshot().catalogueRevision

        app.run("""
        BEGIN;
        DELETE FROM \(AptDatabase.Table.virtual);
        UPDATE \(AptDatabase.Table.resolutionRevision) SET revision = revision + 1;
        COMMIT;
        """)
        XCTAssertEqual(read.obtainVirtualPackageReference(withIdentity: "virtual-library"), [])
        XCTAssertEqual(try read.resolutionSnapshot().catalogueRevision, revision + 1)
    }

    func testMissingWalOrShmIsRefused() throws {
        for missing in ["-wal", "-shm"] {
            let copy = TestEnvironment.root.appendingPathComponent("reader-copy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: copy) }
            for suffix in ["", "-wal", "-shm"] where suffix != missing {
                let name = AptDatabase.fileName + suffix
                try FileManager.default.copyItem(
                    at: directory.appendingPathComponent(name),
                    to: copy.appendingPathComponent(name)
                )
            }
            let before = try listing(copy)
            XCTAssertThrowsError(try PackageIndex.readOnly(in: copy, owner: getuid())) { error in
                XCTAssertEqual(
                    error as? CatalogueUnavailable,
                    CatalogueUnavailable(
                        file: copy.appendingPathComponent(AptDatabase.fileName + missing).path,
                        reason: .missing
                    )
                )
            }
            // refused before SQLite could make the missing file
            XCTAssertEqual(try listing(copy), before)
        }
    }

    func testAnotherOwnerIsRefused() {
        XCTAssertThrowsError(try PackageIndex.readOnly(in: directory, owner: getuid() + 1)) { error in
            XCTAssertEqual(
                error as? CatalogueUnavailable,
                CatalogueUnavailable(
                    file: directory.appendingPathComponent(AptDatabase.fileName).path,
                    reason: .owner(getuid())
                )
            )
        }
    }

    func testLinkInPlaceOfAFileIsRefused() throws {
        let shm = directory.appendingPathComponent(AptDatabase.fileName + "-shm")
        let moved = directory.appendingPathComponent("elsewhere-shm")
        try FileManager.default.moveItem(at: shm, to: moved)
        try FileManager.default.createSymbolicLink(at: shm, withDestinationURL: moved)
        XCTAssertThrowsError(try reader()) { error in
            XCTAssertEqual((error as? CatalogueUnavailable)?.reason, .notRegularFile)
        }
    }

    func testUpdatePreferencesComeFromTheCentersKeys() throws {
        let storage = MemoryStorage()
        try storage.write(key: UpdatePreferenceKey.blockedUpdates, value: JSONEncoder().encode(["com.example.sunset"]))
        defer {
            storage.write(key: UpdatePreferenceKey.blockedUpdates, value: nil)
        }
        var read = try reader()
        read.restoreUpdatePreferences(from: storage)
        XCTAssertEqual(read.blockedUpdateTable, ["com.example.sunset"])
    }
}

/// `sqlite3` holding a database open, one statement batch at a time: the
/// app, as far as a reader in this process can tell.
private final class OtherProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(database: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", database.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    /// What `sql` printed, once it has run.
    @discardableResult
    func run(_ sql: String) -> String {
        let marker = "--done-\(UUID().uuidString)--"
        input.fileHandleForWriting.write(Data("\(sql)\n.print \(marker)\n".utf8))
        var text = ""
        while !text.contains(marker) {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            text += String(decoding: data, as: UTF8.self)
        }
        return text.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func close() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}
