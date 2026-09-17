public enum PreparedEntryKind: String, Codable, Sendable {
    case file, directory, symbolicLink, hardLink
}
