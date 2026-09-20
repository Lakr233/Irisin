//
//  QueuePackageInspection.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import Foundation

/// What one queued package does to the device, read before it happens: the
/// files it adds, the ones it replaces and the ones it leaves to be deleted,
/// and the maintainer scripts in the order the helper runs them, each with
/// the arguments it is handed. An install reads the package file, a removal
/// reads dpkg's info directory, and neither changes anything.
nonisolated struct QueuePackageInspection: Sendable {
    struct Script: Hashable, Sendable {
        let name: String
        let arguments: [String]
        /// From dpkg's info directory, the installed version's own, rather
        /// than from the queued file.
        let installed: Bool
        /// Nil for a script that is a binary.
        let text: String?

        /// "prerm upgrade 1.0", as the helper calls it.
        var invocation: String {
            ([name] + arguments).joined(separator: " ")
        }
    }

    /// Paths that are not directories, as dpkg lists them.
    let added: [String]
    /// Already on disk, whoever put them there.
    let replaced: [String]
    /// The installed version's files that this change leaves nobody owning.
    let deleted: [String]
    /// The installed packages that list one of `replaced`, and how many of
    /// those files there are.
    let otherOwners: [String]
    let otherOwned: Int
    let scripts: [Script]

    /// Reads `archive` for an install, and nothing but the info directory
    /// for a removal.
    @concurrent
    static func inspect(_ change: QueueChange, archive: URL?) async throws -> QueuePackageInspection {
        let identity = change.package.identity.lowercased()
        let info = JailbreakRoot.installedPath("/Library/dpkg/info")
        func member(_ name: String) -> Data? {
            FileManager.default.contents(atPath: "\(info)/\(identity).\(name)")
        }
        let listed = paths(in: member("list"))
        // a line may carry a flag ahead of its path
        let conffiles = Set(paths(in: member("conffiles")).compactMap { $0.split(separator: " ").last.map(String.init) })

        var contents: ArchiveStream.DebianContents?
        if change.kind != .remove {
            guard let archive else { throw CocoaError(.fileNoSuchFile) }
            contents = try ArchiveStream.debianContents(atPath: archive.path)
        }
        let incoming = contents?.files ?? []
        var added: [String] = []
        var replaced: [String] = []
        for path in incoming {
            if fileType(of: path) == nil {
                added.append(path)
            } else {
                replaced.append(path)
            }
        }
        // a conffile outlives both a removal and the upgrade that drops it,
        // unless the new version says it goes
        let dropped = paths(in: contents?.controlFiles["conffiles"])
            .filter { $0.hasPrefix("remove-on-upgrade ") }
            .compactMap { $0.split(separator: " ").last.map(String.init) }
        let staying = Set(incoming).union(contents?.directories ?? []).union(conffiles.subtracting(dropped))
        var deleted = listed.filter { path in
            guard !staying.contains(path), let type = fileType(of: path) else { return false }
            return type != S_IFDIR
        }

        let owners = owners(of: Set(replaced).union(deleted), in: info, besides: identity)
        deleted.removeAll { owners[$0] != nil }
        let otherOwned = replaced.filter { owners[$0] != nil }

        let next = change.package.latestVersion ?? ""
        let current = change.current
        func script(_ name: String, _ arguments: [String], _ data: Data?, installed: Bool) -> Script? {
            data.map { Script(name: name, arguments: arguments, installed: installed, text: String(data: $0, encoding: .utf8)) }
        }
        let scripts: [Script?] = if change.kind == .remove {
            [
                script("prerm", ["remove"], member("prerm"), installed: true),
                script("postrm", ["remove"], member("postrm"), installed: true),
            ]
        } else {
            // `PackageTransaction.unpack` and `configure`, when nothing fails
            [
                current.flatMap { _ in script("prerm", ["upgrade", next], member("prerm"), installed: true) },
                script(
                    "preinst",
                    current.map { ["upgrade", $0, next] } ?? ["install"],
                    contents?.controlFiles["preinst"],
                    installed: false
                ),
                current.flatMap { _ in script("postrm", ["upgrade", next], member("postrm"), installed: true) },
                script(
                    "postinst",
                    ["configure"] + (current.map { [$0] } ?? []),
                    contents?.controlFiles["postinst"],
                    installed: false
                ),
            ]
        }
        return QueuePackageInspection(
            added: added,
            replaced: replaced,
            deleted: deleted,
            otherOwners: Set(otherOwned.compactMap { owners[$0] }).sorted(),
            otherOwned: otherOwned.count,
            scripts: scripts.compactMap(\.self)
        )
    }

    private static func paths(in list: Data?) -> [String] {
        String(decoding: list ?? Data(), as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0 != "/" && $0 != "/." }
    }

    /// `S_IFDIR` and the like for what is at a listed path, the link itself
    /// when it is one; nil when nothing is there.
    private static func fileType(of path: String) -> mode_t? {
        var status = stat()
        return lstat(JailbreakRoot.diskPath(ofListed: path), &status) == 0 ? status.st_mode & S_IFMT : nil
    }

    /// Which other installed package lists each of `paths`. Every list is
    /// read against the few paths asked about, so nothing the size of the
    /// whole database is built.
    private static func owners(of paths: Set<String>, in info: String, besides identity: String) -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let lists = (try? FileManager.default.contentsOfDirectory(atPath: info)) ?? []
        for file in lists where file.hasSuffix(".list") && file != identity + ".list" {
            for path in Self.paths(in: FileManager.default.contents(atPath: info + "/" + file)) where paths.contains(path) {
                result[path] = String(file.dropLast(".list".count))
            }
        }
        return result
    }
}

extension QueueChange {
    /// The package page has something to read: dpkg's own files for a
    /// removal, the package file for anything else once it is here.
    @MainActor
    var isInspectable: Bool {
        kind == .remove || package.isOnDisk
    }
}
