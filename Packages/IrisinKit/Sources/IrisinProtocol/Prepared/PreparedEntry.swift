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
    /// The owner as numbers, as the archive stores them.
    public let uid: UInt32
    public let gid: UInt32
    /// The owner by name, as the archive names it, if it does. The helper
    /// asks the bootstrap for these, and they win over the numbers when it
    /// knows them; the app, running as mobile, never decides.
    public let userName: String?
    public let groupName: String?
    public let modificationTime: Int64

    public init(
        path: String,
        kind: Kind,
        file: PreparedFile? = nil,
        linkTarget: String? = nil,
        mode: UInt32,
        uid: UInt32,
        gid: UInt32,
        userName: String? = nil,
        groupName: String? = nil,
        modificationTime: Int64
    ) {
        self.path = path
        self.kind = kind
        self.file = file
        self.linkTarget = linkTarget
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.userName = userName
        self.groupName = groupName
        self.modificationTime = modificationTime
    }
}
