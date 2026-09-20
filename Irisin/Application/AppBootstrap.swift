//
//  AppBootstrap.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Foundation

/// Brings up every engine, once per process. Their state lives on the main
/// actor; each does its reading off it and returns when done. No screen
/// waits on this: the interface is up first and its pages fill in as the
/// centers announce what they read.
enum AppBootstrap {
    private static var task: Task<Void, Never>?

    /// Called once the environment is prepared and before a scene connects.
    /// A bootstrap this build was not packaged for is never read.
    static func start() {
        guard task == nil, PackagedArchitecture.incompatibilityMessage == nil else { return }

        // read now, before a page counts updates: a blocked package is
        // never in the first count
        PackageCenter.default.restoreUpdatePreferences()

        task = Task {
            DeviceIdentity.applyNetworkingHeaders()

            // MARK: - CENTER

            await PackageCenter.default.load()
            await RepositoryCenter.default.load()

            // MARK: - PRIVILEGED BACKEND

            PrivilegedBackend.start()

            // MARK: - DOWNLOAD ENGINE

            CellularPolicy.allowForThisApplication()

            await Downloads.shared.load()

            // MARK: - PROCESSOR

            _ = Installer.shared
        }
    }

    /// Returns when the engines are up; `false` where they never start.
    static func finished() async -> Bool {
        guard let task else { return false }
        await task.value
        return true
    }
}
