import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// Put the verified payloads in place before any package script runs.
    /// The ordinary stages still unpack each archive, write its dpkg record,
    /// run its scripts and configure it. This preliminary pass is only for
    /// fresh packages, where a script may need a program shipped by another
    /// member of the same transaction.
    func seedPayloads(_ identities: [String], archives: [String: PackageArchive]) throws {
        do {
            for identity in identities {
                guard let archive = archives[identity] else {
                    throw PackageFailure("Missing prepared package: \(identity)")
                }
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
                for entry in entries where entry.kind != .hardLink {
                    if entry.kind == .directory, filesystem.isScaffolding("/" + entry.path) {
                        continue
                    }
                    let path = "/" + entry.path
                    let destination = try filesystem.location(overrides.path(path, owner: identity), for: entry)
                    let attributes = overrides.attributes(path)
                    try filesystem.install(
                        entry,
                        from: archive,
                        at: destination,
                        mode: attributes?.mode,
                        owner: attributes.map { ($0.uid, $0.gid) }
                    )
                }
                for entry in entries where entry.kind == .hardLink {
                    let targetPath = try archive.regularFileTarget(of: entry)
                    let target = try filesystem.location(overrides.path("/" + targetPath, owner: identity))
                    let path = "/" + entry.path
                    let destination = try filesystem.location(overrides.path(path, owner: identity))
                    let attributes = overrides.attributes(path)
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
            try filesystem.finish()
        } catch {
            try filesystem.rollback()
            throw error
        }
    }
}
