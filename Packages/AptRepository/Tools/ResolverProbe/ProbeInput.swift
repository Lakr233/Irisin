import AptRepository
import Foundation

struct ProbeInput: Decodable {
    var available: [[String: String]]
    var installed: [[String: String]]
    var install: [String]
    var remove: [String]
    var updateAll: Bool
    var architecture: String

    func package(_ fields: [String: String], installed: Bool) -> Package {
        // Match repository/status ingestion while retaining the original fields.
        Package(identity: fields["package"]!.lowercased(), payload: [fields["version"]!: fields], repoRef: installed ? nil : URL(string: "https://oracle.invalid/"))
    }
}
