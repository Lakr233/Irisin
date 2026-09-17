//
//  SettingController+Application.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/28.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AlertController
import UIKit

extension SettingController {
    func actionItems() -> [SettingItem] {
        var items: [SettingItem] = []
        #if DEBUG
            items.append(SettingItem(
                id: "app.crash",
                icon: "xmark.octagon.fill",
                title: "Simulate Crash",
                kind: .disclosure,
                action: {
                    fatalError("simulated application crash by user", file: #file, line: #line)
                }
            ))
        #endif
        items += [
            SettingItem(
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
            SettingItem(
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
                        SettingController.leaveApplication(with: .respring, from: self)
                    }
                }
            ),
            SettingItem(
                id: "app.logs",
                icon: "doc.richtext",
                title: String(localized: "View Logs"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.presentLogViewer()
                }
            ),
        ]
        return items
    }
}
