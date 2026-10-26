//
//  OperationFeed.swift
//  Irisin
//

import Foundation
import IrisinWeb

/// The lines of the operation a browser started, numbered from 1, as the
/// page reads them (`Packages/IrisinWeb/README.md`, Stream frames). Kept
/// until the next one begins, so a page that comes back reads how the last
/// one ended. Filled by polling the operation's monitor and read by polling
/// here: the page is on the same network, and a few reads a second cost
/// nothing worth a publisher.
final class OperationFeed {
    private(set) var frames: [JSONValue] = []
    /// An operation is being followed and has not ended.
    private(set) var isRunning = false

    /// How often the monitor is read and the page's stream looks for more.
    static let interval: TimeInterval = 0.25

    /// A new operation: the last one's lines go.
    func begin() {
        frames = []
        isRunning = true
    }

    func append(_ fields: [String: JSONValue]) {
        var frame = fields
        frame["seq"] = .integer(frames.count + 1)
        frames.append(.object(frame))
    }

    /// A line in the device's words, outside any operation's own: why one
    /// could not start, or what the device does next.
    func say(_ line: String) {
        append(["line": .string(line)])
    }

    func end(succeeded: Bool, status: Int32?) {
        guard isRunning else { return }
        append([
            "end": .bool(true),
            "succeeded": .bool(succeeded),
            "status": status.map { .integer(Int($0)) } ?? .null,
        ])
        isRunning = false
    }

    /// The frames after `after`, and whether there will be no more.
    func frames(after: Int) -> (frames: [JSONValue], finished: Bool) {
        let start = min(max(after, 0), frames.count)
        return (Array(frames[start...]), !isRunning)
    }

    /// Reads the monitor until its operation ends: a frame for each line,
    /// each package's step as it changes, and the count. Returns the
    /// helper's exit status; the caller says what comes next and ends it.
    func follow(_ monitor: OperationMonitor) async -> Int32? {
        var lineCount = 0
        var steps: [String: String] = [:]
        var progress: OperationMonitor.Progress?
        while true {
            // a package's step and the count first: a line read in the same
            // turn is usually about the step that just began or ended
            for (identity, state) in monitor.packages.states.sorted(by: { $0.key < $1.key }) {
                guard let step = Self.step(of: state.status), steps[identity] != step else { continue }
                steps[identity] = step
                append(["package": .string(identity), "step": .string(step)])
            }
            if let current = monitor.progress, current != progress {
                progress = current
                append(["progress": .object([
                    "completed": .integer(current.completed),
                    "total": .integer(current.total),
                ])])
            }
            let lines = monitor.lines
            for line in lines.dropFirst(lineCount) {
                append(["line": .string(line)])
            }
            lineCount = lines.count
            if monitor.outcome != nil {
                // the lines the outcome added are read above on the next turn
                if lineCount == monitor.lines.count {
                    return monitor.transcript.reversed().lazy.compactMap { event -> Int32? in
                        if case let .exit(status) = event {
                            return status
                        }
                        return nil
                    }.first
                }
                continue
            }
            try? await Task.sleep(continuousSeconds: Self.interval)
        }
    }

    /// The step a package's row is at, in the page's words; nil before it
    /// has one.
    private static func step(of status: OperationPackages.Status) -> String? {
        switch status {
        case .waiting, .notStarted: nil
        case let .running(step, _): step.rawValue
        case .done: "done"
        case .failed, .incomplete: "failed"
        }
    }
}
