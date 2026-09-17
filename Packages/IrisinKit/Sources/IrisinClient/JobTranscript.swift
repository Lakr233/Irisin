import Darwin
import Foundation
import IrisinProtocol

/// The helper's output, read from the descriptor the daemon handed back.
///
/// The descriptor is the read end of a pipe the helper writes into. It
/// belongs to this process: bytes flow from the helper through the kernel to
/// here, and the daemon that made the introduction keeps nothing. A
/// self-update that restarts the daemon does not interrupt this stream.
public final class JobTranscript: @unchecked Sendable {
    public let identifier: UInt64
    /// Every event the helper wrote, in order, ending with `.exit` when the
    /// helper got that far. Finishes at EOF. Buffered without bound, so a
    /// consumer that attaches late or reads slowly misses nothing.
    public let events: AsyncStream<InstallerEvent>

    init(identifier: UInt64, descriptor: Int32) {
        self.identifier = identifier
        var continuation: AsyncStream<InstallerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        let yield = continuation!
        // A plain thread rather than a task: `read(2)` blocks, and a blocked
        // cooperative-pool thread is a thread the rest of the app needed.
        let reader = Thread {
            LineReader.read(descriptor: descriptor) { yield.yield(InstallerOutput.decode($0)) }
            yield.finish()
            close(descriptor)
        }
        reader.name = "wiki.qaq.irisin.job.\(identifier)"
        reader.start()
    }

    /// Reads to the end, handing every event but the last to `onEvent`, and
    /// returns the status the helper announced. Nil means the stream ended
    /// without one: the helper died, which is a failure the caller reports
    /// as such.
    public func collect(onEvent: @escaping @Sendable (InstallerEvent) -> Void) async -> Int32? {
        var status: Int32?
        for await event in events {
            if case let .exit(announced) = event {
                status = announced
            } else {
                onEvent(event)
            }
        }
        return status
    }
}

/// Reads a descriptor to EOF and hands back each line as it completes. The
/// same loop the helper uses to read its tools, spelled here so the client
/// module does not link the installer.
enum LineReader {
    static func read(descriptor: Int32, line: (String) -> Void) {
        var pending = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { break }
            pending.append(contentsOf: buffer[0 ..< count])
            while let newline = pending.firstIndex(of: 0x0A) {
                line(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty {
            line(String(decoding: pending, as: UTF8.self))
        }
    }
}
