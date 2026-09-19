import Foundation
import IrisinProtocol
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

/// Text that reads one way to Foundation and another to `Character`: the
/// combining grapheme joiner, an accent, a joiner, a variation selector and
/// CRLF, each of which hides the byte before it from a `Character` match.
private let invisible = ["\u{034F}", "\u{0301}", "\u{200D}", "\u{FE0F}", "\r\n", "\u{0000}"]

/// Every `while` in the version comparison drops a character a turn. These
/// are the versions that would stop one from doing so.
struct VersionLoopTests {
    @Test func comparingEndsOnTextThatIsNotWhatItLooksLike() throws {
        var versions = ["", "0", "000", "~", "~~", "1~", "a", "1:", ":", "-", "1-", "0:0-0"]
        for mark in invisible {
            versions += ["1\(mark)", "0\(mark)0", "1.0\(mark)-1", "\(mark)", "~\(mark)", "1:\(mark)2-\(mark)"]
        }
        let all = versions
        let asymmetric = try #require(finished {
            all.flatMap { a in all.filter { b in DebianVersion.compare(a, b).signum() != -DebianVersion.compare(b, a).signum() } }
        })
        #expect(asymmetric.isEmpty)
    }
}
