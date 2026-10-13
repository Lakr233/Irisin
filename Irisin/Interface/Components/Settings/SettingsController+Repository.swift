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

    /// An interval no choice names, in days, hours and minutes. Duration's
    /// style is iOS 16; DateComponentsFormatter says the same below it.
    private static func spelledInterval(_ seconds: TimeInterval) -> String {
        if #available(iOS 16, *) {
            return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
        }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        return formatter.string(from: seconds) ?? ""
    }

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
                        ?? Self.spelledInterval(current)
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
