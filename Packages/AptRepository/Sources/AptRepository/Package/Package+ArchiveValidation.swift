import CryptoKit
import Foundation

/// The repository's listing and the package file disagree. The file reads
/// fine; the plan was solved with the listing, so installing the file would
/// install something the resolver never saw.
public struct ArchiveMismatch: Error, Equatable, CustomStringConvertible {
    public struct Difference: Equatable, Sendable {
        /// The control field's name, lowercased, as the metadata spells it.
        public let field: String
        public let listed: String
        public let found: String

        public init(field: String, listed: String, found: String) {
            self.field = field
            self.listed = listed
            self.found = found
        }
    }

    public let package: String
    public let differences: [Difference]

    public var description: String {
        "the repository's listing of \(package) does not match the package file: "
            + differences.map { "\($0.field) is listed as \"\($0.listed)\", the file says \"\($0.found)\"" }
            .joined(separator: "; ")
    }
}

public extension Package {
    /// Re-read the staged archive, not the download cache. The resolver's
    /// relationships must describe the actual control file dpkg will consume.
    func validateArchive(at url: URL) throws -> String {
        let archive = try Package(debianPackageAt: url)
        let digest = try Self.archiveDigest(at: url)
        var pairs = [
            ("package", identity, archive.identity),
            ("version", latestVersion ?? "", archive.latestVersion ?? ""),
            ("architecture", architectures.joined(separator: " "), archive.architectures.joined(separator: " ")),
        ]
        for field in [
            "depends", "pre-depends", "conflicts", "breaks", "replaces",
            "provides", "essential", "protected", "multi-arch",
        ] {
            pairs.append((
                field,
                (latestMetadata?[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                (archive.latestMetadata?[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        if let expected = latestMetadata?["sha256"] {
            pairs.append(("sha256", expected.lowercased(), digest))
        }
        let differences = pairs.filter { $0.1 != $0.2 }
            .map { ArchiveMismatch.Difference(field: $0.0, listed: $0.1, found: $0.2) }
        guard differences.isEmpty else {
            throw ArchiveMismatch(package: identity, differences: differences)
        }
        return digest
    }

    static func archiveDigest(at url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
