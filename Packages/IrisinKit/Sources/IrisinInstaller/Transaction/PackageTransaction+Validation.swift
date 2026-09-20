import Darwin
import Foundation
import IrisinProtocol

extension PackageTransaction {
    /// Recovery bypasses relationships, never the user's system-package protection.
    func validateRecoveryRemoval(_ transaction: InstallerJob.Transaction) throws {
        for identity in transaction.remove {
            guard let fields = database.records[identity] else {
                throw PackageFailure("Cannot remove absent package: \(identity)")
            }
            let system = fields["essential"] == "yes" || fields["protected"] == "yes"
                || ["apt", "dpkg", "essential", "firmware", "bash", "coreutils",
                    "base", "base-files", "base-passwd", "libroot", "roothide"].contains(identity)
            if system && !transaction.allowSystemRemoval || fields["status"]?.hasPrefix("hold ") == true {
                throw PackageFailure("Cannot remove protected or held package: \(identity)")
            }
        }
    }

    /// What dpkg checks before it acts: the packages this transaction
    /// unpacks or configures must have their dependencies in the final
    /// state, nothing left may depend on what it removes, and a package it
    /// unpacks may not conflict with or break what stays. A dependency
    /// already broken among packages the transaction does not touch is
    /// not its concern, as it is not dpkg's.
    func validateFinalState(_ transaction: InstallerJob.Transaction, archives: [String: PackageArchive]) throws {
        var final = database.records.filter { _, fields in PackageDatabase.isPresent(fields) }
        var gone: [[String: String]] = []
        for identity in transaction.remove {
            if let fields = final[identity] {
                let system = fields["essential"] == "yes" || fields["protected"] == "yes"
                if system && !transaction.allowSystemRemoval || fields["status"]?.hasPrefix("hold ") == true {
                    throw PackageFailure("Cannot remove protected or held package: \(identity)")
                }
            }
            if let fields = final.removeValue(forKey: identity) {
                gone.append(fields)
            }
        }
        for (identity, archive) in archives {
            if final[identity]?["status"]?.hasPrefix("hold ") == true {
                throw PackageFailure("Cannot replace held package: \(identity)")
            }
            final[identity] = archive.fields
        }
        let records = Array(final.values)
        var affected = Set(archives.keys).union(transaction.configureExisting)
        for (identity, fields) in final where !affected.contains(identity) {
            for kind in [.depends, .preDepends] as [PackageRelations.Group.Kind] {
                if try gone.contains(where: { try PackageRelations.relates(fields, kind, to: $0) }) {
                    affected.insert(identity)
                }
            }
        }
        for identity in affected.sorted() {
            guard let fields = final[identity] else { continue }
            try PackageRelations.dependencies(fields, kinds: [.depends, .preDepends], available: records)
        }
        for (identity, archive) in archives {
            for (other, target) in final where other != identity {
                if try PackageRelations.relates(archive.fields, .conflicts, to: target)
                    || PackageRelations.relates(archive.fields, .breaks, to: target)
                    || PackageRelations.relates(target, .conflicts, to: archive.fields)
                    || PackageRelations.relates(target, .breaks, to: archive.fields)
                {
                    throw PackageFailure("Conflicting final packages: \(identity), \(other)")
                }
            }
        }
    }
}
