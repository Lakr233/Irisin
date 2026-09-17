import CryptoKit
import Foundation

public extension Package {
    /// Re-read the staged archive, not the download cache. The resolver's
    /// relationships must describe the actual control file dpkg will consume.
    func validateArchive(at url: URL) throws -> String {
        let archive = try Package(debianPackageAt: url)
        guard identity == archive.identity, latestVersion == archive.latestVersion,
              architectures == archive.architectures else { throw CocoaError(.fileReadCorruptFile) }
        for field in [
            "depends", "pre-depends", "conflicts", "breaks", "replaces",
            "provides", "essential", "protected", "multi-arch",
        ] {
            guard (latestMetadata?[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ==
                (archive.latestMetadata?[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        let digest = try Self.archiveDigest(at: url)
        if let expected = latestMetadata?["sha256"], expected.lowercased() != digest {
            throw CocoaError(.fileReadCorruptFile)
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
