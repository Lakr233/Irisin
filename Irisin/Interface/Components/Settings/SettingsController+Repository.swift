//
//  SettingsController+Repository.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/25.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension SettingsController {
    /// How often a repository may go without a refresh before the app
    /// refreshes it on its own, as the row offers it.
    private static let refreshIntervals: [(interval: TimeInterval, title: String)] = [
        (0, String(localized: "Off")),
        (3600, String(localized: "Every Hour")),
        (6 * 3600, String(localized: "Every 6 Hours")),
        (86400, String(localized: "Every Day")),
    ]

    /// When repositories refresh, and the ones left empty.
    func repositoryItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "repository.autoRefresh",
                icon: "arrow.clockwise",
                title: String(localized: "Auto Refresh"),
                kind: .value,
                value: {
                    let current = RepositoryCenter.default.automaticRefreshInterval
                    // a value no choice names was never written by this row
                    return Self.refreshIntervals.first { $0.interval == current }?.title
                        ?? Duration.seconds(current).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
                },
                menu: { [weak self] in
                    let current = RepositoryCenter.default.automaticRefreshInterval
                    return Self.refreshIntervals.map { choice in
                        UIAction(
                            title: choice.title,
                            state: choice.interval == current ? .on : .off
                        ) { [weak self] _ in
                            RepositoryCenter.default.automaticRefreshInterval = choice.interval
                            // a shorter interval may leave some out of date now
                            AutomaticRefresh.check()
                            self?.dispatchValueUpdate()
                        }
                    }
                }
            ),
            SettingsItem(
                id: "repository.emptyRepositories",
                icon: "sparkles",
                title: String(localized: "Clean Up Repositories"),
                kind: .disclosure,
                action: { [weak self] in
                    guard let self else { return }
                    EmptyRepositoriesController.present(from: self)
                }
            ),
        ]
    }
}
