@testable import AptRepository
import CryptoKit
import Foundation
import Testing

/// One refresh against a stubbed server: what the update does with an index
/// the Release disowns, a Release older than the one it has, and an answer
/// that is no index at all.
@Suite(.serialized) struct UpdateHandoffTests {
    private static let current = Data("Package: a\nVersion: 2\nArchitecture: iphoneos-arm64\n".utf8)
    private static let stale = Data("Package: a\nVersion: 1\nArchitecture: iphoneos-arm64\n".utf8)

    private static func release(of index: Data, date: String) -> Data {
        let digest = SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined()
        return Data("""
        Origin: Example
        Date: \(date)
        SHA256:
         \(digest) \(index.count) Packages
         \(digest) \(index.count) Packages.xz

        """.utf8)
    }

    private static let morning = "Sat, 19 Sep 2026 11:54:05 +0000"
    private static let evening = "Sat, 19 Sep 2026 18:21:09 +0000"

    private func update(
        host: String,
        serving files: [String: Data],
        storedRelease: [String: String] = [:],
        indexes: [[String]] = [["Packages"]],
        behaving: [String: StubServer.Behavior] = [:],
        suite: (distribution: String, components: [String], architectures: [String], installable: Set<String>)? = nil,
        configure: (inout RepositoryCenter.UpdateRequest) -> Void = { _ in }
    ) async -> RepositoryCenter.UpdateOutcome {
        _ = TestEnvironment.root
        StubServer.serve(files, on: host, behaving: behaving)
        let url = URL(string: "https://\(host)")!
        var request = RepositoryCenter.UpdateRequest(
            url: url,
            avatarUrls: [],
            releaseUrl: url.appendingPathComponent("Release"),
            packageCandidates: indexes.map { $0.map(url.appendingPathComponent) },
            preferredSearchPath: "xz",
            availableSearchPath: ["bz2", "", "xz", "gz"],
            storedRelease: storedRelease,
            networking: NetworkingConfiguration(headers: [:], timeout: 5, verboseLogging: false),
            suiteUrl: url,
            distribution: suite?.distribution,
            components: suite?.components ?? []
        )
        if let suite {
            request.architectures = suite.architectures
            request.installable = suite.installable
        }
        configure(&request)
        return await RepositoryCenter.performUpdate(request) { _, _ in }
    }

    /// apt.owngoal.dev on 2026-09-19: the Release and `Packages` of the
    /// evening beside the morning's `Packages.xz`.
    @Test func staleSpellingGivesWayAndIsStillTheOneRemembered() async {
        let outcome = await update(host: "stale-xz.test", serving: [
            "/Release": Self.release(of: Self.current, date: Self.evening),
            "/Packages": Self.current,
            "/Packages.xz": Self.stale,
        ])
        #expect(outcome.packages?.values.first?.latestVersion == "2")
        #expect(outcome.searchPath == nil)
    }

    @Test func everySpellingStaleLeavesTheCatalogue() async {
        let outcome = await update(host: "all-stale.test", serving: [
            "/Release": Self.release(of: Self.current, date: Self.evening),
            "/Packages": Self.stale,
            "/Packages.xz": Self.stale,
        ])
        #expect(outcome.packages == nil)
        #expect(!outcome.succeeded)
    }

    @Test func releaseOlderThanTheOneKnownJudgesNothing() async {
        let outcome = await update(
            host: "stale-release.test",
            serving: [
                "/Release": Self.release(of: Self.stale, date: Self.morning),
                "/Packages.xz": Self.current,
            ],
            storedRelease: ["date": Self.evening]
        )
        #expect(outcome.release == nil)
        #expect(outcome.packages?.values.first?.latestVersion == "2")
        #expect(outcome.searchPath == "xz")
    }

    /// A suite with a directory per architecture, both of which install
    /// here: one catalogue, the build of each version chosen across them,
    /// and a directory that is not there costs nothing but its request.
    @Test func oneEntrysIndexesAreReadAsOneCatalogue() async {
        let own = "main/binary-iphoneos-arm64/Packages"
        let other = "main/binary-other/Packages"
        let files = [
            "/\(own).xz": Data("""
            Package: shared
            Version: 1
            Architecture: iphoneos-arm64
            Filename: own.deb

            Package: only-own
            Version: 1
            Architecture: iphoneos-arm64
            """.utf8),
            "/\(other).xz": Data("""
            Package: shared
            Version: 1
            Architecture: all
            Filename: other.deb

            Package: shared
            Version: 2
            Architecture: all

            Package: only-other
            Version: 1
            Architecture: all
            """.utf8),
        ]
        let outcome = await update(host: "two-arch.test", serving: files, indexes: [[own, other], ["never/Packages"]])
        #expect(outcome.packages?.keys.sorted() == ["only-other", "only-own", "shared"])
        #expect(outcome.packages?["shared"]?.payload["1"]?["filename"] == "own.deb")
        #expect(outcome.packages?["shared"]?.latestVersion == "2")
        #expect(outcome.searchPath == "xz")

        let alone = await update(host: "one-arch.test", serving: files.filter { $0.key.contains("other") }, indexes: [[own, other]])
        #expect(alone.packages?.keys.sorted() == ["only-other", "shared"])
    }

    /// The Release lists both directories and the server has one: the two
    /// are not read together, and the one that is there is read on its own
    /// before anything built for another bootstrap is.
    @Test func aDirectoryTheReleaseListsAndTheServerLacksLeavesTheOther() async {
        let own = "main/binary-iphoneos-arm64e/Packages"
        let other = "main/binary-iphoneos-arm64/Packages"
        let legacy = "main/binary-iphoneos-arm/Packages"
        let index = Data("Package: adaptable\nVersion: 1\nArchitecture: iphoneos-arm64\n".utf8)
        let rootful = Data("Package: rootful\nVersion: 1\nArchitecture: iphoneos-arm\n".utf8)
        let digest = SHA256.hash(data: index).map { String(format: "%02x", $0) }.joined()
        let release = Data("""
        Origin: Example
        Date: \(Self.evening)
        SHA256:
         \(digest) \(index.count) \(own)
         \(digest) \(index.count) \(other)

        """.utf8)
        let outcome = await update(
            host: "half-published.test",
            serving: ["/Release": release, "/\(other)": index, "/\(legacy)": rootful],
            indexes: [[own, other], [own], [other], [legacy]],
            suite: ("stable", ["main"], ["iphoneos-arm64e", "iphoneos-arm64", "iphoneos-arm"], ["iphoneos-arm64e", "iphoneos-arm64"])
        )
        #expect(outcome.packages?.keys.sorted() == ["adaptable"])
    }

    @Test func pageThatIsNoIndexReplacesNothing() async {
        let page = Data("<html><body>Sign in to this network</body></html>".utf8)
        let outcome = await update(host: "portal.test", serving: [
            "/Release": page, "/Packages": page, "/Packages.xz": page, "/Packages.bz2": page, "/Packages.gz": page,
            "/payment_endpoint": page, "/sileo-featured.json": page,
        ])
        #expect(outcome.packages == nil)
        #expect(!outcome.succeeded)
    }

    @Test func serverThatDoesNotAnswerForgetsNothing() async {
        let outcome = await update(host: "down.test", serving: [:])
        guard case .absent = outcome.paymentEndpoint else {
            Issue.record("a 404 for payment_endpoint is the repository saying it has none")
            return
        }
        StubServer.fail(host: "offline.test")
        let offline = await update(host: "offline.test", serving: [:])
        // a device with no network says nothing about the host
        #expect(offline.report?.issues == [.unreachable])
        #expect(!offline.hostUnreachable)
        guard case .unanswered = offline.paymentEndpoint, case .unanswered = offline.featured else {
            Issue.record("a request that failed says nothing about what the repository has")
            return
        }
    }

    /// A host that answers nothing costs the Release and the preferred index
    /// and nothing else: no other spelling or entry is knocked on, and the
    /// optional parts are let go at once.
    @Test func unreachableHostSkipsProbing() async {
        StubServer.fail(host: "blackhole.test", with: .timedOut)
        let started = Date()
        let outcome = await update(
            host: "blackhole.test",
            serving: [:],
            indexes: [["Packages"], ["other/Packages"]]
        )
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(outcome.packages == nil)
        #expect(outcome.report?.issues == [.unreachable])
        #expect(outcome.hostUnreachable)
        let asked = StubServer.requests(to: "blackhole.test")
        #expect(asked.contains("/Release"))
        #expect(asked.contains("/Packages.xz"))
        #expect(!asked.contains { $0.hasPrefix("/other") || $0 == "/Packages.bz2" || $0 == "/Packages" })
    }

    /// mtac.app: a Release with its digests listed over and over. Its name
    /// is read, its packages are, and the report says the Release is bad.
    @Test func releaseWithDuplicatedDigestsStillNamesTheRepository() async throws {
        let outcome = await update(host: "mtac.test", serving: [
            "/Release": Data(try TestEnvironment.fixture("mtac-release").utf8),
            "/Packages.xz": Self.current,
        ])
        #expect(outcome.release?["label"] == "MTAC's Repo")
        #expect(outcome.packages?.values.first?.latestVersion == "2")
        #expect(outcome.report?.issues == [.releaseMalformed])
    }

    @Test func healthyRefreshHasNoIssues() async {
        let outcome = await update(host: "healthy.test", serving: [
            "/Release": Self.release(of: Self.current, date: Self.evening),
            "/Packages.xz": Self.current,
        ])
        #expect(outcome.succeeded)
        #expect(outcome.report?.issues == [])
    }

    @Test func brokenServerIsTheServersError() async {
        let outcome = await update(host: "broken.test", serving: [:], behaving: [
            "/Release": .status(503), "/Packages.xz": .status(503),
        ])
        #expect(outcome.packages == nil)
        #expect(outcome.report?.issues == [.serverError(503)])
        #expect(!outcome.hostUnreachable)
    }

    @Test func serverWithNothingForThisDevice() async {
        let outcome = await update(host: "empty.test", serving: [
            "/Release": Self.release(of: Self.current, date: Self.evening),
        ])
        #expect(outcome.report?.issues == [.noIndex])
    }

    @Test func indexTheReleaseDoesNotListIsUnverified() async {
        let digest = String(repeating: "a", count: 64)
        let outcome = await update(host: "unlisted.test", serving: [
            "/Release": Data("Origin: Example\nSHA256:\n \(digest) 12 Packages.bz2\n".utf8),
            "/Packages.xz": Self.current,
        ])
        #expect(outcome.succeeded)
        #expect(outcome.report?.issues == [.indexUnverified])
        let silent = await update(host: "no-digests.test", serving: [
            "/Release": Data("Origin: Example\n".utf8),
            "/Packages.xz": Self.current,
        ])
        #expect(silent.report?.issues == [])
    }

    /// An icon or a payment endpoint that never answers does not hold the
    /// catalogue up past its grace, and what the repository had stays.
    @Test func optionalPartsDoNotHoldTheCatalogue() async {
        let started = Date()
        let outcome = await update(
            host: "slow-extras.test",
            serving: ["/Packages.xz": Self.current],
            behaving: ["/payment_endpoint": .hang, "/sileo-featured.json": .hang]
        ) { request in
            request.optionalGrace = 0.3
            request.optionalBudget = 5
        }
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(outcome.succeeded)
        guard case .unanswered = outcome.paymentEndpoint, case .unanswered = outcome.featured else {
            Issue.record("a part given up on is unanswered, and what was remembered stays")
            return
        }
    }

    /// The Release lists `Packages` and `Packages.bz2`; the preferred `.xz`
    /// is there too, and not what it vouches for. A listed spelling is read
    /// and remembered, and the refresh has nothing to report.
    @Test func spellingTheReleaseListsIsPreferred() async {
        let digest = SHA256.hash(data: Self.current).map { String(format: "%02x", $0) }.joined()
        let release = Data("""
        Origin: Example
        SHA256:
         \(digest) \(Self.current.count) Packages
         \(digest) \(Self.current.count) Packages.bz2

        """.utf8)
        let outcome = await update(host: "old-tool.test", serving: [
            "/Release": release, "/Packages.xz": Self.current, "/Packages.bz2": Self.current, "/Packages": Self.current,
        ])
        #expect(outcome.succeeded)
        #expect(outcome.searchPath == "bz2" || outcome.searchPath == "")
        #expect(outcome.report?.issues == [])
    }

    /// The Release answered and the index timed out: the connection, not a
    /// server with nothing for this device.
    @Test func indexThatTimedOutIsNotMissing() async {
        let outcome = await update(host: "slow-index.test", serving: [
            "/Release": Self.release(of: Self.current, date: Self.evening),
        ], behaving: [
            "/Packages.xz": .fail(.timedOut), "/Packages.bz2": .fail(.timedOut),
            "/Packages": .fail(.timedOut), "/Packages.gz": .fail(.timedOut),
        ])
        #expect(outcome.packages == nil)
        #expect(outcome.report?.issues == [.unreachable])
        #expect(!outcome.hostUnreachable)
    }

    /// The index came and the Release timed out: a hiccup, the Release kept
    /// is kept, and nothing is reported missing.
    @Test func releaseThatTimedOutBesideAnIndexIsNoIssue() async {
        let outcome = await update(
            host: "slow-release.test",
            serving: ["/Packages.xz": Self.current],
            behaving: ["/Release": .fail(.timedOut)]
        )
        #expect(outcome.succeeded)
        #expect(outcome.release == nil)
        #expect(outcome.report?.issues == [])
    }
}
