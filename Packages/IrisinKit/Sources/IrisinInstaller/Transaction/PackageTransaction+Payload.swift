import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// The archive's entries, into place. A conffile goes where dpkg would
    /// put it: over an unchanged file, beside a changed one as .dpkg-dist,
    /// nowhere when the administrator deleted it and the package did not
    /// change it.
    func installPayload(
        _ identity: String,
        archive: PackageArchive,
        conffiles: inout Conffiles
    ) throws {
        let declarations = try Conffiles.declarations(archive.controlText("conffiles"))
        let entries = archive.package.entries.sorted { lhs, rhs in
            if lhs.kind == .directory, rhs.kind != .directory {
                return true
            }
            if rhs.kind == .directory, lhs.kind != .directory {
                return false
            }
            if lhs.kind == .hardLink, rhs.kind != .hardLink {
                return false
            }
            if rhs.kind == .hardLink, lhs.kind != .hardLink {
                return true
            }
            return lhs.path < rhs.path
        }
        var pendingLinks: [PreparedEntry] = []
        // hard links come last, so the position in `entries` is the count
        for (placed, entry) in entries.enumerated() {
            if placed * 100 / entries.count != (placed + 1) * 100 / entries.count {
                emit(.packageProgress(identity: identity, completed: placed + 1, total: entries.count))
            }
            if entry.kind == .directory, filesystem.isScaffolding("/" + entry.path) {
                continue
            }
            if entry.kind == .hardLink {
                pendingLinks.append(entry)
                continue
            }
            let path = "/" + entry.path
            let actual = overrides.path(path, owner: identity)
            var destination = try filesystem.location(actual, for: entry)
            if declarations.keep.contains(path), let file = entry.file {
                // an old conffile that is this file hands its hash over, as
                // `pkg_remove_old_files` does
                if conffiles.hashes[path] == nil, let current = FileIdentity(destination),
                   let old = try conffiles.hashes.keys.first(where: {
                       try FileIdentity(filesystem.location(overrides.path($0, owner: identity))) == current
                   })
                {
                    conffiles.hashes[path] = conffiles.hashes[old]
                }
                guard let selected = try conffiles.destination(
                    for: path,
                    at: destination,
                    incoming: file.md5,
                    filesystem: filesystem
                ) else { continue }
                destination = selected
            }
            let attributes = overrides.attributes(path)
            try filesystem.install(
                entry,
                from: archive,
                at: destination,
                mode: attributes?.mode,
                owner: attributes.map { ($0.uid, $0.gid) }
            )
        }
        for entry in pendingLinks {
            let targetPath = try archive.regularFileTarget(of: entry)
            let target = try filesystem.location(overrides.path("/" + targetPath, owner: identity))
            let destination = try filesystem.location(overrides.path("/" + entry.path, owner: identity))
            let attributes = overrides.attributes("/" + entry.path)
            try filesystem.install(
                entry,
                from: archive,
                at: destination,
                hardLinkTarget: target,
                mode: attributes?.mode,
                owner: attributes.map { ($0.uid, $0.gid) }
            )
        }
    }

    /// dpkg's `pkg_remove_old_files`, after the old postrm has run: the
    /// conffiles the package asked to remove on upgrade go first, kept as
    /// .dpkg-old when changed locally; then every file the old version had
    /// and the new one does not, except conffiles, which stay on disk as
    /// obsolete. A path still shipped but no longer a conffile leaves the
    /// Conffiles field. Returns the paths taken away, for the file triggers.
    func removeOldFiles(
        _ identity: String,
        archive: PackageArchive,
        owners: [String: [String]],
        conffiles: inout Conffiles
    ) throws -> [String] {
        let declarations = try Conffiles.declarations(archive.controlText("conffiles"))
        let newPaths = archive.absolutePaths
        var removed: [String] = []
        for path in declarations.remove.sorted() {
            let previous = conffiles.hashes[path]
            conffiles.hashes[path] = previous ?? "newconffile"
            conffiles.removeOnUpgrade.insert(path)
            conffiles.obsolete.remove(path)
            // another package's file is not this package's to remove
            guard owners[path] == nil else { continue }
            let location = try filesystem.location(overrides.path(path, owner: identity))
            guard let target = try Conffiles.dereference(location, filesystem: filesystem) else { continue }
            try filesystem.remove(location.appendingPathExtension("dpkg-dist"))
            guard filesystem.exists(target) else { continue }
            if (try? PackageArchive.digest(target, md5: true)) == previous {
                emit(.notice("Removing obsolete conffile \(path)"))
                try filesystem.remove(target)
            } else {
                emit(.notice("Obsolete conffile \(path) has been modified locally, saving as \(path).dpkg-old"))
                let saved = target.appendingPathExtension("dpkg-old")
                try filesystem.backup(saved)
                try filesystem.backup(target)
                guard rename(target.path, saved.path) == 0 else {
                    throw PackageFailure("Cannot rename obsolete conffile \(path)")
                }
                try filesystem.noteWritten(saved)
                try filesystem.noteRemoved(target)
            }
            removed.append(path)
        }
        let oldFiles = try database.files(identity).filter { !newPaths.contains($0) && owners[$0] == nil }
        // an old path that reaches a new file through a directory link is
        // that file: `Library/MobileSubstrate/DynamicLibraries/x.dylib` once
        // ElleKit links the directory to `usr/lib/TweakInject`. Nothing is
        // there to compare against on a first install, where asking what a
        // theme's four thousand new paths lead to is four thousand stats for
        // a set nothing reads.
        var installed = Set<FileIdentity>()
        for path in oldFiles.isEmpty ? [] : newPaths where !filesystem.isScaffolding(path) {
            if let file = try FileIdentity(filesystem.location(overrides.path(path, owner: identity))) {
                installed.insert(file)
            }
        }
        for path in oldFiles.sorted(by: { $0.count > $1.count }) {
            if filesystem.isScaffolding(path) || declarations.remove.contains(path) {
                continue
            }
            let actual = overrides.path(path, owner: identity)
            if try filesystem.isPackageDatabasePath(actual) {
                continue
            }
            let location = try filesystem.location(actual)
            if let file = FileIdentity(location), installed.contains(file) {
                // a conffile's hash went to the new path at install
                conffiles.hashes.removeValue(forKey: path)
                conffiles.obsolete.remove(path)
                conffiles.removeOnUpgrade.remove(path)
                continue
            }
            if conffiles.hashes[path] != nil {
                conffiles.obsolete.insert(path)
                continue
            }
            if try !filesystem.remove(location) {
                removed.append(path)
            }
        }
        for path in conffiles.hashes.keys
            where newPaths.contains(path) && !declarations.keep.contains(path) && !declarations.remove.contains(path)
        {
            conffiles.hashes.removeValue(forKey: path)
            conffiles.obsolete.remove(path)
            conffiles.removeOnUpgrade.remove(path)
        }
        return removed
    }
}
