import Darwin
import Foundation

/// The package's Conffiles field: each path with the hash of the version the
/// package last shipped, flagged `obsolete` when no version ships it any
/// more and `remove-on-upgrade` when the package asked for it to go.
struct Conffiles {
    var hashes: [String: String] = [:]
    var obsolete = Set<String>()
    var removeOnUpgrade = Set<String>()

    init(status: String?) throws {
        for line in (status ?? "").split(separator: "\n") {
            var fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !fields.isEmpty else { continue }
            // dpkg writes ` obsolete` then ` remove-on-upgrade` and reads
            // them back last word first; a line may carry either or both
            var flags = Set<String>()
            while let last = fields.last, last == "obsolete" || last == "remove-on-upgrade" {
                flags.insert(fields.removeLast())
            }
            guard fields.count >= 2, let hash = fields.popLast() else {
                throw PackageFailure("Invalid Conffiles status record")
            }
            let path = fields.joined(separator: " ")
            hashes[path] = hash
            if flags.contains("obsolete") {
                obsolete.insert(path)
            }
            if flags.contains("remove-on-upgrade") {
                removeOnUpgrade.insert(path)
            }
        }
    }

    var status: String {
        hashes.keys.sorted()
            .map {
                "\($0) \(hashes[$0]!)"
                    + (obsolete.contains($0) ? " obsolete" : "")
                    + (removeOnUpgrade.contains($0) ? " remove-on-upgrade" : "")
            }
            .joined(separator: "\n")
    }

    /// Match dpkg's keep-local policy. A deletion is a local change too; an
    /// unchanged vendor version must not recreate a file the user removed.
    /// The file is read through a symbolic link the administrator put in
    /// its place, as dpkg's `conffderef` does.
    mutating func destination(
        for path: String,
        at destination: URL,
        incoming: String,
        filesystem: PackageFilesystem
    ) throws -> URL? {
        let previous = hashes[path]
        guard let destination = try Self.dereference(destination, filesystem: filesystem) else {
            throw PackageFailure("Conffile is not a regular file: \(path)")
        }
        var info = stat()
        let exists = lstat(destination.path, &info) == 0
        let current = exists ? try PackageArchive.digest(destination, md5: true) : nil
        let changed = previous != nil ? current != previous : exists && current != incoming
        hashes[path] = incoming
        obsolete.remove(path)
        removeOnUpgrade.remove(path)
        guard changed else { return destination }
        guard previous != incoming else { return nil }
        return destination.appendingPathExtension("dpkg-dist")
    }

    /// dpkg's `conffderef`: the file a conffile path names once symbolic
    /// links are followed inside the root, or nil when they lead to
    /// something that is not a regular file or loop. A link's text is a
    /// kernel path, as `PackageFilesystem.physicalPath` reads it.
    static func dereference(_ url: URL, filesystem: PackageFilesystem) throws -> URL? {
        var current = url
        for _ in 0 ..< 25 {
            var info = stat()
            guard lstat(current.path, &info) == 0 else { return current }
            switch info.st_mode & S_IFMT {
            case S_IFREG: return current
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: current.path)
                let next = target.hasPrefix("/")
                    ? filesystem.layout.linkedPath(target)
                    : current.deletingLastPathComponent().path + "/" + target
                guard let path = filesystem.physical(next, followingLast: false), filesystem.contains(path)
                else { return nil }
                current = URL(fileURLWithPath: path)
            default: return nil
            }
        }
        return nil
    }

    static func declarations(_ value: String?) throws -> (keep: Set<String>, remove: Set<String>) {
        var keep = Set<String>()
        var remove = Set<String>()
        for line in (value ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("remove-on-upgrade ") {
                let path = String(text.dropFirst("remove-on-upgrade ".count))
                guard path.hasPrefix("/") else { throw PackageFailure("Invalid obsolete conffile path") }
                remove.insert(path)
            } else {
                guard text.hasPrefix("/") else { throw PackageFailure("Invalid conffile declaration") }
                keep.insert(text)
            }
        }
        return (keep, remove)
    }
}
