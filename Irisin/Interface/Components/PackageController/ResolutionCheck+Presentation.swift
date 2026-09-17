import AptRepository
import AptResolver
import UIKit

extension ResolutionCheck {
    var statusText: String {
        switch outcome {
        case .matched: String(localized: "Matching Package Found")
        case .missing: String(localized: "Not Found in Installed Packages or Repositories")
        case .incompatibleArchitecture: String(localized: "Found for a Different Architecture")
        case .noMatchingVersion: String(localized: "No Version Meets This Requirement")
        case .invalidMetadata: String(localized: "Package Metadata Could Not Be Read")
        case .conflictingRequirements: String(localized: "Requirements Conflict")
        case .requiredBySystem: String(localized: "Required by the System")
        }
    }

    var detailText: String {
        var lines = [statusText]
        if outcome == .incompatibleArchitecture {
            let accepted = AptEnvironment.current.installableArchitectures.sorted().joined(separator: ", ")
            lines.append(String(localized: "This device supports \(accepted)."))
        }
        return (lines + candidates).joined(separator: "\n")
    }
}
