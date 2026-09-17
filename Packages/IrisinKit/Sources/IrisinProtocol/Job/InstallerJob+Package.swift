import Foundation

public extension InstallerJob.Transaction {
    struct Package: Codable, Equatable, Sendable {
        public var identity: String
        /// Kernel path of the original archive, retained for digest verification.
        public var path: String
        public var preparedPath: String?
        public var preparedSHA256: String?
        public var sha256: String

        public init(
            identity: String,
            path: String,
            sha256: String = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            preparedPath: String? = nil,
            preparedSHA256: String? = nil
        ) {
            self.identity = identity
            self.path = path
            self.sha256 = sha256
            self.preparedPath = preparedPath
            self.preparedSHA256 = preparedSHA256
        }
    }
}
