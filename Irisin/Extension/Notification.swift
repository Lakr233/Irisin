//
//  Notification.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Foundation

nonisolated extension Notification.Name {
    static let RepositoryQueueChanged = Notification.Name("wiki.qaq.RepositoryQueueChanged")
    static let RepositoryPaymentChanged = Notification.Name("wiki.qaq.RepositoryPaymentChanged")


    static let SettingsDidChange = Notification.Name("wiki.qaq.SettingsDidChange")
}
