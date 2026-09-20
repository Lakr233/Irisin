import Foundation

extension Triggers {
    private func incorporate() throws {
        let (directory, lock) = try lockTriggers()
        defer { lock.close() }
        let path = directory.appendingPathComponent("Unincorp")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        for line in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count >= 2 else { throw PackageFailure("Invalid pending trigger record") }
            for source in words.dropFirst() {
                try activate(words[0], by: source == "-" ? nil : source, awaitCompletion: source != "-")
            }
        }
        try PackageDatabase.write(Data(), to: path)
    }

    /// dpkg's `trigproc`: each package with pending triggers gets one
    /// `postinst triggered` call with every trigger name in one
    /// space-separated argument, and is then installed, or
    /// triggers-awaited while it still waits on another package. The
    /// commit takes it out of the awaited lists of the packages that were
    /// waiting on it.
    func process() throws {
        for _ in 0 ..< 100 {
            try incorporate()
            let pending = database.records.keys.sorted().filter {
                let fields = database.records[$0]!
                return fields["triggers-pending"] != nil && PackageDatabase.isConfigured(fields)
            }
            if pending.isEmpty {
                return
            }
            for identity in pending {
                var fields = database.records[identity]!
                let names = fields["triggers-pending"]!.split(separator: " ").map(String.init)
                scripts.emit(.package(.triggering, identity: identity, version: fields["version"] ?? ""))
                // half-configured first, which takes the pending triggers with
                // it: a postinst that fails leaves a package to configure, not
                // a trigger every later transaction runs into again
                PackageDatabase.setState("half-configured", in: &fields)
                try database.commit(identity, fields)
                fields = database.records[identity] ?? fields
                try scripts.run("postinst", identity: identity, arguments: ["triggered", names.joined(separator: " ")])
                PackageDatabase.setState(PackageDatabase.configuredState(fields), in: &fields)
                try database.commit(identity, fields)
            }
        }
        throw PackageFailure("Trigger processing did not converge")
    }
}
