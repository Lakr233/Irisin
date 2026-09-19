import Foundation
@testable import IrisinAdapter
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

/// The entitlements reader walks bytes by an index of its own, and every
/// loop in it has to move that index. A document cut anywhere, or with a
/// byte swapped for one the reader treats specially, is where one would not.
struct EntitlementsLoopTests {
    private static let document = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <!-- a "comment" -->
    <plist version="1.0">
    <dict>
    \t<key>get-task-allow</key><true/>
    \t<key>a&amp;b&#65;&#x41;</key><string> &lt;text&gt; </string>
    \t<key>groups</key><array><string>one</string><integer>2</integer><dict/></array>
    \t<key>blob</key><data>QUFB</data>
    </dict>
    </plist>
    """

    @Test func theDocumentItselfIsRead() throws {
        _ = try LdidEntitlements(xml: Data(Self.document.utf8))
    }

    @Test func aDocumentCutAnywhereIsReadOrRefused() {
        let bytes = Array(Self.document.utf8)
        #expect(finished(within: 60) {
            for end in 0 ... bytes.count {
                _ = try? LdidEntitlements(xml: Data(bytes[..<end]))
            }
            return true
        } == true)
    }

    @Test func aDocumentWithOneByteChangedIsReadOrRefused() {
        let bytes = Array(Self.document.utf8)
        let swaps = Array("<>\"&;/![ \0".utf8) + [0xFF, 0xCD]
        #expect(finished(within: 120) {
            for at in bytes.indices {
                for swap in swaps {
                    var changed = bytes
                    changed[at] = swap
                    _ = try? LdidEntitlements(xml: Data(changed))
                }
            }
            return true
        } == true)
    }

    @Test func invisibleTextIsReadOrRefused() {
        #expect(finished {
            for mark in invisible {
                let text = "<dict><key>a\(mark)</key><string>\(mark)</string>\(mark)</dict>"
                _ = try? LdidEntitlements(xml: Data(text.utf8))
            }
            return true
        } == true)
    }
}
