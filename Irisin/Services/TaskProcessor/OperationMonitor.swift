import Combine
import Foundation
import IrisinProtocol

/// One running operation, as the screens see it.
///
/// `TaskProcessor` feeds it the helper's events on the main actor and the
/// console binds to the published pieces: the phase heading, the progress
/// bar, the log rows and, at the end, the outcome. Every event is also kept
/// verbatim in `transcript`, so a support report can be written from what
/// the helper actually said and not from what the console chose to show.
final class OperationMonitor {
    struct Progress: Equatable {
        let completed: Int
        let total: Int

        var fraction: Float {
            total > 0 ? Float(completed) / Float(total) : 0
        }
    }

    enum Outcome: Equatable {
        case succeeded
        /// The summary the console shows, already localized.
        case failed(String)

        /// How a helper run ended, from its exit status (nil when it never
        /// started) and the last failure it reported.
        init(status: Int32?, failure: InstallerEvent.Problem?) {
            if status == 0 {
                self = .succeeded
            } else if let failure {
                // the helper's own reason is the headline when it gave one
                self = .failed(failure.localizedDescription)
            } else {
                self = .failed(status == nil
                    ? String(localized: "The installer could not be started. Try again.")
                    : String(localized: "Operation failed. Try again."))
            }
        }

        var succeeded: Bool {
            self == .succeeded
        }
    }

    let operation: TaskProcessor.OperationPayload

    @Published private(set) var phase: InstallerEvent.Phase?
    @Published private(set) var progress: Progress?
    /// What the console shows, one row each, in order. Not published
    /// itself: a published array is copied whole on every append, which a
    /// script that prints thousands of lines turns into a main-actor stall.
    /// `lineCount` is the signal; a subscriber reads `lines` when it fires.
    private(set) var lines: [String] = [] {
        didSet { lineCount = lines.count }
    }

    @Published private(set) var lineCount = 0
    /// Where each package stands, for the row that shows it.
    @Published private(set) var packages: OperationPackages
    /// What each package's scripts were and said, for the page that explains
    /// its failure. Read when that page opens; unpublished like `lines`.
    private(set) var packageOutput: [String: [String]] = [:]
    /// The helper's warnings, for the summary the closing screen shows.
    @Published private(set) var warnings: [String] = []
    /// Set exactly once, when the operation is over.
    @Published private(set) var outcome: Outcome?

    /// Every helper event, in order, as it arrived, the final `exit` included.
    private(set) var transcript: [InstallerEvent] = []
    /// The last failure the helper reported, the reason the outcome names.
    private(set) var failure: InstallerEvent.Problem?

    init(operation: TaskProcessor.OperationPayload) {
        self.operation = operation
        packages = OperationPackages(stages: operation.transaction.stages)
    }

    /// Whether finishing means leaving: the transaction replaced this app.
    var requiresExit: Bool {
        operation.transaction.touchesSelf && !operation.transaction.dryRun
    }

    /// The outcome, once there is one.
    var finished: Outcome {
        get async {
            for await value in $outcome.values {
                if let value {
                    return value
                }
            }
            return .failed(String(localized: "Operation failed. Try again."))
        }
    }

    /// A line the app itself wants on the console, such as its status.
    func append(_ line: String) {
        lines.append(line)
    }

    func record(_ event: InstallerEvent) {
        transcript.append(event)
        switch event {
        case let .phase(next):
            phase = next
        case let .progress(completed, total):
            progress = Progress(completed: completed, total: total)
        case let .warning(problem):
            warnings.append(problem.localizedDescription)
        case let .failure(problem):
            failure = problem
        default:
            break
        }
        // a chatty script changes no row, and every assignment publishes
        switch event {
        case .output, .notice: break
        default: packages.record(event)
        }
        if let line = event.consoleLine {
            lines.append(line)
            // after `record`: a script's announcement is its package's too
            switch event {
            case .script, .output:
                if let identity = packages.current {
                    packageOutput[identity, default: []].append(line)
                }
            case let .warning(.scriptFailureIgnored(identity, _, _)):
                packageOutput[identity, default: []].append(line)
            default:
                break
            }
        }
    }

    /// The summary becomes the last row, then the outcome is published: a
    /// subscriber that reacts to the outcome sees the complete log. A reason
    /// the helper already said as its failure is not said twice.
    func finish(_ result: Outcome) {
        guard outcome == nil else { return }
        switch result {
        case .succeeded:
            lines.append(String(localized: "Operation completed."))
        case let .failed(reason) where failure?.localizedDescription == reason:
            break
        case let .failed(reason):
            lines.append(reason)
        }
        packages.finish(succeeded: result.succeeded)
        outcome = result
    }
}
