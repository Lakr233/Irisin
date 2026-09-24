import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// Check ownership for every preliminary payload before the first file
    /// is placed. The normal unpack will check again against the database
    /// as each package becomes recorded there.
    func validateBootstrapPayloads(_ identities: [String], archives: [String: PackageArchive]) throws {
        var seen: [String: String] = [:]
        for identity in identities {
            guard let archive = archives[identity] else {
                throw PackageFailure("Missing prepared package: \(identity)")
            }
            _ = try validateOwnership(archive, owners: fileOwners(excluding: identity))
            for entry in archive.package.entries where entry.kind != .directory {
                let path = overrides.path("/" + entry.path, owner: identity)
                if let previous = seen[path], previous != identity, let first = archives[previous],
                   try !PackageRelations.relates(archive.fields, .replaces, to: first.fields),
                   try !PackageRelations.relates(first.fields, .replaces, to: archive.fields)
                {
                    throw PackageFailure("\(path) is in both \(previous) and \(identity); Replaces is required")
                }
                seen[path] = identity
            }
        }
    }

    /// dpkg's `process_archive`, in its order: the Pre-Depends check, the
    /// old prerm, the new preinst, the files, the old postrm, the old
    /// version's leftover files, the ownership changes, then the record.
    /// A failure after the preinst runs the abort scripts dpkg would and
    /// puts the record back where it was.
    func unpack(_ identity: String, archive: PackageArchive) throws {
        emit(.package(.unpacking, identity: identity, version: archive.version))
        let old = database.records[identity]
        var conffiles = try Conffiles(status: old?["conffiles"])
        if !recoveryMode {
            try PackageRelations.dependencies(
                archive.fields,
                kinds: [.preDepends],
                available: database.predependencyWitnesses,
                unconfigured: true
            )
        }
        let declarations = try Conffiles.declarations(archive.controlText("conffiles"))
        for entry in archive.package.entries where declarations.remove.contains("/" + entry.path) {
            throw PackageFailure("Obsolete conffile is still in data archive: /\(entry.path)")
        }
        // the activate directives of the old version and of the new one both
        // fire at unpack
        try triggers.changed(identity, paths: [])
        try triggers.changed(identity, paths: [], declarations: archive.controlText("triggers") ?? "")
        let prermRan = try prepareUpgrade(archive, old: old)
        // preinst may use the device's dpkg-divert or dpkg-statoverride.
        // Observe those committed changes before choosing any destination.
        overrides = try PackageOverrides(directory: database.directory)

        var removed: [String] = []
        do {
            let owners = try fileOwners(excluding: identity)
            let kept = try validateOwnership(archive, owners: owners)
            try installPayload(identity, archive: archive, conffiles: &conffiles)
            try finishUpgrade(archive, old: old)
            removed = try removeOldFiles(identity, archive: archive, owners: owners, conffiles: &conffiles)
            try installControlFiles(identity, archive: archive)
            // dpkg writes the hashes itself for a package that ships none
            if archive.package.controlFiles["md5sums"] == nil {
                let hashes = try archive.generatedHashes(excluding: declarations.keep)
                try writeInfo(identity, member: "md5sums", text: hashes)
            }
            // a conffile removed on upgrade stays in the field, not in the list
            let paths = archive.absolutePaths
                .union(conffiles.hashes.keys.filter { !conffiles.removeOnUpgrade.contains($0) })
            try writeInfo(identity, member: "list", text: paths.sorted().joined(separator: "\n") + "\n")
            try disappearOthers(replacedBy: archive, owners: owners)
            try transferOwnership(to: archive, owners: owners, kept: kept)
            var fields = archive.fields
            fields["conffiles"] = conffiles.hashes.isEmpty ? nil : conffiles.status
            fields["config-version"] = old.flatMap(PackageDatabase.configuredVersion)
            // what the package still awaits survives its upgrade
            fields["triggers-awaited"] = old?["triggers-awaited"]
            fields["status"] = "install ok unpacked"
            try filesystem.finish()
            database.noteFieldNames(identity, control: archive.package.control)
            try database.commit(identity, fields)
        } catch {
            try filesystem.rollback()
            abortUnpack(archive, old: old, prermRan: prermRan)
            throw error
        }
        try triggers.synchronize()
        try triggers.activateFileTriggers(archive.absolutePaths + removed, by: identity)
    }

    /// dpkg's `tarobject` on a path another package lists: fine when that
    /// package only has config files left, when one of the two diverted the
    /// path, or when the new package Replaces the other; an error otherwise.
    /// A path another package's diversion moved its file to is never
    /// overwritten. A link the filesystem keeps a directory for is shared,
    /// like a directory; those paths are returned, as the preinst left them.
    private func validateOwnership(_ archive: PackageArchive, owners: [String: [String]]) throws -> Set<String> {
        var kept = Set<String>()
        for entry in archive.package.entries where entry.kind != .directory {
            let path = "/" + entry.path
            let actual = overrides.path(path, owner: archive.identity)
            if try filesystem.keepsDirectory(entry, at: filesystem.location(actual)) {
                kept.insert(path)
                continue
            }
            if actual != path, let others = owners[actual], !others.isEmpty {
                throw PackageFailure(
                    "\(actual) is the diverted version of a file in \(others.joined(separator: ", "))"
                )
            }
            for owner in owners[path] ?? [] {
                guard let fields = database.records[owner] else { continue }
                if let diverter = overrides.diverter(of: path), diverter == owner || diverter == archive.identity {
                    continue
                }
                if PackageDatabase.state(of: fields) == "config-files" {
                    continue
                }
                guard try PackageRelations.relates(archive.fields, .replaces, to: fields) else {
                    throw PackageFailure("\(path) is owned by \(owner); Replaces is required")
                }
            }
        }
        return kept
    }

    private func fileOwners(excluding identity: String) throws -> [String: [String]] {
        var owners: [String: [String]] = [:]
        for package in database.records.keys where package != identity {
            for path in try database.files(package) {
                owners[path, default: []].append(package)
            }
        }
        return owners
    }

    private func transferOwnership(
        to archive: PackageArchive,
        owners: [String: [String]],
        kept: Set<String>
    ) throws {
        let paths = Set(archive.package.entries.filter { $0.kind != .directory }.map { "/" + $0.path })
            .subtracting(kept)
        let previousOwners = Set(paths.flatMap { owners[$0] ?? [] })
        // a package that just disappeared has no list to keep; a diverted
        // path stays with the diverter, and with everyone when it is ours
        for owner in previousOwners where database.records[owner] != nil {
            let remaining = try database.files(owner).filter { path in
                let diverter = overrides.diverter(of: path)
                return !paths.contains(path) || diverter == archive.identity || diverter == owner
            }
            try writeInfo(owner, member: "list", text: remaining.joined(separator: "\n") + "\n")
        }
    }

    /// dpkg's `pkg_disappear_others`: a package whose every file the new
    /// package took over, and that nothing present depends on, is gone: its
    /// postrm hears `disappear`, its info files and its record go. A path a
    /// third package lists is that package's to keep, as `filesavespackage`
    /// has it; a path either of the two diverted, or any other path, saves
    /// its package, a directory too. ElleKit,
    /// whose own `usr/lib/TweakInject` was taken for shared, disappeared
    /// under the first tweak installed after it, and took its link along
    /// when the tweak went.
    private func disappearOthers(replacedBy archive: PackageArchive, owners: [String: [String]]) throws {
        let paths = archive.absolutePaths
        let candidates = Set(paths.flatMap { owners[$0] ?? [] })
        for other in candidates.sorted() {
            guard let gone = database.records[other], PackageDatabase.isPresent(gone) else { continue }
            let files = try database.files(other)
            guard !files.isEmpty, files.allSatisfy({ path in
                let diverter = overrides.diverter(of: path)
                guard diverter != other, diverter != archive.identity else { return false }
                return paths.contains(path) || filesystem.isScaffolding(path)
                    // one that disappeared already takes nothing over
                    || (owners[path] ?? []).contains { $0 != other && database.records[$0] != nil }
            }) else { continue }
            var needed = false
            for (identity, dependent) in database.records
                where identity != other && PackageDatabase.isPresent(dependent)
            {
                let fields = identity == archive.identity ? archive.fields : dependent
                // Recommends keeps a package as well, for dpkg; the wire has
                // no kind for it, so its text is read as a Depends would be
                let recommends = fields["recommends"]
                    .flatMap { PackageRelations.Group(value: $0, type: .depends) }?.requirements ?? []
                if try PackageRelations.relates(fields, .depends, to: gone)
                    || PackageRelations.relates(fields, .preDepends, to: gone)
                    || recommends.contains(where: { $0.elements.contains { PackageRelations.matches($0, gone) } })
                {
                    needed = true
                    break
                }
            }
            if needed {
                continue
            }
            emit(.notice("\(other) has been completely replaced by \(archive.identity)"))
            // irreversible, as it is for dpkg: the info files are not journalled
            try scripts.run("postrm", identity: other, arguments: ["disappear", archive.identity, archive.version])
            for member in try database.infoMembers(other) {
                try FileManager.default.removeItem(at: database.info(other, member))
            }
            try database.remove(other)
        }
    }

    /// dpkg's cleanup handlers once the preinst has run: the new postrm
    /// hears `abort-install` or `abort-upgrade`, the record goes back to
    /// the state the old version was in, and an old version whose prerm
    /// ran gets its postinst `abort-upgrade` and is installed again. A
    /// cleanup script that fails leaves the record half-installed, and the
    /// package needs reinstalling.
    func abortUnpack(_ archive: PackageArchive, old: [String: String]?, prermRan: Bool) {
        let identity = archive.identity
        let state = PackageDatabase.state(of: old)
        var succeeded = true
        if let postrm = archive.package.controlFiles["postrm"] {
            let arguments: [String] = switch state {
            case "not-installed": ["abort-install"]
            case "config-files": ["abort-install", old?["version"] ?? "", archive.version]
            default: ["abort-upgrade", old?["version"] ?? "", archive.version]
            }
            do {
                try scripts.run(
                    "postrm",
                    identity: identity,
                    architecture: archive.architecture,
                    arguments: arguments,
                    source: archive.content(postrm)
                )
            } catch { succeeded = false }
        }
        if succeeded {
            do {
                if let old {
                    var fields = old
                    // dpkg selected the package for installation when it
                    // started, and an old version that heard prerm is unpacked
                    let restored = PackageDatabase.rank(state) >= PackageDatabase.rank("half-configured")
                        ? "unpacked" : state
                    fields["config-version"] = PackageDatabase.configuredVersion(old)
                    fields["status"] = "install ok " + restored
                    try database.commit(identity, fields)
                    if prermRan {
                        try scripts.run("postinst", identity: identity, arguments: ["abort-upgrade", archive.version])
                        PackageDatabase.setState(PackageDatabase.configuredState(fields), in: &fields)
                        try database.commit(identity, fields)
                    }
                } else {
                    try database.remove(identity)
                }
            } catch { succeeded = false }
        }
        if !succeeded {
            emit(.warning(.packageNeedsRepair(identity: identity)))
        }
    }
}
