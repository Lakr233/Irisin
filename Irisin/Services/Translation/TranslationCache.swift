//
//  TranslationCache.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/19.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// What the translator answered, kept in memory by package so a page opened
/// again, or switched between Original, Translated and Compared, asks for
/// nothing. The fifty packages read last are held; the one read longest ago
/// leaves when another arrives. Nothing is written to disk: a translation
/// is the engine's of the day, and the next launch may have a better one.
enum TranslationCache {
    static let capacity = 50

    /// package, then "source>target", then the text and its translation
    private static var packages: [String: [String: [String: String]]] = [:]
    /// Package keys, the one read last at the end.
    private static var recency: [String] = []

    static func translations(of package: String, pair: String) -> [String: String]? {
        guard let found = packages[package]?[pair] else { return nil }
        touch(package)
        return found
    }

    static func store(_ translations: [String: String], of package: String, pair: String) {
        packages[package, default: [:]][pair] = translations
        touch(package)
        while recency.count > capacity {
            packages[recency.removeFirst()] = nil
        }
    }

    private static func touch(_ package: String) {
        recency.removeAll { $0 == package }
        recency.append(package)
    }
}
