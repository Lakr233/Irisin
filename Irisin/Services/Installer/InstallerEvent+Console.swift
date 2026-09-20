import Foundation
import IrisinProtocol

extension InstallerEvent {
    /// The row the operation console shows for this event, in the user's
    /// language, or nil for an event that draws something else (progress)
    /// or nothing at all.
    var consoleLine: String? {
        switch self {
        case let .started(started):
            return String(localized: "Installer started at \(started.installRoot.isEmpty ? "/" : started.installRoot)")
        case let .phase(phase):
            return phase.localizedTitle
        case .progress, .packageProgress:
            return nil
        case let .package(step, identity, version):
            let subject = version.isEmpty ? identity : "\(identity) (\(version))"
            return switch step {
            case .verifying: String(localized: "Checking \(subject)")
            case .removing: String(localized: "Removing \(subject)")
            case .unpacking: String(localized: "Unpacking \(subject)")
            case .configuring: String(localized: "Setting up \(subject)")
            case .triggering: String(localized: "Processing triggers for \(subject)")
            }
        case let .script(identity, member, arguments):
            let script = ([identity + "." + member] + arguments.filter { !$0.isEmpty }).joined(separator: " ")
            return String(localized: "Running \(script)")
        case let .output(line):
            return line
        case let .notice(text):
            return text
        case let .warning(problem):
            return "[!] " + problem.localizedDescription
        case let .failure(problem):
            // the log is read on its own page: the reason has to be in it
            return "[!!] " + problem.localizedDescription
        case .exit(0):
            // the outcome's summary row says it
            return nil
        case let .exit(status):
            return String(localized: "The installer stopped (error code \(status)).")
        }
    }
}

extension InstallerEvent.Problem {
    /// The headline in the user's language; the helper's detail follows it
    /// where there is one, as it came.
    var localizedDescription: String {
        switch self {
        case .invalidJob:
            String(localized: "This operation is not valid and was not started.")
        case .helperMisplaced:
            String(localized: "Irisin is not installed correctly. Reinstall it and try again.")
        case let .installationStopped(detail):
            String(localized: "Installation stopped: \(detail)")
        case let .packageFailed(identity, step, detail):
            switch step {
            case .removing: String(localized: "Unable to remove \(identity): \(detail)")
            case .unpacking: String(localized: "Unable to install \(identity): \(detail)")
            case .configuring, .triggering: String(localized: "Unable to set up \(identity): \(detail)")
            case .verifying: String(localized: "Unable to verify \(identity): \(detail)")
            }
        case let .scriptFailed(identity, _, script, status):
            String(localized: "The \(script) script of \(identity) failed with exit status \(Int(status)).")
        case let .scriptFailureIgnored(identity, script, _):
            String(localized: "The \(script) script of \(identity) failed, but installation continued.")
        case .homeScreenNeedsAttention:
            String(localized: "Packages were changed, but the home screen was not updated. Choose Rebuild Icons to try again.")
        case let .registrationFailed(bundle, detail):
            String(localized: "Unable to add \(bundle) to the home screen: \(detail)")
        case let .unregistrationFailed(bundle, detail):
            String(localized: "Unable to remove \(bundle) from the home screen: \(detail)")
        case let .leftoverBundle(path, detail):
            String(localized: "Unable to remove leftover app files at \(path): \(detail)")
        case let .refreshFailed(detail):
            String(localized: "Unable to refresh apps: \(detail)")
        case let .noProcess(name):
            String(localized: "No process named \(name) is running.")
        case let .packageNeedsRepair(identity):
            String(localized: "\(identity) did not finish installing. Install it again to repair it.")
        case let .markingsNotSaved(detail):
            String(localized: "Unable to record which packages were installed as dependencies: \(detail)")
        case .browsingOnly:
            String(localized: "You can browse, but not install. Install the Irisin package.")
        case .helperUnreachable:
            String(localized: "The installer could not be started. Try again.")
        }
    }
}

extension InstallerEvent.Phase {
    /// The heading the console shows while this phase runs.
    var localizedTitle: String {
        switch self {
        case .preparing: String(localized: "Preparing…")
        case .verifying: String(localized: "Checking packages…")
        case .applying: String(localized: "Applying changes…")
        case .processingTriggers: String(localized: "Processing triggers…")
        case .registeringApplications: String(localized: "Updating the home screen…")
        case .completed: String(localized: "Finishing…")
        }
    }
}
