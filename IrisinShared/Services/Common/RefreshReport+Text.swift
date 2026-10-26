import AptRepository

extension RefreshReport.Issue {
    /// What went wrong, as a sentence; `refreshed` is when the refresh ran,
    /// already formatted. The repository's page and the browser's list both
    /// say it this way.
    func sentence(refreshed: String) -> String {
        switch self {
        case .unreachable:
            String(localized: "The last refresh, on \(refreshed), could not reach the server.")
        case .stalled:
            String(localized: "The server stopped responding during the last refresh.")
        case let .serverError(code):
            String(localized: "The server returned an error (HTTP \(code)) during the last refresh.")
        case .releaseMissing, .releaseMalformed:
            String(
                localized: "This repository's Release file is missing or cannot be read, so its package lists cannot be verified."
            )
        case .releaseOutdated:
            String(
                localized: "The server returned an older Release file than the one on this device, so it was ignored."
            )
        case .indexUnverified:
            String(
                localized: "This repository's Release file does not list its package list, so the list cannot be verified."
            )
        case .noIndex:
            String(localized: "The server has no package list for this device.")
        }
    }
}
