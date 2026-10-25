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

    /// The versions built for `device` (or `all`), as a package of their
    /// own; nil when none is. The catalogue holds no other build, but a
    /// catalogue written before 5.0 may, until its repository refreshes.
    public func versions(builtFor device: String) -> Package? {
        let kept = payload.filter { _, metadata in
            Self.architectures(in: metadata).contains { $0 == "all" || $0 == device }
        }
        guard !kept.isEmpty else { return nil }
        return kept.count == payload.count ? self : Package(identity: identity, payload: kept, repoRef: repoRef)
    }

    /// The versions built for `device` (or `all`), when the newest of them
    /// is an update over `current`; nil otherwise.
    public func update(over current: String, device: String) -> Package? {
        versions(builtFor: device)
            .flatMap { Self.compareVersion($0.latestVersion ?? "", b: current) == .aIsBiggerThenB ? $0 : nil }
    }

    /// The version a list holds up against the `installed` one: the newest
    /// built for `device`. The installed one, when the record has it, is
    /// never behind itself, whatever it was built for; a record with
    /// nothing for `device` is read at its newest, as ever.
    public func version(comparedWith installed: String, device: String) -> String? {
        let offered = (versions(builtFor: device) ?? self).latestVersion
        let own = payload[installed] == nil ? nil : installed
        return [offered, own].compactMap(\.self).max { DebianVersion.compare($0, $1) < 0 }
    }

    /// Whether dpkg on this bootstrap would install the newest version.
    public func supports(architecture device: String) -> Bool {
        architectures.contains { $0 == "all" || $0 == device }
    }

    /// Whether the package installs on the bootstrap the app runs on.
    public var isSupportedOnDevice: Bool {
        supports(architecture: AptEnvironment.current.deviceArchitecture)
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
