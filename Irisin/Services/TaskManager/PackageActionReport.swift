import AptResolver
import Foundation

/// One report is captured by the diagnostic page, so sharing and rendering
/// always describe the same failed request.
final class PackageActionReport {
    static let shared = PackageActionReport()
    private init() {}

    private var messages: [String] = []
    private(set) var checks: [ResolutionCheck] = []

    func record(_ message: String, checks: [ResolutionCheck] = []) {
        messages.append(message)
        self.checks.append(contentsOf: checks)
    }

    func allAvailable() -> String {
        messages.joined(separator: "\n\n")
    }

    func clear() {
        messages.removeAll()
        checks.removeAll()
    }
}
