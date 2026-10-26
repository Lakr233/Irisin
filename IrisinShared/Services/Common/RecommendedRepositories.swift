//
//  RecommendedRepositories.swift
//  Irisin
//
//  The repositories onboarding recommends, read from a property list in the
//  bundle. `default-list-managed.plist` ships empty and is the jailbreak's
//  to fill: when it has entries it is the list, whatever the architecture.
//  Otherwise the list is `default-list-<architecture>.plist`, and with
//  neither the page recommends nothing.
//

import Dog
import Foundation

nonisolated enum RecommendedRepositories {
    /// One entry of a list: a source line (a bare address or `deb <url>
    /// <suite> <components>`), for the iOS major versions it names, both
    /// ends inclusive and either left out for no bound.
    struct Entry: Decodable, Equatable {
        let source: String
        var minimumSystemVersion: Int?
        var maximumSystemVersion: Int?

        func applies(to majorVersion: Int) -> Bool {
            if let minimumSystemVersion, majorVersion < minimumSystemVersion {
                return false
            }
            if let maximumSystemVersion, majorVersion > maximumSystemVersion {
                return false
            }
            return true
        }
    }

    static let managedName = "default-list-managed"

    static func name(for architecture: String) -> String {
        "default-list-\(architecture)"
    }

    /// The source lines for this app, as its bundle has them.
    static var lines: [String] {
        guard let directory = Bundle.main.resourceURL else { return [] }
        return lines(
            in: directory,
            architecture: PackagedArchitecture.architecture,
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    static func lines(in directory: URL, architecture: String, majorVersion: Int) -> [String] {
        let entries = entries(in: directory, named: managedName)
            ?? entries(in: directory, named: name(for: architecture))
            ?? []
        return entries.filter { $0.applies(to: majorVersion) }.map(\.source)
    }

    /// Nil for a list that is missing, empty or does not read, so the next
    /// one is asked.
    private static func entries(in directory: URL, named name: String) -> [Entry]? {
        let list = directory.appendingPathComponent(name).appendingPathExtension("plist")
        guard FileManager.default.fileExists(atPath: list.path) else { return nil }
        do {
            let entries = try PropertyListDecoder().decode([Entry].self, from: Data(contentsOf: list))
            return entries.isEmpty ? nil : entries
        } catch {
            // the description, not the error's dump: its "Underlying error:"
            // reads as a compiler error to the build log's scan, and a test
            // feeds this a broken list on purpose
            Dog.shared.join(
                "Repository",
                "recommended list \(list.lastPathComponent) does not read: \(error.localizedDescription)",
                level: .error
            )
            return nil
        }
    }
}
