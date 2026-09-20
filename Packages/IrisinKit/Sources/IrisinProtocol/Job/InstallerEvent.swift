import Foundation

/// One thing `irisin-install` has to say while it works.
///
/// The helper's transcript used to be free text with ad-hoc prefixes; the
/// app could show it but not read it. Now every line on the pipe is one of
/// these, JSON-encoded (`InstallerOutput`), so the console can draw a phase
/// heading and a progress bar, localize what a package step is called, and
/// tell a warning from a script's chatter. The log file the helper keeps
/// beside the pipe gets `description`, the plain-text rendering, so a
/// transcript read over ssh still reads like one.
public enum InstallerEvent: Codable, Equatable, Sendable {
    /// The helper is up: which job, as whom, and under which install root.
    case started(Started)
    /// A named part of the job began. Phases arrive in order and never repeat.
    case phase(Phase)
    /// Package steps done so far, out of the total the transaction declared.
    case progress(completed: Int, total: Int)
    /// One package moves through the database.
    case package(PackageStep, identity: String, version: String)
    /// How far the package's current step is: files placed out of the files
    /// its archive holds. Said at most once per percent, and only by a step
    /// that can count; a script cannot.
    case packageProgress(identity: String, completed: Int, total: Int)
    /// A maintainer script is about to run with these arguments.
    case script(identity: String, member: String, arguments: [String])
    /// A line a script or a tool printed, verbatim.
    case output(String)
    /// Something worth knowing that changes nothing.
    case notice(String)
    /// A problem the job survived; the user may want to act on it.
    case warning(Problem)
    /// The reason the job stopped. Followed by a non-zero `exit`.
    case failure(Problem)
    /// The job's exit status; always the last event on the pipe.
    case exit(Int32)

    /// What went wrong, as a case the app can put in the user's language.
    /// The associated strings are detail for the log and the support
    /// report (a path, a tool's own message), never the headline.
    public enum Problem: Codable, Equatable, Sendable {
        /// The job failed validation and nothing was started.
        case invalidJob
        /// The helper is not at the path the package installs it to.
        case helperMisplaced
        /// The transaction stopped; `detail` is the installer's own account.
        case installationStopped(detail: String)
        /// The transaction stopped at this package, in this step. Nothing
        /// had been written yet when the step is `verifying`.
        case packageFailed(identity: String, step: PackageStep, detail: String)
        /// The transaction stopped at this package because one of its own
        /// maintainer scripts, run in this step, exited with `status`: a
        /// preinst that fails stops an unpack, but nothing failed to unpack.
        case scriptFailed(identity: String, step: PackageStep, script: String, status: Int32)
        /// A package-owned script failed, but the user explicitly chose to
        /// continue. `detail` is for the log and support report; the app's
        /// headline says only that the installation continued.
        case scriptFailureIgnored(identity: String, script: String, detail: String)
        /// The package database committed, but LaunchServices or husk
        /// cleanup did not finish; a rebuild retries it.
        case homeScreenNeedsAttention
        case registrationFailed(bundle: String, detail: String)
        case unregistrationFailed(bundle: String, detail: String)
        /// A removed app's directory could not be inspected or removed.
        case leftoverBundle(path: String, detail: String)
        /// icli's refresh reported failures.
        case refreshFailed(detail: String)
        /// A signal job found no process by that name.
        case noProcess(name: String)
        /// Unpacking failed after the database was told; the package stays
        /// half-installed until it is unpacked again.
        case packageNeedsRepair(identity: String)
        /// apt's extended_states could not be rewritten: which packages
        /// were installed automatically may be out of date.
        case markingsNotSaved(detail: String)
        /// Written by the app, not the helper: there is no privileged
        /// backend, so nothing was started.
        case browsingOnly
        /// Written by the app: the daemon did not start the helper.
        case helperUnreachable

        /// The plain-text rendering for the log file.
        public var description: String {
            switch self {
            case .invalidJob:
                "This operation is not valid and was not started."
            case .helperMisplaced:
                "irisin-install is not at its installed path."
            case let .installationStopped(detail):
                "Installation stopped: \(detail)"
            case let .packageFailed(identity, step, detail):
                "Installation stopped at \(identity) (\(step.rawValue)): \(detail)"
            case let .scriptFailed(identity, step, script, status):
                "Installation stopped at \(identity) (\(step.rawValue)): \(identity).\(script) exited with status \(status)"
            case let .scriptFailureIgnored(identity, script, detail):
                "Installation continued after \(identity).\(script) failed: \(detail)"
            case .homeScreenNeedsAttention:
                "Package changes completed, but the home screen needs attention. Rebuild icons to retry."
            case let .registrationFailed(bundle, detail):
                "App registration failed for \(bundle): \(detail)"
            case let .unregistrationFailed(bundle, detail):
                "App unregistration failed for \(bundle): \(detail)"
            case let .leftoverBundle(path, detail):
                "Cannot clean up app bundle \(path): \(detail)"
            case let .refreshFailed(detail):
                "App refresh failed: \(detail)"
            case let .noProcess(name):
                "No process named \(name) is running."
            case let .packageNeedsRepair(identity):
                "\(identity) requires repair; its half-installed state was retained."
            case let .markingsNotSaved(detail):
                "Cannot save automatically installed packages: \(detail)"
            case .browsingOnly:
                "Browsing only; the Irisin package is not installed."
            case .helperUnreachable:
                "The installer could not be started."
            }
        }
    }

    public struct Started: Codable, Equatable, Sendable {
        public var job: String
        public var uid: UInt32
        public var installRoot: String
        /// Seconds since 1970, so the app can date a transcript it reads back.
        public var timestamp: Double

        public init(job: String, uid: UInt32, installRoot: String, timestamp: Double = Date().timeIntervalSince1970) {
            self.job = job
            self.uid = uid
            self.installRoot = installRoot
            self.timestamp = timestamp
        }
    }

    /// What a package step is, spelled the way dpkg spells it.
    public enum PackageStep: String, Codable, Equatable, Sendable {
        /// The archive is checked against its digest and read, before
        /// anything is written. Announced with no version: reading the
        /// archive is what finds it.
        case verifying
        case removing
        case unpacking
        case configuring
        case triggering
    }

    /// The plain-text line the helper writes to its log file for this event,
    /// and what a reader with no localization shows. Not for the user's eyes
    /// in the app: the app renders each case in its own language.
    public var description: String {
        switch self {
        case let .started(started):
            let root = started.installRoot.isEmpty ? "/" : started.installRoot
            return "irisin-install \(started.job) uid \(started.uid) root \(root)"
        case let .phase(phase):
            return "==> \(phase.rawValue)"
        case let .progress(completed, total):
            return "[\(completed)/\(total)]"
        case let .package(step, identity, version):
            let verb = switch step {
            case .verifying: "Verifying"
            case .removing: "Removing"
            case .unpacking: "Unpacking"
            case .configuring: "Setting up"
            case .triggering: "Processing triggers for"
            }
            return version.isEmpty ? "\(verb) \(identity)" : "\(verb) \(identity) (\(version))"
        case let .packageProgress(identity, completed, total):
            return "\(identity) [\(completed)/\(total)]"
        case let .script(identity, member, arguments):
            return "[script] \(identity).\(member) " + arguments.joined(separator: " ")
        case let .output(line):
            return line
        case let .notice(text):
            return "[*] \(text)"
        case let .warning(problem):
            return "[!] \(problem.description)"
        case let .failure(problem):
            return "[!!] \(problem.description)"
        case let .exit(status):
            return "===> irisin-install exit \(status)"
        }
    }
}

public extension InstallerEvent {
    /// The parts of a job, in the order they happen. A transaction visits all of
    /// them (`registeringApplications` only when an app bundle came or went); a
    /// rebuild is `registeringApplications` alone, and the other maintenance
    /// jobs are `applying` alone. `completed` is emitted exactly when the job
    /// is about to exit with status 0.
    enum Phase: String, Codable, Equatable, Sendable, CaseIterable {
        /// Locks taken, the database read, the archives captured.
        case preparing
        /// The archives and the final state checked before anything is written.
        case verifying
        /// The stages run: files move, scripts run, the database is committed.
        case applying
        /// Pending triggers processed after the last stage.
        case processingTriggers
        /// LaunchServices told about app bundles that came or went.
        case registeringApplications
        /// Nothing left to do; the exit status follows.
        case completed
    }
}
