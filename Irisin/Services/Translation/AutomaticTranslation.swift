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

    private static let targetStore = PropertiesWrapper(key: "package.translateTarget", defaultValue: "")

    /// The language pages are translated into: the user's own until the
    /// package page's Translate menu names another.
    static var target: Locale {
        get {
            let identifier = targetStore.wrappedValue
            return identifier.isEmpty ? SystemTranslator.preferredTarget : Locale(identifier: identifier)
        }
        set { targetStore.wrappedValue = newValue.identifier }
    }

    /// What is kept for `target`, empty while no language was named. A
    /// cancelled choice puts this back, not `target`: writing the user's own
    /// language down would hold pages to it after the system's changed.
    static var targetIdentifier: String {
        get { targetStore.wrappedValue }
        set { targetStore.wrappedValue = newValue }
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
