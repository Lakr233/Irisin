@testable import AptRepository
import Foundation
import Testing

/// Downloads against a stubbed server: what each failure is called, and
/// which of them the refresh queue's watchdog stops.
@Suite(.serialized) struct DownloadWatchdogTests {
    private static let networking = NetworkingConfiguration(headers: [:], timeout: 30, verboseLogging: false)

    @Test func failuresAreToldApart() async {
        _ = TestEnvironment.root
        StubServer.serve(["/file": Data("x".utf8)], on: "kinds.test", behaving: ["/broken": .status(503)])
        StubServer.fail(host: "refused.test", with: .cannotConnectToHost)
        func download(_ address: String) async -> RepositoryCenter.Download {
            await RepositoryCenter.download(fromUrl: URL(string: address)!, networking: Self.networking)
        }
        #expect(await download("https://kinds.test/file").data == Data("x".utf8))
        guard case .absent = await download("https://kinds.test/missing") else {
            Issue.record("404 is the server saying it has no such file")
            return
        }
        guard case .serverError(503) = await download("https://kinds.test/broken") else {
            Issue.record("503 is the server's own failure")
            return
        }
        guard case .unreachable(.cannotConnectToHost) = await download("https://refused.test/file") else {
            Issue.record("a refused connection never reached the server")
            return
        }
    }

    /// Three downloads watched the way the refresh queue watches them, on
    /// shorter limits: one that never gets an answer, one that sends a few
    /// bytes and stops, and one that sends slowly and steadily. Only the
    /// first two are stopped, and the third arrives whole.
    @Test func watchdogStopsOnlyWhatStoppedMoving() async {
        _ = TestEnvironment.root
        let chunk = Data(repeating: 0x41, count: 600)
        StubServer.serve([:], on: "watched.test", behaving: [
            "/hang": .hang,
            "/stall": .stallAfter(Data(repeating: 0x42, count: 100)),
            "/trickle": .trickle(chunk: chunk, every: 0.2, chunks: 20),
        ])
        let limits = UpdateSchedule.Limits(stall: 1.2, kill: 2.5, total: 10)
        let watch = Watch()
        let started = Date()
        var tasks = [String: Task<RepositoryCenter.Download, Never>]()
        for path in ["hang", "stall", "trickle"] {
            var networking = Self.networking
            networking.activity = { Task { @MainActor in watch.lastActivity[path] = Date() } }
            tasks[path] = Task {
                let download = await RepositoryCenter.download(
                    fromUrl: URL(string: "https://watched.test/\(path)")!,
                    networking: networking
                )
                await MainActor.run { watch.finished.insert(path) }
                return download
            }
        }
        while await watch.finished.count < tasks.count, Date().timeIntervalSince(started) < 10 {
            let flights = await MainActor.run {
                tasks.keys
                    .filter { !watch.finished.contains($0) && !watch.killed.contains($0) }
                    .map { path in
                        UpdateSchedule.Flight(
                            url: URL(string: "https://watched.test/\(path)")!,
                            started: started,
                            lastActivity: watch.lastActivity[path] ?? started
                        )
                    }
            }
            let decision = UpdateSchedule.decide(inFlight: flights, now: Date(), limits: limits)
            for url in decision.kill {
                let path = url.lastPathComponent
                await MainActor.run { _ = watch.killed.insert(path) }
                tasks[path]?.cancel()
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(await watch.killed == ["hang", "stall"])
        guard case .stalled = await tasks["hang"]!.value, case .stalled = await tasks["stall"]!.value else {
            Issue.record("a download given up is stalled, not unreachable")
            return
        }
        #expect(await tasks["trickle"]!.value.data?.count == chunk.count * 20)
    }
}

extension DownloadWatchdogTests {
    /// The icon of the first address that has one, however much quicker a
    /// later one answers: the root's over the suite's, as before.
    @Test func iconFollowsTheOrderNotTheRace() async {
        _ = TestEnvironment.root
        let root = Data(repeating: 1, count: 300)
        StubServer.serve(["/suite/CydiaIcon.png": Data(repeating: 2, count: 10)], on: "icons.test", behaving: [
            "/CydiaIcon.png": .trickle(chunk: root, every: 0.2, chunks: 2),
        ])
        let urls = ["https://icons.test/CydiaIcon.png", "https://icons.test/suite/CydiaIcon.png"].map { URL(string: $0)! }
        #expect(await RepositoryCenter.downloadAvatar(from: urls, networking: Self.networking) == root + root)
        StubServer.serve(["/suite/CydiaIcon.png": Data(repeating: 2, count: 10)], on: "icons-missing.test")
        let fallback = ["https://icons-missing.test/CydiaIcon.png", "https://icons-missing.test/suite/CydiaIcon.png"]
            .map { URL(string: $0)! }
        #expect(await RepositoryCenter.downloadAvatar(from: fallback, networking: Self.networking) == Data(repeating: 2, count: 10))
    }

    /// Work that holds its thread still beats: the beat is a dispatch
    /// timer's, not a task's that would wait for a thread.
    @Test func longWorkStillBeats() {
        let beats = Beats()
        RepositoryCenter.beating({ beats.add() }) {
            Thread.sleep(forTimeInterval: 2.3)
        }
        #expect(beats.count >= 2)
    }
}

private final class Beats: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

@MainActor private final class Watch {
    var lastActivity = [String: Date]()
    var finished = Set<String>()
    var killed = Set<String>()
}
