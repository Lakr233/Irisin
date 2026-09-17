//
//  ResolutionFailure+Presentation.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptResolver
import Foundation

nonisolated extension ResolutionFailure {
    /// The reason, in the user's language.
    var message: String {
        reason.message
    }
}

nonisolated extension ResolutionFailure.Reason {
    var message: String {
        let list = ListFormatter.localizedString(byJoining:)
        return switch self {
        case let .unreadableVersion(package):
            String(localized: "\(package): the repository sent an unreadable version. Refresh the repository and try again.")
        case let .unreadableMetadata(package, version):
            String(localized: "\(package) \(version): the repository sent unreadable package information. Refresh the repository and try again.")
        case let .unfinishedInstall(package):
            String(localized: "\(package) did not finish installing. Install it again before making other changes.")
        case let .ambiguousVersion(package):
            String(localized: "\(package) could not be resolved to a single version. Clear the queue and try again.")
        case let .missingRequirement(package, requirement):
            String(localized: "\(package) requires \(requirement), which is not available. Add a repository that provides it and try again.")
        case let .conflict(package, requirement):
            String(localized: "\(package) conflicts with \(requirement). Remove one of them and try again.")
        case let .noInstallOrder(packages):
            String(localized: "These packages could not be installed in a valid order: \(list(packages)). Remove some of them from the queue and try again.")
        case .orderUnplanned:
            String(localized: "The installation order could not be planned. Try again with fewer changes.")
        case let .noVersion(package):
            String(localized: "\(package): no version is available from its repository. Refresh the repository and try again.")
        case let .versionUnavailable(package):
            String(localized: "\(package): this version is not available from its repository. Refresh the repository and try again.")
        case .noPlan:
            String(localized: "No compatible installation plan was found.")
        case .requirementsUnmatched:
            String(localized: "Some package requirements could not be matched.")
        case .requirementsConflict:
            String(localized: "Matching packages were found, but their requirements conflict.")
        case .unresolvable:
            String(localized: "The selected packages could not be resolved. Adjust your selection and try again.")
        case let .requiredBySystem(package):
            String(localized: "\(package) is required by the system and cannot be removed.")
        case let .neededBySystem(package, dependents):
            String(localized: "\(package) is needed by \(list(dependents)), which the system requires, so it cannot be removed.")
        case let .onHold(package):
            String(localized: "\(package) is on hold and cannot be changed. Remove the hold and try again.")
        case .updateAllRemoves:
            String(localized: "Updating everything would remove installed packages. Update packages one at a time.")
        case .unknown:
            String(localized: "Unable to resolve the packages. Review the queue and try again.")
        case let .message(text):
            text
        }
    }
}
