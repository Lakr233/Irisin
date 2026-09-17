import Foundation

/// A regular file in the app's staging directory, addressed by a generated
/// basename rather than any pathname from the untrusted tar archive.
public struct PreparedFile: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let md5: String
    public let size: Int64

    public init(name: String, sha256: String, md5: String, size: Int64) {
        self.name = name
        self.sha256 = sha256
        self.md5 = md5
        self.size = size
    }
}
