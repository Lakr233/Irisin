//
//  Locale.swift
//  Irisin
//

import Foundation

nonisolated extension Locale {
    /// Language, script and region read from the identifier, for iOS 15,
    /// which has no `Locale.Language`. Only Chinese has its script filled in
    /// when the identifier leaves it out (Traditional for Taiwan, Hong Kong
    /// and Macau), and a missing region stays missing: likely subtags are
    /// ICU's, and the SDK does not offer them below iOS 16.
    struct IdentifierParts: Equatable {
        let language: String?
        let script: String?
        let region: String?

        init(_ identifier: String) {
            let parts = Locale.components(fromIdentifier: identifier)
            language = parts[NSLocale.Key.languageCode.rawValue]
            region = parts[NSLocale.Key.countryCode.rawValue]
            script = parts[NSLocale.Key.scriptCode.rawValue]
                ?? (language == "zh" ? (["TW", "HK", "MO"].contains(region ?? "") ? "Hant" : "Hans") : nil)
        }

        /// `Locale.Language.isEquivalent(to:)` as near as these parts come:
        /// a region one side leaves out is not held against the other.
        func isEquivalent(to other: Self) -> Bool {
            language == other.language && script == other.script
                && (region == nil || other.region == nil || region == other.region)
        }
    }
}
