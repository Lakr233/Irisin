//
//  main.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/5.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

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
func removeSavedSceneState(in library: URL, bundleIdentifier: String) throws {
    let savedState = library
        .appendingPathComponent("Saved Application State", isDirectory: true)
        .appendingPathComponent("\(bundleIdentifier).savedState", isDirectory: true)
    guard FileManager.default.fileExists(atPath: savedState.path) else { return }
    try FileManager.default.removeItem(at: savedState)
}

// Manual entry rather than `@main` on the app delegate: work that must finish
// before UIKit reads saved sessions has to run here. Background resumes do
// not enter `main`, so a live scene is left alone.
do {
    if let bundleIdentifier = Bundle.main.bundleIdentifier {
        let library = try FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        try removeSavedSceneState(
            in: library,
            bundleIdentifier: bundleIdentifier
        )
    }
} catch {
    NSLog("Could not clear saved scene state: %@", String(describing: error))
}

// Nothing more runs before UIApplicationMain. A prewarmed process stops right
// here and may resume much later, after "Reset on Next Launch" was turned on
// in the Settings app; AppDelegate.prepareEnvironment() runs on the launch
// itself.
MainActor.assumeIsolated {
    _ = UIApplicationMain(
        CommandLine.argc,
        CommandLine.unsafeArgv,
        nil,
        NSStringFromClass(AppDelegate.self)
    )
}
