//
//  Project Irisin
//  Irisin
//
//  Created by Lakr Aream on 2020/4/18.
//  Copyright © 2020 Lakr Aream. All rights reserved.
//

import Foundation

/// How well one build of a package fits a bootstrap, best last. A build for
/// any other architecture has no fit: nothing here installs it.
enum ArchitectureFit: Int, Comparable {
    /// `all`
    case portable
    /// built for this bootstrap
    case native

    init?(of architectures: [String], device: String) {
        if architectures.contains(device) {
            self = .native
        } else if architectures.contains("all") {
            self = .portable
        } else {
            return nil
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
/// A build for another architecture is dropped: the catalogue lists only
/// what installs here.
/// - Parameters:
///   - original: parser, string
///   - fromRepo: repo reference
///   - device: the bootstrap's own architecture, the environment's if nil
/// - Returns: container
func invokePackages(
    withContext original: String,
    fromRepo: URL? = nil,
    device: String? = nil
) -> [String: Package] {
    readPackageIndex(original, fromRepo: fromRepo, device: device).packages
}

/// `invokePackages`, and how many entries the index named before any was
/// dropped: an index of packages for another bootstrap is a catalogue with
/// nothing in it, not a page that is no catalogue at all.
func readPackageIndex(
    _ original: String,
    fromRepo: URL? = nil,
    device: String? = nil
) -> (packages: [String: Package], entries: Int) {
    var entries = 0
    let device = device ?? AptEnvironment.current.deviceArchitecture
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
            entries += 1
            guard let fit = ArchitectureFit(of: Package.architectures(in: metadata), device: device) else {
                return
            }
            if let existing = builds[id]?[ver], existing.fit >= fit {
                return
            }
            builds[id, default: [:]][ver] = (metadata, fit)
        }
    let packages = builds.reduce(into: [String: Package]()) { result, entry in
        result[entry.key] = Package(identity: entry.key, payload: entry.value.mapValues(\.metadata), repoRef: fromRepo)
    }
    return (packages, entries)
}
