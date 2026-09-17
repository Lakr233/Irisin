import CryptoKit
import Foundation
import IrisinProtocol

public extension PreparedPackage {
    /// The manifest `ArchiveStream.prepareDebianPackage` wrote beside the blobs.
    static func read(from directory: URL) throws -> PreparedPackage {
        try JSONDecoder().decode(
            PreparedPackage.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
    }

    /// Replace the manifest and return the digest the helper will check it
    /// against. The bytes are encoded the way the preparation encoded them,
    /// so an adapter that changes nothing writes the same digest back.
    func write(to directory: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
