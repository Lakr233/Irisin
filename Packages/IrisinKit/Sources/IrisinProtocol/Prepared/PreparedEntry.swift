import Foundation

public struct PreparedEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, directory, symbolicLink, hardLink
    }

    public let path: String
    public let kind: Kind
    public let file: PreparedFile?
    public let linkTarget: String?
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let modificationTime: Int64

    public init(
        path: String,
        kind: Kind,
        file: PreparedFile? = nil,
        linkTarget: String? = nil,
        mode: UInt32,
        uid: UInt32,
        gid: UInt32,
        modificationTime: Int64
    ) {
        self.path = path
        self.kind = kind
        self.file = file
        self.linkTarget = linkTarget
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.modificationTime = modificationTime
    }
}
