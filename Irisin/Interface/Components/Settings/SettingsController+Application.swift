//
//  SettingsController+Application.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/28.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AlertController
import UIKit

extension SettingsController {
    /// What is done to the system around the app.
    func systemItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "app.uicache",
                icon: "square.grid.2x2",
                title: String(localized: "Rebuild Icons"),
                kind: .disclosure,
                action: { [weak self] in
                    let alert = progressAlert(
                        title: "Rebuilding Icons…",
                        message: "Rebuilding home screen icons will take some time."
                    )
                    self?.present(alert, animated: true) {
                        Task { [weak self] in
                            let outcome = await PrivilegedBackend.runMaintenance(.rebuildIconCache)
                            alert.dismiss(animated: true) {
                                self?.report(outcome, succeeded: "Icons rebuilt", failed: "Unable to Rebuild Icons")
                            }
                        }
                    }
                }
            ),
            SettingsItem(
                id: "app.respring",
                icon: "rays",
                title: String(localized: "Reload Home Screen"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.presentConfirmation(
                        title: "Reload Home Screen?",
                        message: "The home screen restarts and every open app closes.",
                        confirmTitle: "Reload"
                    ) { [weak self] in
                        SettingsController.leaveApplication(with: .respring, from: self)
                    }
                }
            ),
        ]
    }

    /// Where to look, and whom to tell, when something went wrong.
    func supportItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "app.logs",
                icon: "doc.richtext",
                title: String(localized: "View Logs"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.presentLogViewer()
                }
            ),
            SettingsItem(
                id: "app.report",
                icon: "exclamationmark.bubble",
                title: String(localized: "Report Issue"),
                kind: .disclosure,
                action: {
                    guard let url = URL(string: "https://github.com/Lakr233/Irisin/issues/new") else { return }
                    UIApplication.shared.open(url)
                }
            ),
        ]
    }
}
