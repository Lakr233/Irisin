import Foundation
@testable import IrisinInstaller
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

/// The installer's loops that follow what a package or the disk says: a
/// chain of hard links, a chain of symbolic links, a status record, a pipe.
struct InstallerLoopTests {
    private static func link(_ path: String, to target: String) -> PreparedEntry {
        PreparedEntry(path: path, kind: .hardLink, linkTarget: target, mode: 0o644, uid: 0, gid: 0, modificationTime: 0)
    }

    @Test func hardLinksInARingAreRefused() throws {
        let rings: [[PreparedEntry]] = [
            [Self.link("a", to: "a")],
            [Self.link("a", to: "b"), Self.link("b", to: "a")],
            [Self.link("a", to: "b"), Self.link("b", to: "c"), Self.link("c", to: "b")],
        ]
        let resolved = try #require(finished { rings.map { try? PackageArchive.resolveHardLinks($0) } })
        #expect(resolved.allSatisfy { $0 == nil })
    }

    @Test func symbolicLinksInARingResolveToNothing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.resolvingSymlinksInPath().path
        try FileManager.default.createSymbolicLink(atPath: path + "/a", withDestinationPath: path + "/b")
        try FileManager.default.createSymbolicLink(atPath: path + "/b", withDestinationPath: "a")
        try FileManager.default.createSymbolicLink(atPath: path + "/self", withDestinationPath: "self/.")
        let layout = BootstrapLayout(kind: .none)
        let resolved = try #require(finished {
            ["a", "b", "self", "a/below", "self/../self/below"].map {
                PackageFilesystem.physicalPath(path + "/" + $0, followingLast: true, layout: layout)
            }
        })
        #expect(resolved.allSatisfy { $0 == nil })
    }

    @Test func aConffilesRecordOfFlagsAloneIsRefused() throws {
        let records = [" obsolete", " obsolete remove-on-upgrade", " remove-on-upgrade obsolete obsolete", " /etc/x"]
        let read = try #require(finished { records.map { (try? Conffiles(status: $0)) != nil } })
        #expect(read.allSatisfy { !$0 })
        #expect(try #require(finished { (try? Conffiles(status: "\n\n \n")) != nil }))
    }

    @Test func linesEndWithThePipe() {
        var ends = [Int32](repeating: 0, count: 2)
        #expect(pipe(&ends) == 0)
        let text = "\n\none\r\n\u{034F}\n\ntail with no newline"
        _ = text.withCString { write(ends[1], $0, strlen($0)) }
        close(ends[1])
        let reader = ends[0]
        let lines = finished {
            var lines: [String] = []
            LineReader.read(descriptor: reader) { lines.append($0) }
            return lines
        }
        #expect(lines == ["", "", "one\r", "\u{034F}", "", "tail with no newline"])
        close(reader)
    }
}
