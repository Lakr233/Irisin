import Foundation

/// What the last refresh of a repository came to, kept with it so its dot
/// and its page can say why, not only whether. Stored as JSON in
/// `Repository.attachment[.refreshReport]`: no column, no migration.
public struct RefreshReport: Codable, Hashable, Sendable {
    public var date: Date
    public var duration: TimeInterval
    /// empty when the refresh went through without a hitch
    public var issues: [Issue]

    public enum Issue: Codable, Hashable, Sendable {
        /// the server could not be reached at all
        case unreachable
        /// the server stopped answering and the refresh was given up
        case stalled
        /// the server answered with its own failure (5xx)
        case serverError(Int)
        /// the server has no Release
        case releaseMissing
        /// the Release could not be read, or says one thing twice
        case releaseMalformed
        /// the server handed over an older Release than the one kept, which
        /// was ignored
        case releaseOutdated
        /// the Release does not list the index that was read, so nothing
        /// vouches for it
        case indexUnverified
        /// the server answered and has no index for this device
        case noIndex
    }

    public init(date: Date, duration: TimeInterval, issues: [Issue]) {
        self.date = date
        self.duration = duration
        self.issues = issues
    }

    /// What went wrong was the connection, not what the server said.
    public var didNotConnect: Bool {
        issues.contains { $0 == .unreachable || $0 == .stalled }
    }

    /// The refresh read no catalogue because of the network or the server,
    /// the reasons a slow or dead source is last in line next time.
    var failedToFetch: Bool {
        issues.contains {
            switch $0 {
            case .unreachable, .stalled, .serverError, .noIndex: true
            default: false
            }
        }
    }
}

public extension Repository {
    /// The last refresh's report, nil before the first refresh that kept one.
    var refreshReport: RefreshReport? {
        attachment[.refreshReport]
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(RefreshReport.self, from: $0) }
    }
}

extension Repository {
    mutating func setRefreshReport(_ report: RefreshReport) {
        attachment[.refreshReport] = (try? JSONEncoder().encode(report))
            .flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// How a repository stands, for its dot: the four states a row draws.
public enum RepositoryHealth: Sendable, Equatable {
    /// in the refresh queue or being refreshed
    case pending
    /// has packages, and the last refresh went through, within a day
    case ready
    /// has packages, but the last refresh had trouble or was over a day ago
    case degraded
    /// has no packages
    case failed
}
