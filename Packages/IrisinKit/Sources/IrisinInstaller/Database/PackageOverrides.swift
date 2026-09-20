import Foundation

struct PackageOverrides {
    private var diversions: [String: (String, String)] = [:]
    private var overrides: [String: (UInt32, UInt32, UInt32)] = [:]

    init(directory: URL) throws {
        let diversionURL = directory.appendingPathComponent("diversions")
        if FileManager.default.fileExists(atPath: diversionURL.path) {
            let lines = try String(contentsOf: diversionURL, encoding: .utf8).split(separator: "\n").map(String.init)
            guard lines.count % 3 == 0 else { throw PackageFailure("Invalid diversions database") }
            for i in stride(from: 0, to: lines.count, by: 3) {
                diversions[lines[i]] = (lines[i + 1], lines[i + 2])
            }
        }
        let overrideURL = directory.appendingPathComponent("statoverride")
        if FileManager.default.fileExists(atPath: overrideURL.path) {
            for line in try String(contentsOf: overrideURL, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
                guard parts.count == 4, let mode = UInt32(parts[2], radix: 8) else {
                    throw PackageFailure("Invalid statoverride database")
                }
                /// dpkg-statoverride writes an account it could not name as
                /// `#<id>`; a bare number is what older tools wrote
                func number(_ text: String) -> UInt32? {
                    UInt32(text.hasPrefix("#") ? String(text.dropFirst()) : text)
                }
                let uid = number(parts[0]) ?? getpwnam(parts[0])?.pointee.pw_uid
                let gid = number(parts[1]) ?? getgrnam(parts[1])?.pointee.gr_gid
                guard let uid, let gid else { throw PackageFailure("Unknown statoverride account") }
                overrides[parts[3]] = (mode, uid, gid)
            }
        }
    }

    func path(_ original: String, owner: String) -> String {
        guard let (destination, package) = diversions[original], package != owner else { return original }
        return destination
    }

    /// The package that diverted this path, if a package did: dpkg lets it
    /// and the package whose file it diverts share the path.
    func diverter(of original: String) -> String? {
        guard let (_, package) = diversions[original], package != ":" else { return nil }
        return package
    }

    func attributes(_ path: String) -> (mode: UInt32, uid: UInt32, gid: UInt32)? {
        overrides[path]
    }
}
