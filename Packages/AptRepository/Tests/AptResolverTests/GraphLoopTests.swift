@testable import AptResolver
import Foundation
import Testing

private final class FinishedBox<T>: @unchecked Sendable {
    var value: T?
}

/// Runs `body` on a thread of its own and hands back what it made, or nil
/// when it did not come back in time. A loop that never ends would otherwise
/// hang the whole run, so the thread is left behind and the test fails.
private func finished<T: Sendable>(within seconds: Double = 10, _ body: @escaping @Sendable () -> T) -> T? {
    let box = FinishedBox<T>()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        box.value = body()
        done.signal()
    }
    return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

/// The resolver's worklists and fixed points, on graphs that go round.
struct GraphLoopTests {
    @Test func componentsOfAGraphWithRings() {
        #expect(finished { StronglyConnectedComponents.components([:]) } == [])
        #expect(finished { StronglyConnectedComponents.components([1: [1]]) } == [[1]])
        #expect(finished { StronglyConnectedComponents.components([1: [2], 2: [1], 3: [1, 3, 9]]) } == [[1, 2], [3]])
        // a ring of a thousand is one component
        var ring: [Int: [Int]] = [:]
        for node in 0 ..< 1000 {
            ring[node] = [(node + 1) % 1000, node]
        }
        let graph = ring
        #expect(finished { StronglyConnectedComponents.components(graph) } == [Set(0 ..< 1000)])
    }

    @Test func removableAmongPackagesThatNeedEachOther() {
        let ring = ["a": ["b"], "b": ["a"], "c": ["c"], "d": ["a", "missing"]]
        #expect(finished { ResolutionPlan.removable(["a", "b", "c", "d", "stranger"], unneeded: ring) } == ["a", "b", "c"])
        #expect(finished { ResolutionPlan.removable(["a"], unneeded: ring) } == [])
        #expect(finished { ResolutionPlan.removable([], unneeded: ring) } == [])
    }
}
