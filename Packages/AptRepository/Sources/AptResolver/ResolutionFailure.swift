import Foundation

/// Why a request has no plan. The resolver names the reason and the
/// packages involved; the app puts it in the user's words.
public struct ResolutionFailure: Error, Sendable {
    public enum Reason: Hashable, Sendable {
        /// The repository sent a version that does not parse.
        case unreadableVersion(package: String)
        /// The repository sent relations that do not parse.
        case unreadableMetadata(package: String, version: String)
        /// dpkg left the package half done.
        case unfinishedInstall(package: String)
        /// Two versions of the package ended up in one plan.
        case ambiguousVersion(package: String)
        case missingRequirement(package: String, requirement: String)
        case conflict(package: String, requirement: String)
        /// No order installs these without breaking one of them.
        case noInstallOrder(packages: [String])
        case orderUnplanned
        /// The request names a package with no version at all.
        case noVersion(package: String)
        /// The request names a version its repository no longer offers.
        case versionUnavailable(package: String)
        case noPlan
        /// The checks name a requirement nothing satisfies.
        case requirementsUnmatched
        /// Every requirement has a candidate, and they cannot all be had.
        case requirementsConflict
        /// The solver answered without doing what was asked.
        case unresolvable
        case requiredBySystem(package: String)
        /// A removal the system keeps: `dependents` are required by the
        /// system and depend on the package.
        case neededBySystem(package: String, dependents: [String])
        case onHold(package: String)
        case updateAllRemoves
        case unknown
        /// Already in the user's words: the app's own reasons.
        case message(String)
    }

    public let reason: Reason
    public let checks: [ResolutionCheck]

    public init(_ reason: Reason, checks: [ResolutionCheck] = []) {
        self.reason = reason
        self.checks = checks
    }

    /// A reason the app has already put in words.
    public init(message: String, checks: [ResolutionCheck] = []) {
        self.init(.message(message), checks: checks)
    }
}
