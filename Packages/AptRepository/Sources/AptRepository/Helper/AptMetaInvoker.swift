//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

/// How well one build of a package fits a bootstrap, best last.
enum ArchitectureFit: Int, Comparable {
    /// built for another bootstrap, and nothing here rewrites it
    case foreign
    /// an adapter rewrites it
    case adaptable
    /// `all`
    case portable
    /// built for this bootstrap
    case native

    init(of architectures: [String], device: String, installable: Set<String>) {
        if architectures.contains(device) {
            self = .native
        } else if architectures.contains("all") {
            self = .portable
        } else if architectures.contains(where: installable.contains) {
            self = .adaptable
        } else {
            self = .foreign
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// invoke all metadata downloaded and build packages
///
/// One repository may list the same package for several architectures, in
/// one flat index or across a suite's `binary-` directories read as one. A
/// `Package` holds one build per version, so each version keeps the build
/// that fits this bootstrap best (`ArchitectureFit`), and of two that fit
/// alike the one read first, which is the device's own index in a suite.
/// A version is judged on its own: a newer one only an adapter installs
/// stays beside an older native one, and what is an update is decided
/// where updates are. Builds nothing here installs are kept only for a
/// package with no other, so it still shows up and can say so.
/// - Parameters:
///   - original: parser, string
///   - fromRepo: repo reference
///   - device: the bootstrap's own architecture, the environment's if nil
///   - installable: what installs on it, the environment's if nil
/// - Returns: container
func invokePackages(
    withContext original: String,
    fromRepo: URL? = nil,
    device: String? = nil,
    installable: Set<String>? = nil
) -> [String: Package] {
    let device = device ?? AptEnvironment.current.deviceArchitecture
    let installable = installable ?? AptEnvironment.current.installableArchitectures
    typealias Build = (metadata: Package.Metadata, fit: ArchitectureFit)
    var builds = [String: [Package.Version: Build]]()
    original
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\n\n")
        .filter { $0.count > 0 }
        .compactMap { try? DebianControl.parse($0) }
        .forEach { metadata in
            guard let id = metadata["package"]?.lowercased(), // just lowercase
                  let ver = metadata["version"],
                  DebianVersion.isValid(ver)
            else {
                aptLog(
                    "AptMetaInvoker",
                    "dropping \(metadata["package"] ?? "an unnamed entry"): version \(metadata["version"] ?? "missing") is not one dpkg would accept",
                    level: .warning
                )
                return
            }
            let fit = ArchitectureFit(
                of: Package.architectures(in: metadata),
                device: device,
                installable: installable
            )
            if let existing = builds[id]?[ver], existing.fit >= fit {
                return
            }
            builds[id, default: [:]][ver] = (metadata, fit)
        }
    return builds.reduce(into: [:]) { result, entry in
        let installs = entry.value.values.contains { $0.fit > .foreign }
        let payload = entry.value
            .filter { !installs || $0.value.fit > .foreign }
            .mapValues(\.metadata)
        result[entry.key] = Package(identity: entry.key, payload: payload, repoRef: fromRepo)
    }
}
