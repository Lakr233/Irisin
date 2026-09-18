import Foundation

public struct PreparedPackage: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let control: String
    public let controlFiles: [String: PreparedFile]
    public let entries: [PreparedEntry]

    public init(control: String, controlFiles: [String: PreparedFile], entries: [PreparedEntry]) {
        formatVersion = 1
        self.control = control
        self.controlFiles = controlFiles
        self.entries = entries
    }

    /// `original` as a path below a root, `.` and empty components dropped,
    /// or a refusal: absolute, a NUL or a newline in it, a `..` component.
    /// All of it in bytes, as the kernel and dpkg's lists read a path:
    /// `String` splits by character, and a combining mark after a `/` makes
    /// one character of the two, so `../` and a mark would pass as a name,
    /// and `\r\n` is a character that is not `\n`.
    public static func relativePath(_ original: String) throws -> String {
        guard original.utf8.first != 0x2F, !original.utf8.contains(0), !original.utf8.contains(0x0A) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let components = original.utf8.split(separator: 0x2F).filter { !$0.elementsEqual(".".utf8) }
        guard !components.contains(where: { $0.elementsEqual("..".utf8) }) else { throw CocoaError(.fileReadCorruptFile) }
        return components.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
    }
}
