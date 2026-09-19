//
//  AutomaticTranslation.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/19.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// The Auto Translate setting and how its failures are spelled.
enum AutomaticTranslation {
    private static let store = PropertiesWrapper(key: "package.translateDescriptions", defaultValue: false)

    /// Settings turns this on only after `SystemTranslator.verify` passed.
    static var isEnabled: Bool {
        get { store.wrappedValue }
        set { store.wrappedValue = newValue }
    }

    /// A package page has told the user about a failure this launch.
    static var failureWasShown = false

    static func describe(_ error: Error) -> String {
        switch error as? SystemTranslator.Failure {
        case .unavailable:
            String(localized: "This device does not offer system translation.")
        case .unsupportedLanguage:
            String(localized: "System translation does not support this language.")
        case let .failed(reason):
            reason
        case nil:
            error.localizedDescription
        }
    }
}
