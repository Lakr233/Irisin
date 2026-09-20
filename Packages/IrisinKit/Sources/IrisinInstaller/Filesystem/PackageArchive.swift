import CryptoKit
import Foundation
import IrisinProtocol

struct PackageArchive {
    let package: PreparedPackage
    let directory: URL
    let fields: [String: String]
    private var hardLinkTargets: [String: String] = [:]

    init(directory: URL, digest: String, identity: String) throws {
        self.directory = directory
        let manifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard Self.sha256(manifest) == digest else {
            throw PackageFailure("Prepared manifest changed: \(identity)")
        }
        package = try JSONDecoder().decode(PreparedPackage.self, from: manifest)
        var control = try DebianControl.parse(package.control, preservingLinesFor: ["description"])
        // dpkg matches package names case-insensitively and the app lowercases
        // every identity it reads, so a control file spelling its name
        // `com.example.violaWhite` is the package the transaction calls
        // `com.example.violawhite`. The transaction's spelling is the one the
        // database records and every relation is matched against.
        guard package.formatVersion == 1,
              control["package"]?.caseInsensitiveCompare(identity) == .orderedSame,
              let version = control["version"], let canonical = DebianVersion.canonical(version),
              control["architecture"] != nil
        else {
            throw PackageFailure("Invalid prepared package: \(identity)")
        }
        control["package"] = identity
        // the version as dpkg spells it back: no `0:` epoch, no trailing space
        control["version"] = canonical
        for field in PackageDatabase.archiveOnlyFields {
            control.removeValue(forKey: field)
        }
        fields = control
        var paths = Set<String>()
        for entry in package.entries {
            guard !entry.path.isEmpty, try PreparedPackage.relativePath(entry.path) == entry.path,
                  paths.insert(entry.path).inserted, entry.mode & ~0o7777 == 0
            else {
                throw PackageFailure("Invalid archive path or permissions")
            }
            if entry.kind == .file {
                guard let file = entry.file else { throw PackageFailure("Missing regular file contents") }
                try validate(file)
            } else if entry.kind == .symbolicLink || entry.kind == .hardLink {
                guard let target = entry.linkTarget, !target.isEmpty, !target.utf8.contains(0) else {
                    throw PackageFailure("Invalid link target")
                }
                if entry.kind == .hardLink, try PreparedPackage.relativePath(target) != target {
                    throw PackageFailure("Invalid hard link target")
                }
            }
        }
        for (name, file) in package.controlFiles {
            // dpkg installs any control member as an info file, under its own
            // name: `extrainst_` and friends included. A name it could not
            // spell as a path is the only refusal.
            guard !name.isEmpty, name != ".", name != "..", name.count <= 250,
                  !name.utf8.contains(0), !name.utf8.contains(0x2F)
            else { throw PackageFailure("Invalid control member") }
            try validate(file)
        }
        hardLinkTargets = try Self.resolveHardLinks(package.entries)
    }

    var identity: String {
        fields["package"]!
    }

    var version: String {
        fields["version"]!
    }

    var architecture: String {
        fields["architecture"]!
    }

    /// Every path the package ships, spelled from the root.
    var absolutePaths: Set<String> {
        Set(package.entries.map { "/" + $0.path })
    }

    /// dpkg's `write_filehash_except`: the `md5sums` dpkg writes for a
    /// package that ships none, one line per regular file and hard link in
    /// the archive's order, conffiles left out, no leading slash.
    func generatedHashes(excluding conffiles: Set<String>) throws -> String {
        let byPath = Dictionary(uniqueKeysWithValues: package.entries.map { ($0.path, $0) })
        var lines = ""
        for entry in package.entries where !conffiles.contains("/" + entry.path) {
            let file: PreparedFile? = switch entry.kind {
            case .file: entry.file
            case .hardLink: try byPath[regularFileTarget(of: entry)]?.file
            default: nil
            }
            if let file {
                lines += file.md5 + "  " + entry.path + "\n"
            }
        }
        return lines
    }

    func regularFileTarget(of entry: PreparedEntry) throws -> String {
        guard let target = hardLinkTargets[entry.path] else {
            throw PackageFailure("Missing hard link target: \(entry.path)")
        }
        return target
    }

    func content(_ file: PreparedFile) -> URL {
        directory.appendingPathComponent(file.name)
    }

    func controlText(_ name: String) throws -> String? {
        guard let file = package.controlFiles[name] else { return nil }
        return try String(contentsOf: content(file), encoding: .utf8)
    }

    private func validate(_ file: PreparedFile) throws {
        guard file.name.hasPrefix("blob-"), file.name.count > 5,
              file.name.dropFirst(5).allSatisfy(\.isNumber), file.size >= 0
        else { throw PackageFailure("Invalid prepared file") }
        var info = stat()
        guard lstat(content(file).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == file.size,
              try Self.digests(content(file)) == (file.sha256, file.md5)
        else { throw PackageFailure("Prepared file changed: \(file.name)") }
    }

    /// Both digests in one read, as the app computes them while it writes the
    /// blob (`ArchiveStream+Preparation`). Verifying them in two passes read
    /// a theme's four thousand files twice over.
    static func digests(_ url: URL) throws -> (sha256: String, md5: String) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        var legacy = Insecure.MD5()
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            sha.update(data: data)
            legacy.update(data: data)
        }
        return (hex(sha.finalize()), hex(legacy.finalize()))
    }

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func digest(_ url: URL, md5: Bool) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha = SHA256()
        var legacy = Insecure.MD5()
        while let data = try file.read(upToCount: 65536), !data.isEmpty {
            if md5 {
                legacy.update(data: data)
            } else {
                sha.update(data: data)
            }
        }
        return md5 ? hex(legacy.finalize()) : hex(sha.finalize())
    }

    private static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
