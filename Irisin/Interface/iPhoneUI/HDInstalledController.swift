//
//  HDInstalledController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import UIKit

class HDInstalledNavigator: UINavigationController {
    private var subscriptions = Set<AnyCancellable>()
    private var updateCountTask: Task<Void, Never>?

    init() {
        super.init(rootViewController: HDInstalledController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(localized: "Installed"),
            image: UIImage.fluent(.textChangeAccept24Filled),
            tag: 0
        )
        tabBarItem.badgeColor = .buttonNormal

        NotificationCenter.default.publisher(for: PackageCenter.packageRecordChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAvailableUpdateBadge() }
            .store(in: &subscriptions)
    }

    func updateAvailableUpdateBadge() {
        updateCountTask?.cancel()
        updateCountTask = Task { [weak self] in
            let count = await InterfaceBridge.availableUpdateCount()
            guard !Task.isCancelled, let self else { return }
            setTabBadge(count > 0 ? String(count) : nil)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class HDInstalledController: InstalledController {}
