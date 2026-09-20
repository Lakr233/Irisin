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
    static let RepositoryPaymenChanged = Notification.Name("wiki.qaq.RepositoryPaymenChanged")


    static let SettingReload = Notification.Name("wiki.qaq.SettingReload")
}
