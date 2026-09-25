//
//  Notification.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Foundation

nonisolated extension Notification.Name {
    static let RepositoryQueueChanged = Notification.Name("wiki.qaq.RepositoryQueueChanged")
    static let RepositoryPaymentChanged = Notification.Name("wiki.qaq.RepositoryPaymentChanged")

    static let SettingsDidChange = Notification.Name("wiki.qaq.SettingsDidChange")
}

nonisolated extension Notification {
    /// A repository's download moved without finishing. The rows drawing the
    /// progress want it; a page listing what the repositories offer does
    /// not, since nothing it shows changes until the refresh completes.
    var isRepositoryProgress: Bool {
        (object as? RepositoryCenter.UpdateNotification)?.complete == false
    }
}
