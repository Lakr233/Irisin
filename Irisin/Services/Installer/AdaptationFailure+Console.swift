//
//  AdaptationFailure+Console.swift
//  Irisin
//

import Foundation
import IrisinAdapter

extension AdaptationFailure {
    /// The reason in the user's language, for the action report.
    var report: String {
        switch self {
        case let .unavailable(from, to):
            String(localized: "This package is built for \(from.rawValue). Converting it for \(to.rawValue) is not available yet.")
        case let .incompatible(package):
            String(localized: "\(package) is known not to work in compatibility mode.")
        case let .notSimple(package, path):
            String(localized: "\(package) cannot be installed in compatibility mode, which does not convert \(path).")
        case let .malformedBinary(package, path):
            String(localized: "\(package) cannot be installed in compatibility mode. \(path) could not be converted.")
        }
    }
}
