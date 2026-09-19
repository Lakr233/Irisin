@testable import AptRepository
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

/// Text that reads one way to Foundation and another to `Character`: the
/// combining grapheme joiner, an accent, a joiner, a variation selector and
/// CRLF, each of which hides the byte before it from a `Character` match.
private let invisible = ["\u{034F}", "\u{0301}", "\u{200D}", "\u{FE0F}", "\r\n", "\u{0000}"]

/// An address is trimmed by loops that ask the string a question and then
/// change it. Each has to change what it asked about, whatever the text.
struct AddressLoopTests {
    private static var addresses: [String] {
        var all = ["", "/", "//", "://", "https://", "https:////", "https://https://", "https://HTTP://https://a//"]
        for mark in invisible {
            all += [
                "a/\(mark)", "a\(mark)/", "/\(mark)/", "a//\(mark)//", "\(mark)",
                "https://\(mark)https://a/", "https:/\(mark)/https://a/", "https://a/\(mark)", "https://https://a\(mark)//",
            ]
        }
        return all
    }

    @Test func anAddressIsReadOrRefused() {
        let addresses = Self.addresses
        #expect(finished {
            for address in addresses {
                _ = RepositorySource.url(from: address)
                _ = RepositorySource(line: "deb \(address) ./")
            }
            return true
        } == true)
    }

    @Test func aReadAddressEndsWithoutASlash() {
        #expect(RepositorySource.url(from: "https://https://example.org///")?.absoluteString == "https://example.org")
        #expect(RepositorySource.url(from: "example.org/")?.absoluteString == "https://example.org")
        #expect(RepositorySource.url(from: "https://") == nil)
    }
}
