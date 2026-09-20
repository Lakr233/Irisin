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
