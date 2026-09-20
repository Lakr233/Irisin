import Darwin
import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// dpkg's `deferred_remove` and `removal_bulk`: a configured package
    /// hears `prerm remove` from half-configured; the files go while the
    /// record is half-installed (and fine: dpkg refuses to touch a
    /// package that needs reinstalling); the postrm hears `remove`; the
    /// info files go but the list and the postrm; and the record is
    /// config-files, or gone altogether when there is no postrm and no
    /// conffile to keep it for. A package already down to its config files
    /// is purged.
    func remove(_ identity: String) throws {
        guard var fields = database.records[identity] else {
            throw PackageFailure("Cannot remove absent package")
        }
        let original = fields
        // a removal that stops halfway still knows what was configured
        fields["config-version"] = PackageDatabase.configuredVersion(original)
        let state = PackageDatabase.state(of: fields)
        guard state != "not-installed" else { throw PackageFailure("Cannot remove absent package") }
        emit(.package(.removing, identity: identity, version: fields["version"] ?? ""))
        if state == "config-files" {
            return try purge(identity, fields)
        }
        try triggers.changed(identity, paths: [])
        if PackageDatabase.rank(state) >= PackageDatabase.rank("half-configured") {
            fields["status"] = "deinstall ok half-configured"
            try database.commit(identity, fields)
            do { try scripts.run("prerm", identity: identity, arguments: ["remove"]) }
            catch {
                if PackageDatabase.isConfigured(original) {
                    try? scripts.run("postinst", identity: identity, arguments: ["abort-remove"])
                    PackageDatabase.setState(PackageDatabase.configuredState(original), in: &fields)
                    try? database.commit(identity, fields)
                }
                throw error
            }
        }
        overrides = try PackageOverrides(directory: database.directory)
        fields["status"] = "deinstall ok half-installed"
        try database.commit(identity, fields)

        let files = try database.files(identity)
        let conffiles = try Conffiles(status: fields["conffiles"])
        var otherFiles = Set<String>()
        for other in database.records.keys where other != identity {
            try otherFiles.formUnion(database.files(other))
        }
        var leftover: [String] = []
        var removed: [String] = []
        do {
            for path in files.sorted(by: { $0.count > $1.count }) {
                if conffiles.hashes[path] != nil {
                    leftover.append(path)
                    continue
                }
                if filesystem.isScaffolding(path) || otherFiles.contains(path) {
                    continue
                }
                let actual = overrides.path(path, owner: identity)
                if try filesystem.isPackageDatabasePath(actual) {
                    leftover.append(path)
                    continue
                }
                if try filesystem.remove(filesystem.location(actual)) {
                    leftover.append(path)
                } else {
                    removed.append(path)
                }
            }
            try filesystem.finish()
        } catch { try filesystem.rollback(); throw error }
        try writeInfo(identity, member: "list", text: leftover.sorted().map { $0 + "\n" }.joined())
        try scripts.run("postrm", identity: identity, arguments: ["remove"])
        for member in try database.infoMembers(identity) where member != "list" && member != "postrm" {
            try FileManager.default.removeItem(at: database.info(identity, member))
        }
        try triggers.synchronize()
        fields.removeValue(forKey: "essential")
        fields.removeValue(forKey: "protected")
        fields["status"] = "deinstall ok config-files"
        try database.commit(identity, fields)
        if conffiles.hashes.isEmpty, !FileManager.default.fileExists(atPath: database.info(identity, "postrm").path) {
            // no config files and no postrm: dpkg goes straight to purge
            try purgeRecord(identity)
        }
        try triggers.activateFileTriggers(removed, by: identity)
    }

    /// dpkg's `removal_bulk_remove_configfiles`: the conffiles and the
    /// copies dpkg keeps beside them go, the postrm hears `purge`, and the
    /// package is not installed at all.
    private func purge(_ identity: String, _ fields: [String: String]) throws {
        try triggers.changed(identity, paths: [])
        let conffiles = try Conffiles(status: fields["conffiles"])
        var removed: [String] = []
        do {
            for path in conffiles.hashes.keys.sorted(by: { $0.count > $1.count }) {
                let location = try filesystem.location(overrides.path(path, owner: identity))
                for suffix in ["dpkg-dist", "dpkg-old", "dpkg-bak", "dpkg-new", "dpkg-tmp", "~"] {
                    let variant = suffix == "~"
                        ? URL(fileURLWithPath: location.path + "~")
                        : location.appendingPathExtension(suffix)
                    try filesystem.remove(variant)
                }
                if try !filesystem.remove(location) {
                    removed.append(path)
                }
            }
            try filesystem.finish()
        } catch { try filesystem.rollback(); throw error }
        var fields = fields
        fields.removeValue(forKey: "conffiles")
        fields.removeValue(forKey: "config-version")
        fields["status"] = "purge ok config-files"
        try database.commit(identity, fields)
        try scripts.run("postrm", identity: identity, arguments: ["purge"])
        try purgeRecord(identity)
        try triggers.synchronize()
        try triggers.activateFileTriggers(removed, by: identity)
    }

    /// The end of dpkg's `removal_bulk` for a purge: the directories the
    /// removal could not empty get another try, the list and the postrm go,
    /// and the record is not written any more.
    private func purgeRecord(_ identity: String) throws {
        for path in try database.files(identity).sorted(by: { $0.count > $1.count }) {
            guard !filesystem.isScaffolding(path) else { continue }
            let actual = overrides.path(path, owner: identity)
            guard try !filesystem.isPackageDatabasePath(actual) else { continue }
            let location = try filesystem.location(actual)
            if filesystem.isDirectory(location) {
                try filesystem.remove(location)
            }
        }
        try filesystem.finish()
        for member in try database.infoMembers(identity) {
            try FileManager.default.removeItem(at: database.info(identity, member))
        }
        try database.remove(identity)
    }
}
