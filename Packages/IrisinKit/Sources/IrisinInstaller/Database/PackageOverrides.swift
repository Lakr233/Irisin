import Foundation
import IrisinProtocol

/// The diversions and statoverrides dpkg keeps, and the accounts they and
/// the archives name, as the bootstrap knows them. Read when a transaction
/// starts, again after each preinst and before each removal: a script may
/// have run dpkg-divert, dpkg-statoverride or added an account.
///
/// dpkg reads the statoverrides only to unpack (`archivefiles`), and
/// `dpkg -r` or `--configure` passes an override that names an account
/// nobody has: `statoverrides` is false for a transaction that unpacks
/// nothing, and none are read.
struct PackageOverrides {
    private var diversions: [String: (String, String)] = [:]
    private var overrides: [String: (UInt32, UInt32, UInt32)] = [:]
    private let accounts: BootstrapAccounts

    init(directory: URL, layout: BootstrapLayout, statoverrides: Bool) throws {
        accounts = BootstrapAccounts(layout: layout)
        let diversionURL = directory.appendingPathComponent("diversions")
        if FileManager.default.fileExists(atPath: diversionURL.path) {
            let lines = try String(contentsOf: diversionURL, encoding: .utf8).split(separator: "\n").map(String.init)
            guard lines.count % 3 == 0 else { throw PackageFailure("Invalid diversions database") }
            for i in stride(from: 0, to: lines.count, by: 3) {
                diversions[lines[i]] = (lines[i + 1], lines[i + 2])
            }
        }
        let overrideURL = directory.appendingPathComponent("statoverride")
        if statoverrides, FileManager.default.fileExists(atPath: overrideURL.path) {
            for line in try String(contentsOf: overrideURL, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
                guard parts.count == 4, let mode = UInt32(parts[2], radix: 8) else {
                    throw PackageFailure("Invalid statoverride database")
                }
                // dpkg-statoverride writes an account it could not name as
                // `#<id>`; a bare number is what older tools wrote
                func number(_ text: String) -> UInt32? {
                    UInt32(text.hasPrefix("#") ? String(text.dropFirst()) : text)
                }
                // dpkg reads the whole file and stops at an account it
                // cannot name, wherever its path is (`ensure_statoverrides`)
                guard let uid = number(parts[0]) ?? accounts.user(parts[0]) else {
                    throw PackageFailure("Unknown user '\(parts[0])' in the statoverride for \(parts[3])")
                }
                guard let gid = number(parts[1]) ?? accounts.group(parts[1]) else {
                    throw PackageFailure("Unknown group '\(parts[1])' in the statoverride for \(parts[3])")
                }
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

    /// The owner dpkg gives an entry it unpacks at `path`: the
    /// statoverride's (`tarobject`), else the user and group the archive
    /// names, when the bootstrap knows them, whatever numbers are stored
    /// beside the names (`tar_entry_update_from_system`). A package packed
    /// on a Mac without `--root-owner-group` says `root` next to its
    /// builder's uid, and dpkg installs it as root.
    func owner(_ path: String, of entry: PreparedEntry) -> (uid: UInt32, gid: UInt32) {
        if let (_, uid, gid) = overrides[path] {
            return (uid, gid)
        }
        return (
            entry.userName.flatMap(accounts.user) ?? entry.uid,
            entry.groupName.flatMap(accounts.group) ?? entry.gid
        )
    }
}
