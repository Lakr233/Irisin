@testable import AptRepository
import Foundation
import Testing

/// A repository deleted while its refresh is in flight, through the center
/// itself: the fetch is cancelled rather than waited for, and a repository
/// added again at the same address gets a refresh of its own.
@MainActor @Suite(.serialized) struct RepositoryDeletionTests {
    private static let index = Data("Package: a\nVersion: 1\nArchitecture: iphoneos-arm64\n".utf8)

    /// Every path the refresh asks for first, answered with silence.
    private static let silence: [String: StubServer.Behavior] = [
        "/Release": .hang, "/Packages": .hang, "/Packages.xz": .hang,
        "/Packages.bz2": .hang, "/Packages.gz": .hang,
        "/payment_endpoint": .hang, "/sileo-featured.json": .hang,
    ]

    private func until(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The server never answers, so only a cancel ends the fetch before the
    /// request's own timeout.
    @Test func deletingCancelsTheFetch() async {
        _ = TestEnvironment.root
        let center = RepositoryCenter.default
        StubServer.serve([:], on: "deleted-in-flight.test", behaving: Self.silence)
        let url = URL(string: "https://deleted-in-flight.test")!
        center.registerRepository(RepositorySource(url: url))
        #expect(await until(3) { StubServer.requests(to: "deleted-in-flight.test").contains("/Release") })

        center.deleteRepository(withUrl: url)
        #expect(center.obtainUpdateRemain() == 0)
        #expect(center.updateState(withUrl: url) == .idle)

        #expect(await until(3) { !center.currentlyInUpdate.contains(url) })
        #expect(center.repositories[url] == nil)
        #expect(AptDatabase.shared.packages(in: url, section: nil).isEmpty)
    }

    /// Deleted and added again before the first fetch ended: the new one is
    /// queued behind it, runs once it is gone, and keeps what it read.
    @Test func addedAgainIsRefreshedOnItsOwn() async {
        _ = TestEnvironment.root
        let center = RepositoryCenter.default
        StubServer.serve([:], on: "added-again.test", behaving: Self.silence)
        let url = URL(string: "https://added-again.test")!
        center.registerRepository(RepositorySource(url: url))
        // the first fetch is waiting on the server, not about to ask it
        #expect(await until(3) { StubServer.requests(to: "added-again.test").contains("/Release") })
        center.deleteRepository(withUrl: url)

        StubServer.serve(["/Packages": Self.index, "/Packages.xz": Self.index], on: "added-again.test")
        center.registerRepository(RepositorySource(url: url))
        #expect(center.isRepositoryPreparedForUpdate(withUrl: url))

        #expect(await until(5) { center.repositories[url]?.packageCount == 1 && !center.currentlyInUpdate.contains(url) })
        #expect(center.obtainUpdateRemain() == 0)
        #expect(AptDatabase.shared.packages(in: url, section: nil).count == 1)
        center.deleteRepository(withUrl: url)
    }
}
