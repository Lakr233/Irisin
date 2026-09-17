//
//  IrisinLink.swift
//  Irisin
//

import AptRepository
import Foundation

/// The two things an `irisin://` link can ask for. Parsing only: nothing here
/// touches the catalogue or the screen, and nothing here repairs a malformed
/// link. A link that arrives mangled is refused and said so, because guessing
/// what a half-escaped address meant is how `apt-repo://` grew its patches.
///
/// - `irisin://repository/add?url=…[&suite=…][&component=…]…` — one or more
///   repositories. A suite describes one repository, so it may not be spread
///   over several addresses.
/// - `irisin://package/<identity>` — one package's page.
nonisolated enum IrisinLink: Equatable {
    case addRepositories([RepositorySource])
    case package(identity: String)

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "irisin",
              let host = components.host?.lowercased()
        else { return nil }
        // URLComponents decodes the path, so a percent-encoded identity is
        // already spelled out by the time it is checked
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        switch (host, path.count) {
        case ("repository", 1) where path[0] == "add":
            guard let sources = Self.sources(from: components.queryItems) else { return nil }
            self = .addRepositories(sources)
        case ("package", 1):
            guard InstallerJob.isPackageIdentity(path[0]) else { return nil }
            self = .package(identity: path[0])
        default:
            return nil
        }
    }

    /// The query as repositories, or nil when any part of it is not one: an
    /// unknown parameter, an empty value, an address without its own scheme,
    /// a second suite, a suite over several addresses, or a source apt would
    /// not accept.
    private static func sources(from items: [URLQueryItem]?) -> [RepositorySource]? {
        guard let items, !items.isEmpty else { return nil }
        var addresses: [String] = []
        var suite: String?
        var components: [String] = []
        for item in items {
            guard let value = item.value, !value.isEmpty else { return nil }
            switch item.name {
            case "url": addresses.append(value)
            case "suite":
                guard suite == nil else { return nil }
                suite = value
            case "component": components.append(value)
            default: return nil
            }
        }
        guard !addresses.isEmpty else { return nil }
        // one suite and one set of components describe one repository
        guard suite == nil || addresses.count == 1 else { return nil }
        var sources: [RepositorySource] = []
        for address in addresses {
            // the link carries a complete address; nothing is filled in here
            guard address.range(of: #"^https?://"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let url = RepositorySource.url(from: address)
            else { return nil }
            let source = RepositorySource(url: url, distribution: suite, components: components)
            guard source.isValid else { return nil }
            sources.append(source)
        }
        return sources.uniqued()
    }
}
