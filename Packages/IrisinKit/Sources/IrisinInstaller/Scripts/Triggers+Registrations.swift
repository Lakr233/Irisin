import Foundation

extension Triggers {
    func registrations() throws -> [String: [(String, Bool)]] {
        var result: [String: [(String, Bool)]] = [:]
        for identity in database.records.keys.sorted() {
            guard let status = database.records[identity]?["status"],
                  !status.hasSuffix("config-files"), !status.hasSuffix("not-installed")
            else { continue }
            let path = database.info(identity, "triggers")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            for (directive, trigger) in try Self.directives(String(contentsOf: path, encoding: .utf8))
                where directive.hasPrefix("interest")
            {
                result[trigger, default: []].append((identity, !directive.hasSuffix("noawait")))
            }
        }
        return result
    }

    func synchronize() throws {
        let (directory, lock) = try lockTriggers()
        defer { lock.close() }
        let interests = try registrations()
        var files: [String] = []
        for (trigger, packages) in interests {
            let names = packages.map { $0.0 + ($0.1 ? "" : "/noawait") }.sorted()
            if trigger.hasPrefix("/") {
                files += names.map { trigger + " " + $0 }
            } else {
                // one interested package per line: dpkg reads each line of
                // an explicit trigger's file as one package name
                try PackageDatabase.write(
                    Data(names.map { $0 + "\n" }.joined().utf8),
                    to: directory.appendingPathComponent(trigger)
                )
            }
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path)
            where name != "Lock" && name != "File" && name != "Unincorp" && interests[name] == nil
        {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try PackageDatabase.write(
            Data(files.sorted().map { $0 + "\n" }.joined().utf8),
            to: directory.appendingPathComponent("File")
        )
    }
}
