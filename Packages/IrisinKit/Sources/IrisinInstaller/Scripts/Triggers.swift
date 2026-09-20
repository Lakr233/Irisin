import Foundation
import IrisinProtocol

/// Maintains dpkg-compatible interest and pending-trigger records. Scripts may
/// enqueue Unincorp entries; the installer incorporates them without running
/// dpkg-trigger itself.
final class Triggers {
    let database: PackageDatabase
    let scripts: MaintainerScripts

    init(database: PackageDatabase, scripts: MaintainerScripts) {
        self.database = database
        self.scripts = scripts
    }

    /// dpkg's triggers directory, created if missing, and the record lock on
    /// its `Lock` file; the caller closes the lock.
    func lockTriggers() throws -> (URL, DpkgLock) {
        let directory = database.directory.appendingPathComponent("triggers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = try DpkgLock(path: directory.appendingPathComponent("Lock").path)
        return (directory, lock)
    }

    static func directives(_ text: String) throws -> [(String, String)] {
        try text.split(separator: "\n").compactMap { line in
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let words = body.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.isEmpty {
                return nil
            }
            let kinds = [
                "interest", "interest-await", "interest-noawait",
                "activate", "activate-await", "activate-noawait",
            ]
            guard words.count == 2, kinds.contains(words[0]),
                  !words[1].contains(".."), words[1].hasPrefix("/") || !words[1].contains("/")
            else { throw PackageFailure("Invalid trigger directive") }
            return (words[0], words[1])
        }
    }

    /// dpkg's `trig_record_activation`: only a package that is at least
    /// triggers-awaited takes a pending trigger; an unpacked one does not,
    /// its configure will run its postinst anyway. The activating package
    /// awaits it only when the interest says so and it is past config-files.
    func activate(_ trigger: String, by source: String?, awaitCompletion: Bool) throws {
        // A source read back from Unincorp is spelled however it was written.
        let source = source?.lowercased()
        for (identity, interestedAwait) in try registrations()[trigger] ?? [] {
            guard var fields = database.records[identity],
                  PackageDatabase.isConfigured(fields) else { continue }
            var pending = Set((fields["triggers-pending"] ?? "").split(separator: " ").map(String.init))
            let added = pending.insert(trigger).inserted
            fields["triggers-pending"] = pending.sorted().joined(separator: " ")
            PackageDatabase.setState(PackageDatabase.configuredState(fields), in: &fields)
            if added {
                try database.commit(identity, fields)
            }
            if let source, source != identity, awaitCompletion, interestedAwait,
               var awaiting = database.records[source], PackageDatabase.isPresent(awaiting)
            {
                var names = Set((awaiting["triggers-awaited"] ?? "").split(separator: " ").map(String.init))
                guard names.insert(identity).inserted else { continue }
                awaiting["triggers-awaited"] = names.sorted().joined(separator: " ")
                if PackageDatabase.rank(PackageDatabase.state(of: awaiting))
                    > PackageDatabase.rank("triggers-awaited")
                {
                    PackageDatabase.setState("triggers-awaited", in: &awaiting)
                }
                try database.commit(source, awaiting)
            }
        }
    }

    /// The package's own `activate` directives, dpkg's
    /// `trig_activate_packageprocessing`, plus the file triggers its `paths`
    /// touch: the files it unpacked, or the ones it just removed.
    func changed(_ identity: String, paths: [String], declarations: String? = nil) throws {
        let path = database.info(identity, "triggers")
        let text = try declarations
            ?? (FileManager.default.fileExists(atPath: path.path) ? String(contentsOf: path, encoding: .utf8) : "")
        for (directive, trigger) in try Self.directives(text) where directive.hasPrefix("activate") {
            try activate(trigger, by: identity, awaitCompletion: !directive.hasSuffix("noawait"))
        }
        try activateFileTriggers(paths, by: identity)
    }

    /// dpkg's `trig_path_activate`: every file trigger whose path is one
    /// of these or a parent of one.
    func activateFileTriggers(_ paths: [String], by identity: String) throws {
        guard !paths.isEmpty else { return }
        for trigger in try registrations().keys
            where trigger.hasPrefix("/") && paths.contains(where: { $0 == trigger || $0.hasPrefix(trigger + "/") })
        {
            try activate(trigger, by: identity, awaitCompletion: true)
        }
    }
}
