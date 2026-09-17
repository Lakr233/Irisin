//
//  PartialDownloads.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation

/// The bytes of downloads still under way, one file per URL, kept between
/// attempts so a server that honours `Range` can pick up where it left off.
/// A finished download is moved out by `DownloadCenter`; nothing stays here
/// once it is either verified or given up on.
nonisolated enum PartialDownloads {
    /// In a caches folder named after the app: it has no container, and
    /// `Library/Caches` is shared with every other app without one.
    static let directory: URL = {
        let directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wiki.qaq.irisin/PartialDownloads")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Named by a hash of the URL: a repository controls the last path
    /// component of its links, and a `..` in there must not leave the directory.
    static func file(for url: URL) -> URL {
        directory.appendingPathComponent(String.sha256From(data: Data(url.absoluteString.utf8)) + ".partial")
    }

    static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: file(for: url))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
