//
//  SettingController+Package.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/28.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension SettingController {
    func packageItems() -> [SettingItem] {
        [
            SettingItem(
                id: "package.downloads",
                icon: "tray.full",
                title: String(localized: "Open Downloads Folder"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.openInFila(path: DownloadCenter.shared.workingLocation.path)
                }
            ),
            SettingItem(
                id: "package.clean",
                icon: "trash",
                title: String(localized: "Delete All Downloads"),
                kind: .value,
                value: {
                    var compute = 0
                    if let cache = try? PartialDownloads.directory.directoryTotalAllocatedSize() {
                        compute += cache
                    }
                    if let download = try? DownloadCenter.shared.workingLocation.directoryTotalAllocatedSize() {
                        compute += download
                    }
                    if let staged = try? TaskProcessor.shared.workingLocation.directoryTotalAllocatedSize() {
                        compute += staged
                    }
                    if let directInstallSize = try? documentsDirectory
                        .appendingPathComponent("DirectInstallCache")
                        .directoryTotalAllocatedSize()
                    {
                        compute += directInstallSize
                    }
                    let formatter = ByteCountFormatter()
                    formatter.allowedUnits = [.useAll]
                    formatter.countStyle = .file
                    formatter.allowsNonnumericFormatting = false // "0 KB", not "Zero KB"
                    return formatter.string(fromByteCount: Int64(max(compute, 0)))
                },
                menu: { [weak self] in
                    guard let self else { return [] }
                    return confirmMenu(String(localized: "Delete All Downloads")) {
                        DownloadCenter.shared.clear()
                        try? FileManager.default
                            .removeItem(at: documentsDirectory.appendingPathComponent("DirectInstallCache"))
                        if !TaskProcessor.shared.inProcessingQueue {
                            // a running operation reads from here; its files go when it ends
                            try? FileManager.default.removeItem(at: TaskProcessor.shared.workingLocation)
                        }
                        self.dispatchValueUpdate()
                    }
                }
            ),
            SettingItem(
                id: "package.blocked",
                icon: "hand.raised.fill",
                title: String(localized: "Blocked Updates"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.present(next: BlockUpdateController())
                }
            ),
            SettingItem(
                id: "package.systemRemoval",
                icon: "exclamationmark.shield",
                title: String(localized: "Allow Removing System Packages"),
                kind: .toggle,
                isOn: { TaskManager.shared.allowSystemRemoval },
                setOn: { [weak self] isOn in
                    guard isOn else {
                        TaskManager.shared.allowSystemRemoval = false
                        return
                    }
                    self?.presentConfirmation(
                        title: "Allow Removing System Packages?",
                        message: "Removing a package the system requires can stop the jailbreak or this app from working.",
                        confirmTitle: "Allow",
                        destructive: true
                    ) { [weak self] in
                        TaskManager.shared.allowSystemRemoval = true
                        self?.dispatchValueUpdate()
                    }
                    // the switch follows the stored value: it goes back
                    // until the confirmation says otherwise
                    self?.dispatchValueUpdate()
                }
            ),
        ]
    }
}
