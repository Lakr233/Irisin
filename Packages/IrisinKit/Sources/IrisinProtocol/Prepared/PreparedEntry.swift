import Foundation

public struct PreparedEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: PreparedEntryKind
    public let file: PreparedFile?
    public let linkTarget: String?
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let modificationTime: Int64

    public init(
        path: String,
        kind: PreparedEntryKind,
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
