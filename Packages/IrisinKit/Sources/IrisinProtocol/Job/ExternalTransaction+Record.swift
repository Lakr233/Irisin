import Darwin
import Foundation

public extension ExternalTransaction {
    /// One event of a transaction as an external client reads it: a stable,
    /// flat projection of `InstallerEvent`, numbered from 1 in the order the
    /// helper wrote them. `raw` is the helper's own line, Irisin's internal
    /// shape, for a client that wants the detail and accepts its changes.
    struct Event: Equatable, Sendable {
        public var sequence: UInt64
        /// `started`, `phase`, `progress`, `package`, `packageProgress`,
        /// `script`, `output`, `notice`, `warning`, `failure` or `exit`.
        public var kind: String
        /// The plain-text line the helper's log has for it, in English.
        public var text: String
        public var phase: String?
        public var step: String?
        public var identity: String?
        public var version: String?
        public var completed: Int64?
        public var total: Int64?
        public var exitStatus: Int64?
        /// For `warning` and `failure`, the problem's case name
        /// (`packageFailed`, `scriptFailed`, `installationStopped`, ...).
        public var problem: String?
        public var raw: String

        public init(sequence: UInt64, line: String) {
            self.sequence = sequence
            raw = line
            let event = InstallerOutput.decode(line)
            text = event.description
            switch event {
            case .started: kind = "started"
            case let .phase(phase):
                kind = "phase"; self.phase = phase.rawValue
            case let .progress(completed, total):
                kind = "progress"; self.completed = Int64(completed); self.total = Int64(total)
            case let .package(step, identity, version):
                kind = "package"; self.step = step.rawValue; self.identity = identity; self.version = version
            case let .packageProgress(identity, completed, total):
                kind = "packageProgress"; self.identity = identity
                self.completed = Int64(completed); self.total = Int64(total)
            case let .script(identity, _, _):
                kind = "script"; self.identity = identity
            case .output: kind = "output"
            case .notice: kind = "notice"
            case let .warning(problem):
                kind = "warning"; self.problem = problem.name
            case let .failure(problem):
                kind = "failure"; self.problem = problem.name
            case let .exit(status):
                kind = "exit"; exitStatus = Int64(status)
            }
        }
    }

    /// What a transaction's directory says about it now.
    struct Record: Sendable {
        public var transaction: String
        public var request: Request
        public var package: Package?
        public var state: State
        public var exitStatus: Int32?
        /// The last `failure` event, if there was one.
        public var failure: Event?
        /// One more than the last event's sequence: the `after` that asks
        /// for nothing already read is `nextSequence - 1`.
        public var nextSequence: UInt64
        /// Every complete line of the journal, in order. A line still being
        /// written (no newline yet) is not an event yet.
        public var lines: [String]

        /// Reads `directory`. Throws `notFound` when it is not a
        /// transaction's.
        public static func load(directory: String, transaction: String) throws -> Record {
            guard let requestData = FileManager.default.contents(atPath: directory + "/" + File.request),
                  let request = try? JSONDecoder().decode(Request.self, from: requestData)
            else {
                throw IrisinFailure(code: .notFound, systemError: ENOENT)
            }
            let package = FileManager.default.contents(atPath: directory + "/" + File.package)
                .flatMap { try? JSONDecoder().decode(Package.self, from: $0) }
            let journalPath = directory + "/" + File.journal
            let lines = completeLines(FileManager.default.contents(atPath: journalPath) ?? Data())
            var exitStatus: Int32?
            var failure: Event?
            for (index, line) in lines.enumerated() {
                switch InstallerOutput.decode(line) {
                case let .exit(status): exitStatus = status
                case .failure: failure = Event(sequence: UInt64(index + 1), line: line)
                default: break
                }
            }
            let state: State = if let exitStatus {
                exitStatus == 0 ? .succeeded : .failed
            } else {
                isHeld(journalPath) ? .running : .interrupted
            }
            return Record(
                transaction: transaction,
                request: request,
                package: package,
                state: state,
                exitStatus: exitStatus,
                failure: failure,
                nextSequence: UInt64(lines.count + 1),
                lines: lines
            )
        }

        /// The events after `after`, at most `limit` of them.
        public func events(after: UInt64, limit: Int) -> [Event] {
            guard after < UInt64(lines.count) else { return [] }
            let start = Int(after)
            let end = min(lines.count, start + max(0, limit))
            return (start ..< end).map { Event(sequence: UInt64($0 + 1), line: lines[$0]) }
        }

        static func completeLines(_ data: Data) -> [String] {
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
            return data[data.startIndex ..< lastNewline]
                .split(separator: 0x0A, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
        }

        /// Whether a process holds the journal's `flock`: the helper, which
        /// inherited the daemon's exclusive lock with the descriptor.
        public static func isHeld(_ path: String) -> Bool {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
                flock(descriptor, LOCK_UN)
                return false
            }
            return errno == EWOULDBLOCK
        }
    }
}

public extension InstallerEvent.Problem {
    /// The case's name, as an external client reads it.
    var name: String {
        switch self {
        case .invalidJob: "invalidJob"
        case .helperMisplaced: "helperMisplaced"
        case .installationStopped: "installationStopped"
        case .packageFailed: "packageFailed"
        case .scriptFailed: "scriptFailed"
        case .scriptFailureIgnored: "scriptFailureIgnored"
        case .homeScreenNeedsAttention: "homeScreenNeedsAttention"
        case .registrationFailed: "registrationFailed"
        case .unregistrationFailed: "unregistrationFailed"
        case .leftoverBundle: "leftoverBundle"
        case .refreshFailed: "refreshFailed"
        case .daemonNotLoaded: "daemonNotLoaded"
        case .noProcess: "noProcess"
        case .packageNeedsRepair: "packageNeedsRepair"
        case .markingsNotSaved: "markingsNotSaved"
        case .browsingOnly: "browsingOnly"
        case .helperUnreachable: "helperUnreachable"
        }
    }
}
