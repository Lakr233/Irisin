import AptResolver
import Foundation

/// One report is captured by the diagnostic page, so sharing and rendering
/// always describe the same failed request.
final class PackageActionReport {
    static let shared = PackageActionReport()
    private init() {}

    private var messages: [String] = []
    private(set) var checks: [ResolutionCheck] = []
    /// Set when the reason is one a row on the page would undersell: the
    /// page that reads it presents the report as an alert under this title.
    private(set) var alertTitle: String?

    func record(_ message: String, checks: [ResolutionCheck] = [], alertTitle: String? = nil) {
        messages.append(message)
        self.checks.append(contentsOf: checks)
        self.alertTitle = alertTitle ?? self.alertTitle
    }

    func allAvailable() -> String {
        messages.joined(separator: "\n\n")
    }

    func clear() {
        messages.removeAll()
        checks.removeAll()
        alertTitle = nil
    }
}
