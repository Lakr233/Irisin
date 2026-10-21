import AptResolver

/// The app's wording for why a plan could not be made
/// (`ResolutionFailure+Presentation`), in English and for a shell: the
/// next step is a command or Irisin, not the queue.
extension ResolutionFailure {
    var text: String {
        let reason = switch reason {
        case let .unreadableVersion(package):
            "\(package): the repository sent an unreadable version. Refresh the repository in Irisin and try again."
        case let .unreadableMetadata(package, version):
            "\(package) \(version): the repository sent unreadable package information. Refresh the repository in Irisin and try again."
        case let .unfinishedInstall(package):
            "\(package) did not finish installing. Install it again before making other changes."
        case let .ambiguousVersion(package):
            "\(package) could not be resolved to a single version."
        case let .missingRequirement(package, requirement):
            "\(package) requires \(requirement), which is not available. Add a repository that provides it in Irisin and try again."
        case let .conflict(package, requirement):
            "\(package) conflicts with \(requirement). Remove one of them and try again."
        case let .noInstallOrder(packages):
            "These packages could not be installed in a valid order: \(packages.joined(separator: ", "))."
        case .orderUnplanned:
            "The installation order could not be planned. Try again with fewer changes."
        case let .noVersion(package):
            "\(package): no version is available from its repository."
        case let .versionUnavailable(package):
            "\(package): this version is not available from its repository."
        case .noPlan:
            "No compatible installation plan was found."
        case .requirementsUnmatched:
            "Some package requirements could not be matched."
        case .requirementsConflict:
            "Matching packages were found, but their requirements conflict."
        case .unresolvable:
            "The packages could not be resolved."
        case let .requiredBySystem(package):
            "\(package) is required by the system and cannot be removed."
        case let .neededBySystem(package, dependents):
            "\(package) is needed by \(dependents.joined(separator: ", ")), which the system requires, so it cannot be removed."
        case let .onHold(package):
            "\(package) is on hold and cannot be changed."
        case .updateAllRemoves:
            "Upgrading everything would remove installed packages. Install the updates by name."
        case .unknown:
            "Unable to resolve the packages."
        case let .message(text):
            text
        }
        let evidence = checks.filter { $0.outcome != .matched }.map { check in
            "  \(check.package) needs \(check.requirement): \(check.outcome.text)"
        }
        return ([reason] + evidence).joined(separator: "\n")
    }
}

extension ResolutionCheck.Outcome {
    var text: String {
        switch self {
        case .matched: "available"
        case .missing: "no repository provides it"
        case .incompatibleArchitecture: "only for another bootstrap"
        case .noMatchingVersion: "no version matches"
        case .invalidMetadata: "its information is unreadable"
        case .conflictingRequirements: "the requirements conflict"
        case .requiredBySystem: "the system requires it"
        }
    }
}
