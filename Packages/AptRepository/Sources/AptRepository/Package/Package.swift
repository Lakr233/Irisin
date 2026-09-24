//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

public let PackageBadUrl = URL(string: "https://127.0.0.1:8888/some/bad/url")!

public struct Package: Codable, Hashable, Identifiable, Sendable {
    // MARK: - Property

    /// id
    public var id: String {
        identity
    }

    public let identity: String

    // store
    public typealias Version = String
    public typealias Metadata = [String: String]
    public let payload: [Version: Metadata]

    /// ref
    public let repoRef: URL?

    public let latestVersion: String?

    /// What names the package, not what it says: a list's snapshot hashes
    /// every row, and the synthesized hash walked each version's control
    /// fields. Equality still compares everything, so a package whose
    /// fields changed is still a different value.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(identity)
        hasher.combine(repoRef)
        hasher.combine(latestVersion)
    }

    // MARK: - Init

    public init(
        identity: String,
        payload: [Package.Version: Package.Metadata] = [:],
        repoRef: URL? = nil
    ) {
        self.identity = identity
        self.payload = payload
        self.repoRef = repoRef
        // every package in every repository runs this init: take the maximum
        // rather than sorting the whole key set to read its head
        latestVersion = payload.keys.max { DebianVersion.compare($0, $1) < 0 }
    }

    /// A `.deb` on disk, described by its own `control` file. The package has
    /// no repository; its `filename` is the file URL, so it downloads to
    /// itself and `localFileURL` tells it apart from a repository package.
    public init(debianPackageAt url: URL) throws {
        let control = try ArchiveStream.debianControl(atPath: url.path)
        guard var meta = try? DebianControl.parse(control),
              let id = meta["package"]?.lowercased(), // just lowercase
              let ver = meta["version"],
              DebianVersion.isValid(ver)
        else {
            throw ArchiveStream.Failure(description: "control file has no valid package and version")
        }
        meta["filename"] = url.absoluteString
        meta["sha256"] = try Self.archiveDigest(at: url)
        self.init(identity: id, payload: [ver: meta], repoRef: nil)
    }

    // MARK: - Computed

    public var latestMetadata: Metadata? {
        if let latestVersion {
            return payload[latestVersion]
        }
        return nil
    }

    /// The `.deb` behind a package built with `init(debianPackageAt:)`.
    public var localFileURL: URL? {
        let url = obtainDownloadLink()
        return url.isFileURL ? url : nil
    }

    public func obtainDownloadLink() -> URL {
        guard var target = latestMetadata?["filename"] else {
            return PackageBadUrl
        }

        func createURL(from string: String) -> URL {
            if let url = URL(string: string) {
                return url
            }
            var charSet = CharacterSet.urlFragmentAllowed
            charSet = charSet.union(.urlHostAllowed)
            charSet = charSet.union(.urlPathAllowed)
            charSet = charSet.union(.urlQueryAllowed)
            if let encode = string.addingPercentEncoding(withAllowedCharacters: charSet),
               let url = URL(string: encode)
            {
                return url
            }
            return PackageBadUrl
        }

        if target.hasPrefix("http") || target.hasPrefix("file://") {
            return createURL(from: target)
        }
        if target.hasPrefix("./") {
            target.removeFirst(2)
        }
        guard let repo = repoRef else {
            return PackageBadUrl
        }

        var builder = repo.absoluteString
        while builder.hasSuffix("/") {
            builder.removeLast()
        }
        if !target.hasPrefix("/") {
            builder += "/"
        }
        builder += target

        return createURL(from: builder)
    }

    // MARK: - Static Tools

    public enum VersionCompareResult {
        case aIsBiggerThenB
        case aIsSmallerThenB
        case aIsEqualToB
        case invalidParameter
    }

    public static func compareVersion(_ a: String, b: String) -> VersionCompareResult {
        guard let a = DebianVersion.parse(a), let b = DebianVersion.parse(b) else { return .invalidParameter }
        let result = DebianVersion.compare(a, b)
        if result < 0 {
            return .aIsSmallerThenB
        }
        if result > 0 {
            return .aIsBiggerThenB
        }
        return .aIsEqualToB
    }

    // MARK: - Architecture

    /// What the newest version's `Provides:` offers, parsed on its own.
    /// The whole-package parse gives up on any malformed relationship
    /// field, so reaching this through it would drop a package's virtual
    /// names over an unrelated bad `Depends:`.
    public var provides: [PackageRequirementGroup.Clause.Term] {
        guard let value = latestMetadata?["provides"],
              let group = PackageRequirementGroup(value: value, type: .provides)
        else { return [] }
        return group.requirements.flatMap(\.elements)
    }

    /// The dpkg architectures the newest version was built for. `all` fits
    /// every bootstrap; a missing field is taken as `all`, the way dpkg does.
    public var architectures: [String] {
        Self.architectures(in: latestMetadata ?? [:])
    }

    /// The `Architecture` field of one control paragraph, read as a list.
    public static func architectures(in metadata: Metadata) -> [String] {
        (metadata["architecture"] ?? "all")
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
    }

    /// The versions whose build carries one of `accepted` (or `all`), as a
    /// package of their own; nil when none does. One repository can offer a
    /// version built for this bootstrap beside a newer one built for
    /// another, so the newest says nothing about the rest.
    public func versions(supportingAnyOf accepted: Set<String>) -> Package? {
        let kept = payload.filter { _, metadata in
            Self.architectures(in: metadata).contains { $0 == "all" || accepted.contains($0) }
        }
        guard !kept.isEmpty else { return nil }
        return kept.count == payload.count ? self : Package(identity: identity, payload: kept, repoRef: repoRef)
    }

    /// The versions that are an update over `current`, nil when none is:
    /// those built for `device` when one of them is newer, as the resolver
    /// takes a build for this bootstrap ahead of a newer one an adapter
    /// would rewrite, and otherwise all that `accepted` lets in.
    public func update(over current: String, device: String, accepted: Set<String>) -> Package? {
        [[device], accepted].lazy
            .compactMap { versions(supportingAnyOf: $0) }
            .first { Self.compareVersion($0.latestVersion ?? "", b: current) == .aIsBiggerThenB }
    }

    /// The version a list holds up against the `installed` one: the newest
    /// that `accepted` lets be an update, since a record can hold a version
    /// built for this bootstrap under a newer one only an adapter installs.
    /// The installed one, when the record has it, is never behind itself,
    /// whatever it was built for; a record with nothing accepted is read at
    /// its newest, as ever.
    public func version(comparedWith installed: String, accepted: Set<String>) -> String? {
        let offered = (versions(supportingAnyOf: accepted) ?? self).latestVersion
        let own = payload[installed] == nil ? nil : installed
        return [offered, own].compactMap(\.self).max { DebianVersion.compare($0, $1) < 0 }
    }

    /// Whether dpkg on this bootstrap would install the newest version as
    /// built, with no adapter in between.
    public func supports(architecture device: String) -> Bool {
        architectures.contains { $0 == "all" || $0 == device }
    }

    /// Whether the newest version carries one of `accepted`, the bootstrap's
    /// own architecture or one an adapter rewrites into it.
    public func supports(anyOf accepted: Set<String>) -> Bool {
        architectures.contains { $0 == "all" || accepted.contains($0) }
    }

    /// Whether the package installs on the bootstrap the app runs on, as
    /// built or through an adapter.
    public var isSupportedOnDevice: Bool {
        supports(anyOf: AptEnvironment.current.installableArchitectures)
    }

    public func propertyListEncoded() -> Data? {
        try? PropertyListEncoder().encode(self)
    }

    public static func propertyListDecoded(with data: Data?) -> Self? {
        guard let data else {
            return nil
        }
        return try? PropertyListDecoder().decode(self, from: data)
    }
}
