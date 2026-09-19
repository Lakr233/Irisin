//
//  main.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/5.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

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
        try SceneRestorationReset.removeSavedState(
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
