import Darwin
import Foundation
import IrisinProtocol

extension NativePackageTransaction {
    /// Recovery bypasses relationships, never the user's system-package protection.
    func validateRecoveryRemoval(_ transaction: InstallerJob.Transaction) throws {
        for identity in transaction.remove {
            guard let fields = database.records[identity] else {
                throw NativePackageFailure("Cannot remove absent package: \(identity)")
            }
            let system = fields["essential"] == "yes" || fields["protected"] == "yes"
                || ["apt", "dpkg", "essential", "firmware", "bash", "coreutils",
                    "base", "base-files", "base-passwd", "libroot", "roothide"].contains(identity)
            if system && !transaction.allowSystemRemoval || fields["status"]?.hasPrefix("hold ") == true {
                throw NativePackageFailure("Cannot remove protected or held package: \(identity)")
            }
        }
    }

    /// What dpkg checks before it acts: the packages this transaction
    /// unpacks or configures must have their dependencies in the final
    /// state, nothing left may depend on what it removes, and a package it
    /// unpacks may not conflict with or break what stays. A dependency
    /// already broken among packages the transaction does not touch is
    /// not its concern, as it is not dpkg's.
    func validateFinalState(_ transaction: InstallerJob.Transaction, archives: [String: NativePackageArchive]) throws {
        var final = database.records.filter { _, fields in NativePackageDatabase.isPresent(fields) }
        var gone: [[String: String]] = []
        for identity in transaction.remove {
            if let fields = final[identity] {
                let system = fields["essential"] == "yes" || fields["protected"] == "yes"
                if system && !transaction.allowSystemRemoval || fields["status"]?.hasPrefix("hold ") == true {
                    throw NativePackageFailure("Cannot remove protected or held package: \(identity)")
                }
            }
            if let fields = final.removeValue(forKey: identity) {
                gone.append(fields)
            }
        }
        for (identity, archive) in archives {
            if final[identity]?["status"]?.hasPrefix("hold ") == true {
                throw NativePackageFailure("Cannot replace held package: \(identity)")
            }
            final[identity] = archive.fields
        }
        let records = Array(final.values)
        var affected = Set(archives.keys).union(transaction.configureExisting)
        for (identity, fields) in final where !affected.contains(identity) {
            for kind in [.depends, .preDepends] as [NativePackageRelations.Group.RequirementType] {
                if try gone.contains(where: { try NativePackageRelations.relates(fields, kind, to: $0) }) {
                    affected.insert(identity)
                }
            }
        }
        for identity in affected.sorted() {
            guard let fields = final[identity] else { continue }
            try NativePackageRelations.dependencies(fields, kinds: [.depends, .preDepends], available: records)
        }
        for (identity, archive) in archives {
            for (other, target) in final where other != identity {
                if try NativePackageRelations.relates(archive.fields, .conflicts, to: target)
                    || NativePackageRelations.relates(archive.fields, .breaks, to: target)
                    || NativePackageRelations.relates(target, .conflicts, to: archive.fields)
                    || NativePackageRelations.relates(target, .breaks, to: archive.fields)
                {
                    throw NativePackageFailure("Conflicting final packages: \(identity), \(other)")
                }
            }
        }
    }
}
