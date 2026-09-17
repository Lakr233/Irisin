//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2021/8/14.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

/// Pure helpers over a package value; nonisolated so sort comparators and
/// resolvers running off the main actor can use them.
public extension PackageCenter {
    /// obtain avatar url of package
    /// - Parameter package: package
    /// - Returns: url if available
    nonisolated func avatarUrl(with package: Package) -> URL? {
        if var icon = package.latestMetadata?["icon"] {
            if icon.hasPrefix("file:/") {
                let icon = String(icon.dropFirst("file:/".count))
                return URL(fileURLWithPath: icon)
            } else if icon.hasPrefix("http") {
                return URL(string: icon)
            } else {
                guard let repo = package.repoRef else {
                    return nil
                }
                if icon.hasPrefix("./") {
                    icon.removeFirst(2)
                }
                return repo.appendingPathComponent(icon)
            }
        }
        return nil
    }

    /// obtain name of package
    /// - Parameter package: package
    /// - Returns: name
    nonisolated func name(of package: Package) -> String {
        if let name = package.latestMetadata?["name"],
           name.count > 0
        {
            return name
        }
        return package.identity
    }

    /// obtain description of package
    /// - Parameter package: package
    /// - Returns: description
    nonisolated func description(of package: Package) -> String {
        package.latestMetadata?["description"]
            ?? package.latestVersion
            ?? package.identity
    }

    /// Where the package's native depiction json lives, if it named one.
    ///
    /// `Depiction:` names a web page and is ignored; `SileoDepiction:` and
    /// `NativeDepiction:` name the json this app draws itself. nil is not an
    /// absence of a page — the embedder writes that json out of the metadata
    /// it already holds — only an absence of a remote one.
    nonisolated func depictionURL(of package: Package) -> URL? {
        guard let targetMeta = package.latestMetadata else { return nil }
        guard let lookup = targetMeta["sileodepiction"] ?? targetMeta["nativedepiction"] else { return nil }
        return URL(string: lookup)
    }

    /// Remove any other version inside a package
    /// - Parameters:
    ///   - package: the package to be trimmed
    ///   - target: target version
    /// - Returns: the trimmed package if version found and validated
    nonisolated func trim(package: Package, toVersion target: String) -> Package? {
        if !DebianVersion.isValid(target) {
            return nil
        }
        let payload = package.payload
        guard let meta = payload[target] else { return nil }
        return Package(
            identity: package.identity,
            payload: [target: meta],
            repoRef: package.repoRef
        )
    }

    /// returns a set of packages that contains only one version from parent
    /// - Parameter of: a package
    /// - Returns: sorted from latest to oldest
    nonisolated func versionTrimmedSingleSubPackages(of package: Package) -> [Package] {
        package
            .payload
            .keys
            .sorted { Package.compareVersion($0, b: $1) == .aIsBiggerThenB }
            .compactMap { trim(package: package, toVersion: $0) }
    }

    /// The package to take when several repositories offer the same one:
    /// the newest version that installs on this bootstrap. A flavour built
    /// for this architecture beats an `all` one at the same version; at a
    /// tie the preferred repository wins, then the repository's address, so
    /// the answer does not change between two reads of the same index.
    /// - Parameters:
    ///   - list: candidates, validated against the first's identity
    ///   - preferred: the repository to keep to at a tie, typically the one
    ///     the package was installed from or the one the user is looking at
    /// - Returns: the one to install, nil when nothing here fits the device
    nonisolated func newestPackage(of list: [Package], preferring preferred: URL? = nil) -> Package? {
        guard let first = list.first else { return nil }
        let device = AptEnvironment.current.deviceArchitecture
        let installable = AptEnvironment.current.installableArchitectures
        let preferredRepo = preferred?.absoluteString
        typealias Candidate = (package: Package, version: String, exact: Bool, preferred: Bool, repo: String)
        // `architectures` splits the metadata field afresh on every read, so
        // it is read once per candidate here and not once per comparison
        let candidates = list.compactMap { package -> Candidate? in
            guard package.identity == first.identity,
                  let trimmed = trim(package: package, toVersion: package.latestVersion ?? ""),
                  let version = trimmed.latestVersion
            else { return nil }
            let architectures = trimmed.architectures
            guard architectures.contains(where: { $0 == "all" || installable.contains($0) }) else { return nil }
            let repo = trimmed.repoRef?.absoluteString ?? ""
            return (trimmed, version, architectures.contains(device), repo == preferredRepo, repo)
        }
        func precedes(_ a: Candidate, _ b: Candidate) -> Bool {
            let byVersion = DebianVersion.compare(a.version, b.version)
            if byVersion != 0 {
                return byVersion > 0
            }
            if a.exact != b.exact {
                return a.exact
            }
            if a.preferred != b.preferred {
                return a.preferred
            }
            return a.repo < b.repo
        }
        // max keeps the first of two equivalent candidates, as the head of the
        // sorted list did
        return candidates.max { precedes($1, $0) }?.package
    }
}
