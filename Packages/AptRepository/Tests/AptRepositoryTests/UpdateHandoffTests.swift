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
        suite: (distribution: String, components: [String], architectures: [String], installable: Set<String>)? = nil
    ) async -> RepositoryCenter.UpdateOutcome {
        _ = TestEnvironment.root
        StubServer.serve(files, on: host)
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
        guard case .unanswered = offline.paymentEndpoint, case .unanswered = offline.featured else {
            Issue.record("a request that failed says nothing about what the repository has")
            return
        }
    }
}

/// Answers `URLSession.shared` for the hosts it was given: a file, 404 for
/// anything else, or no answer at all.
final class StubServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var files = [String: [String: Data]]()
    private nonisolated(unsafe) static var failing = Set<String>()
    private nonisolated(unsafe) static var registered = false

    static func serve(_ served: [String: Data], on host: String) {
        lock.withLock {
            // `fail(host:)` comes first for a host that is to stay silent
            files[host] = served
            if !registered {
                registered = true
                URLProtocol.registerClass(StubServer.self)
            }
        }
    }

    static func fail(host: String) {
        lock.withLock { _ = failing.insert(host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { files[host] != nil || failing.contains(host) }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let (body, fails) = Self.lock.withLock { (Self.files[host]?[url.path], Self.failing.contains(host)) }
        if fails {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
