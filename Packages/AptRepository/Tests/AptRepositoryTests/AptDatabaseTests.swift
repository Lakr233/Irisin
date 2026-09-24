@testable import AptRepository
import Foundation
import WCDBSwift
import XCTest

/// A synthetic catalogue in a throwaway database, asked everything the
/// interface asks the index.
final class AptDatabaseTests: XCTestCase {
    private var db: AptDatabase!
    private var index: PackageIndex!

    static let repoA = URL(string: "https://a.example")!
    static let repoB = URL(string: "https://b.example")!

    override func setUp() {
        super.setUp()
        db = TestEnvironment.database()
        index = PackageIndex(db: db)
    }

    private func package(_ identity: String, _ version: String, repo: URL?, _ fields: [String: String] = [:]) -> Package {
        var meta = fields
        meta["package"] = identity
        meta["version"] = version
        meta["architecture"] = meta["architecture"] ?? "iphoneos-arm64"
        return Package(identity: identity, payload: [version: meta], repoRef: repo)
    }

    /// Two repositories: A with a few hundred packages plus named ones, B
    /// overlapping on `shared` with a newer version.
    private func seed() {
        var a = [String: Package]()
        for i in 0 ..< 300 {
            let id = "com.example.filler\(i)"
            a[id] = package(id, "1.\(i)", repo: Self.repoA, [
                "name": "Filler \(i)",
                "author": "Filler Author <f@example.com>",
                "section": i % 2 == 0 ? "Tweaks" : "Themes",
                "description": "filler package number \(i)",
            ])
        }
        a["com.example.shared"] = package("com.example.shared", "1.0", repo: Self.repoA, [
            "name": "Shared Thing", "author": "Alice <a@x.com>, Bob", "section": "Tweaks",
            "description": "a thing 红色日落 both repositories offer",
        ])
        a["com.example.provider"] = package("com.example.provider", "2.0", repo: Self.repoA, [
            "name": "Provider", "section": "System", "provides": "virtual-one, virtual-two (= 1.0)",
        ])
        a["com.example.armv7"] = package("com.example.armv7", "9.0", repo: Self.repoA, [
            "name": "Old Flavour", "section": "Tweaks", "architecture": "iphoneos-arm",
        ])
        db.replacePackages(of: Self.repoA, with: a)

        var b = [String: Package]()
        b["com.example.shared"] = package("com.example.shared", "1.1", repo: Self.repoB, [
            "name": "Shared Thing", "author": "Alice <a@x.com>, Bob", "section": "Tweaks",
        ])
        b["com.example.only-b"] = package("com.example.only-b", "0.1", repo: Self.repoB, [
            "name": "Only B", "author": "Carol", "section": "Utilities",
        ])
        db.replacePackages(of: Self.repoB, with: b)

        db.replaceInstalled([
            "com.example.shared": package("com.example.shared", "1.0", repo: nil),
            "com.example.filler1": package("com.example.filler1", "1.1", repo: nil),
            "firmware": package("firmware", "16.0", repo: nil),
        ])
    }

    func testSummaryAndSinglePackage() {
        seed()
        let summary = index.obtainPackageSummary(with: "com.example.shared")
        XCTAssertEqual(Set(summary.keys), [Self.repoA, Self.repoB])
        XCTAssertEqual(summary[Self.repoA]?.latestVersion, "1.0")
        XCTAssertEqual(summary[Self.repoB]?.latestVersion, "1.1")
        XCTAssertEqual(summary[Self.repoB]?.repoRef, Self.repoB)
        XCTAssertEqual(summary[Self.repoA]?.latestMetadata?["description"], "a thing 红色日落 both repositories offer")

        XCTAssertEqual(index.obtainPackage(with: "com.example.only-b", in: Self.repoB)?.latestVersion, "0.1")
        XCTAssertNil(index.obtainPackage(with: "com.example.only-b", in: Self.repoA))
        XCTAssertEqual(index.obtainAllPackageIdentity().count, 304)
    }

    /// the batch a list asks for: one repository's packages among the
    /// identities, nothing another repository offers
    func testPackagesByIdentities() {
        seed()
        let found = db.packages(identities: ["com.example.shared", "com.example.only-b", "com.example.none"], in: Self.repoB)
        XCTAssertEqual(Set(found.map(\.identity)), ["com.example.shared", "com.example.only-b"])
        XCTAssertEqual(found.first { $0.identity == "com.example.shared" }?.latestVersion, "1.1")
        XCTAssertEqual(db.packages(identities: ["com.example.only-b"], in: Self.repoA), [])
        XCTAssertEqual(db.packages(identities: [], in: Self.repoA), [])
    }

    /// the installed side answered from memory is the database's answer
    func testInstalledSnapshotAnswersAsTheDatabase() {
        seed()
        var held: PackageIndex = index
        held.installedSnapshot = InstalledSnapshot(reading: db)
        XCTAssertEqual(held.obtainInstalledPackageList(), index.obtainInstalledPackageList().sorted { $0.identity < $1.identity })
        for identity in ["com.example.shared", "com.example.filler1", "com.example.only-b"] {
            XCTAssertEqual(
                held.obtainPackageInstallationInfo(with: identity)?.representObject,
                index.obtainPackageInstallationInfo(with: identity)?.representObject,
                identity
            )
            XCTAssertEqual(held.obtainInstallOrigin(of: identity), index.obtainInstallOrigin(of: identity), identity)
        }
        XCTAssertEqual(db.installedVersions(), ["com.example.shared": "1.0", "com.example.filler1": "1.1", "firmware": "16.0"])
    }

    func testRepositoryListingAndSections() {
        seed()
        XCTAssertEqual(index.obtainPackageList(in: Self.repoA).count, 303)
        XCTAssertEqual(index.obtainPackageList(in: Self.repoB).count, 2)
        let counts = index.obtainSectionCounts(in: Self.repoA)
        XCTAssertEqual(counts["Tweaks"], 150 + 2)
        XCTAssertEqual(counts["Themes"], 150)
        XCTAssertEqual(counts["System"], 1)
        XCTAssertEqual(index.obtainPackageList(in: Self.repoA, section: "System").map(\.identity), ["com.example.provider"])
    }

    func testAuthors() {
        seed()
        XCTAssertEqual(Set(index.obtainAuthorList()), ["Filler Author", "Alice, Bob", "Carol"])
        XCTAssertEqual(index.obtainPackage(by: "Alice, Bob").count, 2)
        XCTAssertEqual(index.obtainAvailablePackageList(writtenBy: "Alice, Bob"), ["com.example.shared"])
        XCTAssertEqual(index.obtainAvailablePackageList(writtenBy: "Filler Author").count, 300)
    }

    func testVirtualPackages() {
        seed()
        XCTAssertEqual(index.obtainVirtualPackageReference(withIdentity: "virtual-one"), ["com.example.provider"])
        XCTAssertEqual(index.obtainVirtualPackageReference(withIdentity: "virtual-two"), ["com.example.provider"])
        XCTAssertEqual(index.obtainVirtualPackageReference(withIdentity: "nothing"), [])
    }

    func testInstalledAndUpdates() {
        seed()
        XCTAssertEqual(index.obtainInstalledPackageList().count, 3)
        let info = index.obtainPackageInstallationInfo(with: "com.example.shared")
        XCTAssertEqual(info?.version, "1.0")
        XCTAssertNil(info?.representObject.repoRef)
        XCTAssertNil(index.obtainPackageInstallationInfo(with: "com.example.only-b"))

        // an update comes from the repository the package was installed
        // from, and from nowhere else: with no origin any repository's newer
        // version is one, from A there is none because A has nothing newer,
        // from B there is B's
        let installed = Dictionary(uniqueKeysWithValues: index.obtainInstalledPackageList().map { ($0.identity, $0) })
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.shared", version: "1.0").map(\.repoRef), [Self.repoB])
        db.replaceInstalled(installed, installedFrom: [package("com.example.shared", "1.0", repo: Self.repoA)])
        XCTAssertEqual(index.obtainInstallOrigin(of: "com.example.shared")?.repoRef, Self.repoA)
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.shared", version: "1.0").count, 0)
        db.replaceInstalled(installed, installedFrom: [package("com.example.shared", "1.0", repo: Self.repoB)])
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.shared", version: "1.0").map(\.repoRef), [Self.repoB])
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.shared", version: "1.1").count, 0)
        XCTAssertEqual(db.installOrigins(), ["com.example.shared": Self.repoB])
        // the armv7 flavour never qualifies on this device
        db.replaceInstalled(
            installed.merging(["com.example.armv7": package("com.example.armv7", "1.0", repo: nil)]) { $1 },
            installedFrom: [package("com.example.armv7", "1.0", repo: Self.repoA)]
        )
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.armv7", version: "1.0").count, 0)
        // a record with a version for this device under a newer one for
        // another offers the first, and the second only once adapted
        // updates are on and something adapts it
        let mixed = Package(identity: "com.example.mixed", payload: [
            "1.5": ["package": "com.example.mixed", "version": "1.5", "architecture": "iphoneos-arm64"],
            "2.0": ["package": "com.example.mixed", "version": "2.0", "architecture": "iphoneos-arm"],
        ], repoRef: Self.repoB)
        db.replacePackages(of: Self.repoB, with: ["com.example.mixed": mixed])
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.mixed", version: "1.0").map(\.latestVersion), ["1.5"])
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.mixed", version: "1.5").count, 0)
        index.blockedUpdateTable = ["com.example.shared"]
        XCTAssertEqual(index.obtainUpdateForPackage(with: "com.example.shared", version: "0").count, 0)
    }

    func testLocalReinstallClearsThePreviousRepositoryAtTheSameVersion() {
        let installed = package("test.local", "1", repo: nil)
        let remote = package(installed.identity, "1", repo: Self.repoA)
        let packages = [installed.identity: installed]
        db.replaceInstalled(packages, installedFrom: [remote])
        XCTAssertEqual(index.obtainInstallOrigin(of: installed.identity), remote)

        // An ordinary status refresh must preserve the recorded source.
        db.replaceInstalled(packages)
        XCTAssertEqual(db.installOrigins()[installed.identity], Self.repoA)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("local.deb")
        let local = package(installed.identity, "1", repo: nil, ["filename": file.absoluteString])
        db.replaceInstalled(packages, installedFrom: [local])
        XCTAssertNil(index.obtainInstallOrigin(of: installed.identity))
        XCTAssertTrue(db.installOrigins().isEmpty)
    }

    func testADpkgRowIsDescribedByItsOrigin() {
        let installed = package("test.described", "1", repo: nil)
        let remote = package(installed.identity, "1", repo: Self.repoA, ["icon": "https://example.com/icon.png"])
        db.replaceInstalled([installed.identity: installed])
        XCTAssertEqual(index.obtainDescription(of: installed), installed)

        db.replaceInstalled([installed.identity: installed], installedFrom: [remote])
        XCTAssertEqual(index.obtainDescription(of: installed), remote)
        XCTAssertEqual(index.obtainInstallOrigins(), [installed.identity: remote])
        // a repository's package is its own description, whatever is installed
        let other = package(installed.identity, "2", repo: Self.repoB)
        XCTAssertEqual(index.obtainDescription(of: other), other)

        // dpkg moved on without us: the origin is gone and the row stands alone
        let newer = package(installed.identity, "2", repo: nil)
        db.replaceInstalled([newer.identity: newer])
        XCTAssertEqual(index.obtainDescription(of: newer), newer)
    }

    func testRefreshReplacesOnlyThatRepository() {
        seed()
        db.replacePackages(of: Self.repoB, with: [
            "com.example.fresh": package("com.example.fresh", "1", repo: Self.repoB, ["name": "Fresh"]),
        ])
        XCTAssertEqual(index.obtainPackageList(in: Self.repoB).map(\.identity), ["com.example.fresh"])
        XCTAssertEqual(index.obtainPackageSummary(with: "com.example.shared").count, 1)
        XCTAssertEqual(index.obtainPackageList(in: Self.repoA).count, 303)
        XCTAssertEqual(index.search("Only B").count, 0)
        XCTAssertEqual(index.search("Fresh").map(\.identity), ["com.example.fresh"])

        db.deletePackages(of: Self.repoA)
        XCTAssertEqual(index.obtainPackageList(in: Self.repoA).count, 0)
        XCTAssertEqual(index.obtainVirtualPackageReference(withIdentity: "virtual-one"), [])
        XCTAssertEqual(index.search("Filler").count, 0)
    }

    /// Package rows written before they kept their search rowid: a refresh
    /// of their repository still drops its search rows, and no other's, and
    /// the rows it writes keep theirs.
    func testSearchRowsWrittenBeforeTheirRowidWasKept() throws {
        let path = TestEnvironment.root.appendingPathComponent("\(UUID().uuidString).db")
        db = AptDatabase(at: path)
        index = PackageIndex(db: db)
        seed()
        try Database(at: path).exec(
            StatementUpdate()
                .update(table: AptDatabase.Table.package)
                .set(PackageRow.Properties.searchRowid)
                .to(LiteralValue(nil))
        )

        db.replacePackages(of: Self.repoA, with: [
            "com.example.fresh": package("com.example.fresh", "1", repo: Self.repoA, ["name": "Fresh"]),
        ])
        XCTAssertEqual(index.search("Filler").count, 0)
        XCTAssertEqual(index.search("Fresh").map(\.identity), ["com.example.fresh"])
        XCTAssertEqual(index.search("Only B").map(\.identity), ["com.example.only-b"])

        db.deletePackages(of: Self.repoA)
        XCTAssertEqual(index.search("Fresh").count, 0)
        XCTAssertEqual(index.search("Shared Thing").map(\.repository), [Self.repoB])
        db.deletePackages(of: Self.repoB)
        XCTAssertEqual(index.search("Shared Thing").count, 0)
    }

    func testSearch() {
        seed()
        let shared = index.search("shared thing")
        XCTAssertEqual(Set(shared.map(\.repository)), [Self.repoA, Self.repoB])
        XCTAssertEqual(shared.first?.name, "Shared Thing")
        // a prefix of a word, any case
        XCTAssertEqual(index.search("SHAR").count, 2)
        // every word must match
        XCTAssertEqual(index.search("shared nothing").count, 0)
        // author, section, description and identity are searchable
        XCTAssertEqual(index.search("carol").map(\.identity), ["com.example.only-b"])
        XCTAssertEqual(index.search("utilities").map(\.identity), ["com.example.only-b"])
        XCTAssertEqual(index.search("com.example.provider").map(\.identity), ["com.example.provider"])
        XCTAssertEqual(index.search("number 299").map(\.identity), ["com.example.filler299"])
        // every word is a prefix: 7, 70 ... 79
        XCTAssertEqual(index.search("number 7").count, 11)
        // CJK, one token per character, as a phrase; only A's copy has a description
        XCTAssertEqual(index.search("日落").map(\.identity), ["com.example.shared"])
        XCTAssertEqual(index.search("红色日落").map(\.repository), [Self.repoA])
        XCTAssertEqual(index.search("落日").count, 0)
        // the limit, and a quote that must not break the query
        XCTAssertEqual(index.search("filler", limit: 10).count, 10)
        XCTAssertEqual(index.search("\"filler\"").count, 200)
        XCTAssertEqual(index.search("   ").count, 0)
    }

    func testRepositoryRoundTrip() throws {
        let source = RepositorySource(url: Self.repoA, distribution: "1900", components: ["main", "extra"])
        var repository = Repository(source: source)
        repository.avatar = Data([1, 2, 3])
        repository.metaRelease = ["label": "Repo A"]
        repository.attachment[.nickNamePinned] = "true"
        repository.paymentInfo[.endpoint] = "https://pay.example"
        repository.packageCount = 42
        repository.lastUpdatePackage = Date(timeIntervalSince1970: 1000)
        db.save(repository)
        db.save(Repository(source: RepositorySource(url: Self.repoB)))

        let loaded = db.repositories()
        XCTAssertEqual(loaded.count, 2)
        let a = try XCTUnwrap(loaded.first { $0.url == Self.repoA })
        XCTAssertEqual(a.distribution, "1900")
        XCTAssertEqual(a.components, ["main", "extra"])
        XCTAssertEqual(a.avatar, Data([1, 2, 3]))
        XCTAssertEqual(a.metaRelease["label"], "Repo A")
        XCTAssertEqual(a.attachment[.nickNamePinned], "true")
        XCTAssertEqual(a.endpoint?.absoluteString, "https://pay.example")
        XCTAssertEqual(a.packageCount, 42)
        XCTAssertEqual(a.lastUpdatePackage, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(a.source, source)

        // a second save is an update, not a duplicate
        repository.packageCount = 43
        db.save(repository)
        XCTAssertEqual(db.repositories().first { $0.url == Self.repoA }?.packageCount, 43)

        db.delete(repository: Self.repoA)
        XCTAssertEqual(db.repositories().map(\.url), [Self.repoB])
    }

    func testTraces() async {
        seed()
        let day1 = Date(timeIntervalSince1970: 86400)
        let first = await PackageCenter.trace(db, disableTableTrace: false, initialInstall: [Self.repoA: true, Self.repoB: false], date: day1)
        XCTAssertTrue(first)
        // A is on its initial load: its packages are recorded silently; B is
        // not, so what only B brought counts as an update
        XCTAssertNil(index.obtainLastModification(for: "com.example.filler1", and: .repo))
        XCTAssertEqual(index.obtainLastModification(for: "com.example.only-b", and: .repo), day1)
        // shared is newest in B, and B is past its initial load
        XCTAssertEqual(index.obtainLastModification(for: "com.example.shared", and: .repo), day1)
        XCTAssertEqual(index.obtainLastModification(for: "com.example.shared", and: .install), day1)
        XCTAssertEqual(index.obtainLastModification(for: "firmware", and: .install), day1)
        XCTAssertEqual(Set(index.obtainRecentUpdatedList()[day1]?.map(\.0) ?? []), ["com.example.only-b", "com.example.shared"])

        // nothing changed: nothing moves
        let day2 = Date(timeIntervalSince1970: 2 * 86400)
        _ = await PackageCenter.trace(db, disableTableTrace: false, initialInstall: [Self.repoA: false, Self.repoB: false], date: day2)
        XCTAssertEqual(index.obtainLastModification(for: "com.example.only-b", and: .repo), day1)
        XCTAssertNil(index.obtainLastModification(for: "com.example.filler1", and: .repo))

        // A ships a newer filler1 and the user upgrades shared
        db.replacePackages(of: Self.repoA, with: [
            "com.example.filler1": package("com.example.filler1", "2.0", repo: Self.repoA, ["name": "Filler 1"]),
        ])
        db.replaceInstalled([
            "com.example.shared": package("com.example.shared", "1.1", repo: nil),
            "firmware": package("firmware", "16.0", repo: nil),
        ])
        let day3 = Date(timeIntervalSince1970: 3 * 86400)
        _ = await PackageCenter.trace(db, disableTableTrace: false, initialInstall: [Self.repoA: false, Self.repoB: false], date: day3)
        XCTAssertEqual(index.obtainLastModification(for: "com.example.filler1", and: .repo), day3)
        XCTAssertEqual(index.obtainLastModification(for: "com.example.shared", and: .install), day3)
        XCTAssertEqual(index.obtainLastModification(for: "firmware", and: .install), day1)
        // gone from the repositories, gone from the trace
        XCTAssertNil(index.obtainLastModification(for: "com.example.provider", and: .repo))
        XCTAssertNil(index.obtainLastModification(for: "com.example.filler1", and: .install))
        let recent = index.obtainRecentUpdatedList()
        XCTAssertEqual(recent[day3]?.map(\.0), ["com.example.filler1"])
        XCTAssertEqual(recent[day3]?.first?.1, Self.repoA)
    }

    // MARK: - Sources

    func testSourceLines() {
        XCTAssertEqual(RepositorySource(line: "https://a.example/")?.line, "https://a.example")
        XCTAssertEqual(RepositorySource(line: "a.example")?.url.absoluteString, "https://a.example")
        let dist = RepositorySource(line: "deb https://apt.procurs.us/ 1900 main extra")
        XCTAssertEqual(dist?.url.absoluteString, "https://apt.procurs.us")
        XCTAssertEqual(dist?.distribution, "1900")
        XCTAssertEqual(dist?.components, ["main", "extra"])
        XCTAssertEqual(dist?.line, "deb https://apt.procurs.us 1900 main extra")
        XCTAssertEqual(RepositorySource(line: "https://x.example ./")?.components, [])
        XCTAssertEqual(RepositorySource(line: "https://x.example ./")?.distribution, "./")
        XCTAssertNil(RepositorySource(line: "deb https://x.example stable"))
        XCTAssertNil(RepositorySource(line: "deb https://x.example ./ main"))
        XCTAssertNil(RepositorySource(line: "deb"))
        XCTAssertNil(RepositorySource(line: "https://"))
        XCTAssertNil(RepositorySource(line: ""))
        XCTAssertFalse(RepositorySource(url: Self.repoA, distribution: "", components: []).isValid)
        XCTAssertFalse(RepositorySource(url: Self.repoA, distribution: "stable", components: [""]).isValid)
        XCTAssertTrue(RepositorySource(url: Self.repoA, distribution: "stable", components: ["main"]).isValid)
    }

    func testIndexUrls() {
        let flat = Repository(source: RepositorySource(url: Self.repoA))
        XCTAssertEqual(flat.metaReleaseUrl.absoluteString, "https://a.example/Release")
        XCTAssertEqual(flat.metaPackageCandidates.map { $0.map(\.absoluteString) }, [["https://a.example/Packages"]])

        let flatSuite = Repository(source: RepositorySource(url: Self.repoA, distribution: "ios/"))
        XCTAssertEqual(flatSuite.metaReleaseUrl.absoluteString, "https://a.example/ios/Release")
        XCTAssertEqual(flatSuite.metaPackageCandidates.map { $0.map(\.absoluteString) }, [["https://a.example/ios/Packages"]])

        let dist = Repository(source: RepositorySource(url: Self.repoA, distribution: "1900", components: ["main", "extra"]))
        XCTAssertEqual(dist.metaReleaseUrl.absoluteString, "https://a.example/dists/1900/Release")
        XCTAssertEqual(dist.metaPackageCandidates.map { $0.map(\.absoluteString) }, [[
            "https://a.example/dists/1900/main/binary-iphoneos-arm64/Packages",
            "https://a.example/dists/1900/extra/binary-iphoneos-arm64/Packages",
        ]])
        XCTAssertEqual(dist.avatarUrls.map(\.absoluteString), [
            "https://a.example/CydiaIcon.png",
            "https://a.example/dists/1900/CydiaIcon.png",
        ])
        XCTAssertEqual(flat.avatarUrls.map(\.absoluteString), ["https://a.example/CydiaIcon.png"])
    }
}
