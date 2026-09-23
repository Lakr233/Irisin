//
//  Repository.swift
//  Irisin
//
//  Created by Lakr Aream on 2020/4/26.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation
import WCDBSwift

/// What the user typed to add a repository: a bare address for a flat one,
/// or `deb <url> <suite> <component>...` the way apt's sources.list spells
/// a distribution. A suite ending in `/` is apt's other flat form and takes
/// no components.
public struct RepositorySource: Hashable, Codable, Sendable {
    public var url: URL
    public var distribution: String?
    public var components: [String]

    public init(url: URL, distribution: String? = nil, components: [String] = []) {
        self.url = url
        self.distribution = distribution
        self.components = components
    }

    /// A sources.list line, or a bare address; nil when it is neither.
    public init?(line: String) {
        var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.first == "deb" {
            tokens.removeFirst()
        }
        guard let first = tokens.first, let url = Self.url(from: first) else { return nil }
        self.url = url
        distribution = tokens.count > 1 ? tokens[1] : nil
        components = tokens.count > 2 ? Array(tokens[2...]) : []
        guard isValid else { return nil }
    }

    /// The same source, the way sources.list would spell it.
    public var line: String {
        guard let distribution else { return url.absoluteString }
        return (["deb", url.absoluteString, distribution] + components).joined(separator: " ")
    }

    /// Well formed: a host, and either no suite, a flat suite ending in `/`,
    /// or a suite with at least one component. Nothing is fetched here.
    public var isValid: Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        guard let distribution, !distribution.isEmpty else {
            return distribution == nil && components.isEmpty
        }
        if distribution.hasSuffix("/") {
            return components.isEmpty
        }
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty }
    }

    /// An address with the scheme filled in when it was left out — a host is
    /// what the user usually types — and no trailing `/`.
    public static func url(from text: String) -> URL? {
        var str = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // the add sheet's field starts with `https://`; an address pasted
        // after it carries its own scheme, and only the last one counts
        while let range = str.range(of: #"^https?://(?=https?://)"#, options: [.regularExpression, .caseInsensitive]) {
            str.removeSubrange(range)
        }
        if !str.contains("://") {
            str = "https://" + str
        }
        while str.hasSuffix("/") {
            str.removeLast()
        }
        // a bare scheme ends up as `https:`, which has no host
        guard let url = URL(string: str), let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// A registered repository: the source, what its Release file said, its
/// icon, and the user's notes on it. Its packages live in the database, by
/// its url; `packageCount` is the only trace of them here.
public struct Repository: TableCodable, Hashable, Identifiable, Sendable {
    // MARK: - USER GRANTED

    public internal(set) var url: URL
    public internal(set) var distribution: String?
    public internal(set) var components: [String] = []

    public var id: String {
        url.absoluteString
    }

    public var source: RepositorySource {
        RepositorySource(url: url, distribution: distribution, components: components)
    }

    // MARK: - METADATA

    public internal(set) var avatar = Data()
    /// Where the icon may be, in the order asked: the address itself, then
    /// the suite's directory, which is where BigBoss keeps it.
    public var avatarUrls: [URL] {
        var bases = [url]
        if suiteUrl != url {
            bases.append(suiteUrl)
        }
        return bases.map { $0.appendingPathComponent("CydiaIcon").appendingPathExtension("png") }
    }

    public internal(set) var lastUpdateRelease = Date(timeIntervalSince1970: 0)
    public internal(set) var metaRelease: [String: String] = [:]

    /// Where the suite's files live: the address itself for a flat
    /// repository, `<url>/<suite>` for a flat suite, `<url>/dists/<suite>`
    /// for a distribution.
    var suiteUrl: URL {
        guard let distribution else { return url }
        if distribution.hasSuffix("/") {
            return url.appendingPathComponent(distribution)
        }
        return url.appendingPathComponent("dists").appendingPathComponent(distribution)
    }

    public var metaReleaseUrl: URL {
        suiteUrl.appendingPathComponent("Release")
    }

    public internal(set) var lastUpdatePackage = Date(timeIntervalSince1970: 0)
    public internal(set) var packageCount = 0

    /// The Packages indexes to try, in the order tried, each entry read as
    /// one catalogue; a flat repository has a single entry of one index.
    /// The refresh reads the first entry that answers with packages.
    public var metaPackageCandidates: [[URL]] {
        Self.packageIndexUrls(
            suiteUrl: suiteUrl,
            distribution: distribution,
            components: components,
            release: metaRelease,
            architectures: AptEnvironment.current.indexArchitectures,
            installable: AptEnvironment.current.installableArchitectures
        )
    }

    /// The index directories to probe given what the Release offers:
    /// `architectures` in order, the device's own first, less those a
    /// Release that lists its architectures leaves out, so a directory known
    /// to be missing costs no request: Procursus keeps its rootless suites
    /// in the legacy `binary-iphoneos-arm` and its Release says so, and
    /// BigBoss has `binary-iphoneos-arm64` and nothing for roothide. A
    /// Release that lists none of them, or says nothing, leaves the whole
    /// list to be probed. `all` is never a directory of its own.
    ///
    /// Every architecture in `installable` goes in the first entry, the
    /// device's own ahead of those an adapter rewrites, one index per
    /// component each: a suite with three packages built for this bootstrap
    /// and three hundred for the one next to it offers them all, and
    /// `invokePackages` picks the build of each version. An entry is read
    /// whole or not at all, and two directories are not published as one:
    /// where the Release lists one the server does not have, or has an
    /// older copy of, each is asked again on its own. The rest follow one
    /// entry each, reached only when nothing before them answered, so a
    /// suite with nothing that installs here still lists what it has.
    /// An entry is asked for under one compression at a time, so
    /// directories that share none are read through the single entries.
    static func packageIndexUrls(
        suiteUrl: URL,
        distribution: String?,
        components: [String],
        release: [String: String],
        architectures: [String],
        installable: Set<String>
    ) -> [[URL]] {
        guard let distribution, !distribution.hasSuffix("/") else {
            return [[suiteUrl.appendingPathComponent("Packages")]]
        }
        let offered = release["architectures"]?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        let named = architectures.filter(offered.contains)
        let chain = named.isEmpty ? architectures : named
        let together = chain.filter(installable.contains)
        let entries = (together.count > 1 ? [together] : [])
            + together.map { [$0] }
            + chain.filter { !installable.contains($0) }.map { [$0] }
        return entries.map { entry in
            entry.flatMap { architecture in
                components.map {
                    suiteUrl
                        .appendingPathComponent($0)
                        .appendingPathComponent("binary-\(architecture)")
                        .appendingPathComponent("Packages")
                }
            }
        }
    }

    public internal(set) var preferredSearchPath = "bz2"
    /// Every spelling of a compressed index worth asking for. Not stored:
    /// the list is the app's knowledge, not the repository's.
    public var availableSearchPath: [String] {
        ["bz2", "", "xz", "gz", "zst", "lzma"]
    }

    public internal(set) var attachment: [AttachInfo: String] = [:]
    public var nickName: String {
        attachment[.nickName, default: "repo"]
    }

    public enum AttachInfo: String, Codable, Sendable {
        /*
         if nickNamePinned is true
         - that means user has pinned the name for repo
         - nickName will return userPinnedName

         if nickNamePinned is false
         - check repo release metadata
         - the name may be calculated from repo url if no meta
         */
        case nickName
        case nickNamePinned
        /**
         used to store featured packages
         */
        case featured
        /**
         tag for tracing, not set means true [for backward capability]
         */
        case initialInstall
        /**
         the last refresh's `RefreshReport`, as JSON
         */
        case refreshReport
    }

    public internal(set) var paymentInfo: [PaymentInfo: String] = [:]
    public var endpoint: URL? {
        paymentInfo[.endpoint].flatMap(URL.init(string:))
    }

    public enum PaymentInfo: String, Codable, Sendable {
        case endpoint
    }

    public var repositoryDescription: String? {
        metaRelease["description"] ?? metaRelease["version"]
    }

    // MARK: - STORAGE

    public enum CodingKeys: String, CodingTableKey {
        public typealias Root = Repository
        case url
        case distribution
        case components
        case avatar
        case lastUpdateRelease
        case metaRelease
        case lastUpdatePackage
        case packageCount
        case preferredSearchPath
        case attachment
        case paymentInfo

        public nonisolated(unsafe) static let objectRelationalMapping = TableBinding(CodingKeys.self) {
            BindColumnConstraint(url, isPrimary: true)
        }
    }

    // MARK: - INIT

    public init(source: RepositorySource) {
        url = source.url
        distribution = source.distribution
        components = source.components
        attachment[.nickName] = regenerateNickName()
        attachment[.initialInstall] = "YES"
    }

    // MARK: - PROTOCOL

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: Repository, rhs: Repository) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Helper

    public mutating func regenerateNickName(apply: Bool = false) -> String {
        // build nick name
        var build = "repo"
        if let nickName = attachment[.nickName],
           let pinned = attachment[.nickNamePinned],
           pinned == "true"
        {
            return nickName
        } else if let name = metaRelease["label"] {
            build = name
        } else if let name = metaRelease["origin"] {
            build = name
        } else if var host = url.host {
            let trimmer = [
                "www", "apt", "repo", "deb",
            ]
            for item in trimmer {
                let prefix = item + "."
                if host.hasPrefix(prefix) {
                    host.removeFirst(prefix.count)
                }
            }
            build = host
        }
        if apply {
            attachment[.nickName] = build
        }
        return build
    }
}
