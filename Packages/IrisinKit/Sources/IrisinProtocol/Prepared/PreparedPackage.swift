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

    public static func relativePath(_ original: String) throws -> String {
        guard !original.hasPrefix("/"), !original.utf8.contains(0), !original.contains("\n") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let components = original.split(separator: "/").filter { $0 != "." }
        guard !components.contains("..") else { throw CocoaError(.fileReadCorruptFile) }
        return components.joined(separator: "/")
    }
}
