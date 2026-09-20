import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// The scripts before the files, as dpkg's `process_archive` runs
    /// them: an old version that was configured hears `prerm upgrade` from
    /// half-configured and is unpacked after; the packages the new one
    /// breaks are deconfigured; the record is half-installed and needs
    /// reinstalling before the new preinst runs. Answers whether the old
    /// prerm ran, which a later abort has to undo.
    func prepareUpgrade(_ archive: PackageArchive, old: [String: String]?) throws -> Bool {
        let identity = archive.identity
        let version = archive.version
        let oldVersion = old?["version"] ?? ""
        var prermRan = false
        if let old, PackageDatabase.rank(PackageDatabase.state(of: old))
            >= PackageDatabase.rank("half-configured")
        {
            var fields = old
            PackageDatabase.setState("half-configured", in: &fields)
            try database.commit(identity, fields)
            prermRan = PackageDatabase.isConfigured(old)
            do {
                try scripts.run("prerm", identity: identity, arguments: ["upgrade", version])
            } catch {
                do {
                    guard let fallback = archive.package.controlFiles["prerm"] else { throw error }
                    try scripts.run(
                        "prerm",
                        identity: identity,
                        architecture: archive.architecture,
                        arguments: ["failed-upgrade", oldVersion, version],
                        source: archive.content(fallback)
                    )
                } catch {
                    if prermRan {
                        try? scripts.run("postinst", identity: identity, arguments: ["abort-upgrade", version])
                        PackageDatabase.setState(PackageDatabase.configuredState(old), in: &fields)
                        try? database.commit(identity, fields)
                    }
                    throw error
                }
            }
            PackageDatabase.setState("unpacked", in: &fields)
            try database.commit(identity, fields)
        }
        try deconfigureBrokenPackages(for: archive)
        // Commit a recoverable state before the preinst can touch anything;
        // only a complete payload and control-file commit advance from it.
        var fields = old ?? ["package": identity, "version": version, "architecture": archive.architecture]
        fields["config-version"] = old.flatMap(PackageDatabase.configuredVersion)
        fields["status"] = "install reinstreq half-installed"
        try database.commit(identity, fields)
        try runPreinst(archive, old: old, prermRan: prermRan)
        return prermRan
    }

    private func deconfigureBrokenPackages(for archive: PackageArchive) throws {
        // Breaks permits coexistence only after notifying the configured victim.
        for identity in database.records.keys.sorted() where identity != archive.identity {
            guard var fields = database.records[identity], PackageDatabase.isConfigured(fields) else { continue }
            let broken = try PackageRelations.relates(archive.fields, .breaks, to: fields)
                || PackageRelations.relates(fields, .breaks, to: archive.fields)
            guard broken else { continue }
            PackageDatabase.setState("half-configured", in: &fields)
            try database.commit(identity, fields)
            try scripts.run(
                "prerm",
                identity: identity,
                arguments: ["deconfigure", "in-favour", archive.identity, archive.version]
            )
            PackageDatabase.setState("unpacked", in: &fields)
            try database.commit(identity, fields)
        }
    }

    private func runPreinst(_ archive: PackageArchive, old: [String: String]?, prermRan: Bool) throws {
        guard let preinst = archive.package.controlFiles["preinst"] else { return }
        let oldVersion = old?["version"] ?? ""
        var arguments = [PackageDatabase.isPresent(old) ? "upgrade" : "install"]
        if !oldVersion.isEmpty {
            arguments += [oldVersion, archive.version]
        }
        do {
            try scripts.run(
                "preinst",
                identity: archive.identity,
                architecture: archive.architecture,
                arguments: arguments,
                source: archive.content(preinst)
            )
        } catch {
            abortUnpack(archive, old: old, prermRan: prermRan)
            throw error
        }
    }

    /// The old postrm hears `upgrade` once the new files are in place and
    /// before the old version's leftover files go. When it and the new
    /// postrm's `failed-upgrade` both fail, the old preinst hears
    /// `abort-upgrade` before the unpack is abandoned.
    func finishUpgrade(_ archive: PackageArchive, old: [String: String]?) throws {
        guard PackageDatabase.isPresent(old) else { return }
        do {
            try scripts.run("postrm", identity: archive.identity, arguments: ["upgrade", archive.version])
        } catch {
            do {
                guard let fallback = archive.package.controlFiles["postrm"] else { throw error }
                try scripts.run(
                    "postrm",
                    identity: archive.identity,
                    architecture: archive.architecture,
                    arguments: ["failed-upgrade", old?["version"] ?? "", archive.version],
                    source: archive.content(fallback)
                )
            } catch {
                try? scripts.run("preinst", identity: archive.identity, arguments: ["abort-upgrade", archive.version])
                throw error
            }
        }
    }
}
