//
//  SceneRestorationReset.swift
//  Irisin
//

import Foundation

/// Drops this process's UIKit scene-restoration archive.
///
/// UIKit reads `Library/Saved Application State/<bundleID>.savedState` before
/// any scene delegate runs. A leftover archive from a previous UI framework,
/// a previous `Info.plist` scene configuration, or an old `delegateClass`
/// restores that old delegate and never reaches the current one. Cold launch
/// is the only chance to delete it: `main` does not run on a background
/// resume, which is what keeps a live scene intact.
///
/// Only this bundle's `.savedState` directory is removed. Preferences and
/// other bundles under the same Saved Application State folder stay.
nonisolated enum SceneRestorationReset {
    static func removeSavedState(in library: URL, bundleIdentifier: String) throws {
        let savedState = library
            .appendingPathComponent("Saved Application State", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
        guard FileManager.default.fileExists(atPath: savedState.path) else { return }
        try FileManager.default.removeItem(at: savedState)
    }
}
