@testable import AptRepository
import Foundation
import XCTest

/// Files taken from a Debian 12 arm64 machine: its dpkg status file, and
/// every version its package lists carried, ordered by apt itself. The
/// parser and the comparison are held to what that machine does.
final class FixtureTests: XCTestCase {
    private static var environment: URL {
        TestEnvironment.root
    }

    // MARK: - STATUS FILE

    func testParsesEveryStanzaOfTheStatusFile() async throws {
        let status = try TestEnvironment.fixture("installed-status")
        let stanzas = status.components(separatedBy: "\n\n").filter { $0.contains("Package: ") }.count
        let path = Self.environment.appendingPathComponent("status").path
        try status.write(toFile: path, atomically: true, encoding: .utf8)

        let read = await PackageCenter.readInstalled(at: path)
        let packages = try XCTUnwrap(read)
        XCTAssertEqual(packages.count, stanzas)
        for (identity, package) in packages {
            XCTAssertEqual(package.identity, identity)
            XCTAssertNil(package.repoRef)
            let version = try XCTUnwrap(package.latestVersion, identity)
            XCTAssertTrue(DebianVersion.isValid(version), "\(identity) \(version)")
            XCTAssertEqual(package.latestMetadata?["status"], "install ok installed", identity)
            XCTAssertTrue(["arm64", "all"].contains(package.latestMetadata?["architecture"] ?? ""), identity)
        }
        // multi-line fields keep their continuation lines, joined by a space
        let bash = try XCTUnwrap(packages["bash"])
        XCTAssertEqual(bash.latestMetadata?["essential"], "yes")
        XCTAssertTrue(bash.latestMetadata?["description"]?.hasPrefix("GNU Bourne Again SHell Bash is an sh-compatible") ?? false)
        XCTAssertTrue(bash.latestMetadata?["depends"]?.contains("base-files") ?? false)
    }

    func testStatusFileRoundTripsThroughTheDatabase() async throws {
        let status = try TestEnvironment.fixture("installed-status")
        let path = Self.environment.appendingPathComponent("status-roundtrip").path
        try status.write(toFile: path, atomically: true, encoding: .utf8)
        let db = TestEnvironment.database()

        let snapshot = await PackageCenter.storeInstalled(from: path, into: db)
        let count = snapshot.list.count
        let read = await PackageCenter.readInstalled(at: path)
        let parsed = try XCTUnwrap(read)
        XCTAssertEqual(count, parsed.count, "Only actual dpkg records are stored")

        let stored = db.installed()
        XCTAssertEqual(stored.count, count)
        let byIdentity = Dictionary(uniqueKeysWithValues: stored.map { ($0.identity, $0) })
        // what the center answers from memory is what the database holds
        XCTAssertEqual(snapshot.packages, byIdentity)
        XCTAssertEqual(snapshot, InstalledSnapshot(reading: db))
        XCTAssertEqual(db.installedVersions(), byIdentity.compactMapValues(\.latestVersion))
        for (identity, package) in parsed {
            XCTAssertEqual(byIdentity[identity]?.latestVersion, package.latestVersion, identity)
            XCTAssertEqual(byIdentity[identity]?.latestMetadata, package.latestMetadata, identity)
        }
        XCTAssertNil(db.installed(identity: "firmware"))
        XCTAssertEqual(db.installed(identity: "apt")?.latestVersion, parsed["apt"]?.latestVersion)
    }

    /// An origin is the repository's package for what dpkg reports at that
    /// version, and nothing else: a source dpkg does not confirm is not
    /// recorded, and an origin dpkg stops confirming is dropped.
    func testOriginsFollowTheStatusFile() async throws {
        let status = try TestEnvironment.fixture("installed-status")
        let path = Self.environment.appendingPathComponent("status-origin").path
        try status.write(toFile: path, atomically: true, encoding: .utf8)
        let db = TestEnvironment.database()
        let read = await PackageCenter.readInstalled(at: path)
        let parsed = try XCTUnwrap(read)
        let aptVersion = try XCTUnwrap(parsed["apt"]?.latestVersion)
        let repo = try XCTUnwrap(URL(string: "https://repo.example/"))
        func source(_ identity: String, _ version: String, repo: URL? = repo) -> Package {
            Package(identity: identity, payload: [version: ["package": identity, "version": version, "filename": "./\(identity).deb"]], repoRef: repo)
        }
        let dpkgVersion = try XCTUnwrap(parsed["dpkg"]?.latestVersion)

        let snapshot = await PackageCenter.storeInstalled(from: path, into: db, installedFrom: [
            source("apt", aptVersion),
            source("apt-not-installed", "1.0"),
            source("bash", "0.0-not-what-dpkg-says"),
            source("dpkg", dpkgVersion, repo: nil), // a local .deb: nowhere to come back to
        ])
        // the origins the write kept, not the sources it was handed
        XCTAssertEqual(snapshot.origins, db.installOriginPackages())
        XCTAssertEqual(Set(snapshot.origins.keys), ["apt"])
        let origin = try XCTUnwrap(db.installOrigin(identity: "apt"))
        XCTAssertEqual(origin.repoRef, repo)
        XCTAssertEqual(origin.latestVersion, aptVersion)
        XCTAssertEqual(origin.obtainDownloadLink(), URL(string: "https://repo.example/apt.deb"))
        XCTAssertNil(db.installOrigin(identity: "apt-not-installed"))
        XCTAssertNil(db.installOrigin(identity: "bash"))
        XCTAssertNil(db.installOrigin(identity: "dpkg"))

        // a plain reload keeps the origin, a version change under it drops it
        _ = await PackageCenter.storeInstalled(from: path, into: db)
        XCTAssertNotNil(db.installOrigin(identity: "apt"))
        let changed = status.replacingOccurrences(of: "Version: \(aptVersion)\n", with: "Version: \(aptVersion)+1\n")
        XCTAssertNotEqual(changed, status)
        try changed.write(toFile: path, atomically: true, encoding: .utf8)
        _ = await PackageCenter.storeInstalled(from: path, into: db)
        XCTAssertNil(db.installOrigin(identity: "apt"))
    }

    // MARK: - VERSION ORDER

    private func versions() throws -> [String] {
        try TestEnvironment.fixture("versions-ascending")
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func testEveryRealVersionIsValid() throws {
        let versions = try versions()
        XCTAssertGreaterThan(versions.count, 1000)
        for version in versions {
            XCTAssertTrue(DebianVersion.isValid(version), version)
            XCTAssertEqual(DebianVersion.compare(version, version), 0, version)
        }
    }

    /// apt sorted the list, so every earlier entry is strictly less than
    /// every later one. Neighbours and a window of further pairs are
    /// checked both ways.
    func testAgreesWithAptOnTheSortedList() throws {
        let versions = try versions()
        var disagreements = [String]()
        for i in versions.indices {
            for j in (i + 1) ..< min(i + 8, versions.count) {
                let a = versions[i], b = versions[j]
                if DebianVersion.compare(a, b) >= 0 {
                    disagreements.append("\(a) < \(b)")
                }
                if DebianVersion.compare(b, a) <= 0 {
                    disagreements.append("\(b) > \(a)")
                }
            }
        }
        XCTAssertEqual(disagreements.count, 0, disagreements.prefix(20).joined(separator: "\n"))
    }

    /// Far apart pairs from a fixed seed, so the whole list is covered and
    /// not only its neighbours.
    func testAgreesWithAptOnDistantPairs() throws {
        let versions = try versions()
        var generator = SplitMix64(seed: 0xF1C7_0BE5)
        var disagreements = [String]()
        for _ in 0 ..< 20000 {
            let i = Int(generator.next() % UInt64(versions.count))
            let j = Int(generator.next() % UInt64(versions.count))
            guard i != j else { continue }
            let (low, high) = i < j ? (versions[i], versions[j]) : (versions[j], versions[i])
            if DebianVersion.compare(low, high) >= 0 || DebianVersion.compare(high, low) <= 0 {
                disagreements.append("\(low) < \(high)")
            }
        }
        XCTAssertEqual(disagreements.count, 0, disagreements.prefix(20).joined(separator: "\n"))
    }

    /// Sorting the list with our comparison must reproduce apt's order.
    func testSortReproducesAptOrder() throws {
        let versions = try versions()
        var generator = SplitMix64(seed: 0x50B7)
        var shuffled = versions
        for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
            shuffled.swapAt(i, Int(generator.next() % UInt64(i + 1)))
        }
        let sorted = shuffled.sorted { DebianVersion.compare($0, $1) < 0 }
        XCTAssertEqual(sorted, versions)
    }
}
