//
//  SettingsController+Package.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/28.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension SettingsController {
    /// How packages are shown and handled.
    func packageItems() -> [SettingsItem] {
        let items: [SettingsItem?] = [
            SettingsItem(
                id: "package.translate",
                icon: "character.bubble",
                title: String(localized: "Auto Translate"),
                kind: .toggle,
                isOn: { AutomaticTranslation.isEnabled },
                setOn: { [weak self] isOn in
                    guard isOn else {
                        AutomaticTranslation.isEnabled = false
                        return
                    }
                    // on only once the device has shown it can: the switch
                    // goes back until the translator has answered
                    Task { [weak self] in
                        if let failure = await SystemTranslator.verify() {
                            self?.presentNotice(
                                title: "Unable to Translate",
                                message: AutomaticTranslation.describe(failure)
                            )
                        } else {
                            AutomaticTranslation.isEnabled = true
                            AutomaticTranslation.failureWasShown = false
                        }
                        self?.dispatchValueUpdate()
                    }
                    self?.dispatchValueUpdate()
                }
            ),
            SettingsItem(
                id: "package.blocked",
                icon: "hand.raised.fill",
                title: String(localized: "Blocked Updates"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.present(next: BlockUpdateController())
                }
            ),
            SettingsItem(
                id: "package.emptyRepositories",
                icon: "sparkles",
                title: String(localized: "Clean Up Repositories"),
                kind: .disclosure,
                action: { [weak self] in
                    guard let self else { return }
                    EmptyRepositoriesController.present(from: self)
                }
            ),
            compatibilityUpdatesItem(),
            SettingsItem(
                id: "package.systemRemoval",
                icon: "exclamationmark.shield",
                title: String(localized: "Power Operations"),
                kind: .toggle,
                isOn: { PackageQueue.shared.allowSystemRemoval },
                setOn: { [weak self] isOn in
                    guard isOn else {
                        PackageQueue.shared.allowSystemRemoval = false
                        return
                    }
                    self?.presentConfirmation(
                        title: "Allow Power Operations?",
                        message: "Removing a package the system requires can stop the custom firmware or this app from working.",
                        confirmTitle: "Allow",
                        destructive: true
                    ) { [weak self] in
                        PackageQueue.shared.allowSystemRemoval = true
                        self?.dispatchValueUpdate()
                    }
                    // the switch follows the stored value: it goes back
                    // until the confirmation says otherwise
                    self?.dispatchValueUpdate()
                }
            ),
        ]
        return items.compactMap(\.self)
    }

    /// Whether a package installed in compatibility mode is offered its
    /// newer versions, each converted again. Off until the user allows it,
    /// and no row at all on a bootstrap nothing is converted for.
    private func compatibilityUpdatesItem() -> SettingsItem? {
        guard AptRepositoryBootstrap.installableArchitectures.count > 1 else { return nil }
        return SettingsItem(
            id: "package.compatibilityUpdates",
            icon: "arrow.triangle.2.circlepath",
            title: String(localized: "Compatibility Updates"),
            kind: .toggle,
            isOn: { PackageCenter.default.offersAdaptedUpdates },
            setOn: { [weak self] isOn in
                guard isOn else {
                    PackageCenter.default.offersAdaptedUpdates = false
                    return
                }
                self?.presentConfirmation(
                    title: "Allow Compatibility Updates?",
                    message: "An update to a package installed in compatibility mode is converted again. It may stop working and damage the system.",
                    confirmTitle: "Allow",
                    destructive: true
                ) { [weak self] in
                    PackageCenter.default.offersAdaptedUpdates = true
                    self?.dispatchValueUpdate()
                }
                // the switch goes back until the confirmation says otherwise
                self?.dispatchValueUpdate()
            }
        )
    }

    /// The files the app has fetched and keeps.
    func downloadItems() -> [SettingsItem] {
        [
            SettingsItem(
                id: "package.downloads",
                icon: "tray.full",
                title: String(localized: "Downloads Folder"),
                kind: .disclosure,
                action: { [weak self] in
                    self?.openInFila(path: Downloads.shared.workingLocation.path)
                }
            ),
            SettingsItem(
                id: "package.clean",
                icon: "trash",
                title: String(localized: "Clear Downloads"),
                kind: .value,
                value: {
                    var compute = 0
                    if let cache = try? PartialDownloads.directory.directoryTotalAllocatedSize() {
                        compute += cache
                    }
                    if let download = try? Downloads.shared.workingLocation.directoryTotalAllocatedSize() {
                        compute += download
                    }
                    if let staged = try? Installer.shared.workingLocation.directoryTotalAllocatedSize() {
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
                    return confirmMenu(String(localized: "Clear Downloads")) {
                        Downloads.shared.clear()
                        try? FileManager.default
                            .removeItem(at: documentsDirectory.appendingPathComponent("DirectInstallCache"))
                        if !Installer.shared.inProcessingQueue {
                            // a running operation reads from here; its files go when it ends
                            try? FileManager.default.removeItem(at: Installer.shared.workingLocation)
                        }
                        self.dispatchValueUpdate()
                    }
                }
            ),
        ]
    }
}
