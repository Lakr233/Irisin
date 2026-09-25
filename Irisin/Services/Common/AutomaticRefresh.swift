//
//  AutomaticRefresh.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/25.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import Foundation

/// Auto Refresh after launch: `RepositoryCenter` refreshes what is out of
/// date when it loads, and this looks again once a minute, when the app
/// comes back and when the setting changes. Never while an operation runs:
/// a refresh then moves the catalogue under the plan being carried out.
enum AutomaticRefresh {
    private static var loop: Task<Void, Never>?

    /// Starts the minute's look, once per process, after the engines are up.
    static func start() {
        guard loop == nil else { return }
        loop = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                check()
            }
        }
    }

    /// Queues what is older than the setting allows, and says so to the
    /// lists that show the queue.
    static func check() {
        guard AppBootstrap.isFinished, !Installer.shared.inProcessingQueue else { return }
        guard RepositoryCenter.default.dispatchAutomaticRefresh() else { return }
        NotificationCenter.default.post(name: .RepositoryQueueChanged, object: nil)
    }
}
