//
//  AppDelegate+Indicator.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/10.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import Dog
import Foundation
import SPIndicator

extension AppDelegate {
    func observeRepositoryUpdates() {
        repositoryUpdateSubscription = NotificationCenter.default.publisher(for: RepositoryCenter.metadataUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in self?.popIndicator(for: notification) }
    }

    private func popIndicator(for notification: Notification) {
        guard let object = notification.object as? RepositoryCenter.UpdateNotification else {
            Dog.shared.join("AppIndicator", "broken notification payload received \(notification.name)", level: .error)
            return
        }
        if object.complete, !object.success,
           let failedRepoName = RepositoryCenter.default
           .obtainImmutableRepository(withUrl: object.repository)?.nickName
        {
            SPIndicator.present(
                title: String(localized: "Repository update failed"),
                message: failedRepoName,
                preset: .error,
                haptic: .error,
                from: .top,
                completion: nil
            )
        }
        if object.queueLeft < 1 {
            Task {
                try? await Task.sleep(seconds: 1) // prevent hides another
                SPIndicator.present(
                    title: String(localized: "Repositories updated"),
                    message: "", // dont remove this
                    preset: .done,
                    haptic: .success,
                    from: .top,
                    completion: nil
                )
            }
        }
    }
}
