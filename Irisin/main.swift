//
//  main.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/5.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

// Nothing else runs before UIApplicationMain. A prewarmed process stops right
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
