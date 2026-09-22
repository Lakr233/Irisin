//
//  TabDashboardController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import SPIndicator
import UIKit

class DashboardNavigator: UINavigationController {
    init() {
        super.init(rootViewController: TabDashboardController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(localized: "Dashboard"),
            image: UIImage.fluent(.timeline24Regular),
            tag: 0
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

class TabDashboardController: DashboardController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground
        title = String(localized: "Dashboard")

        let settings = UIBarButtonItem(
            image: .fluent(.settings24Regular),
            style: .plain,
            target: self,
            action: #selector(rightButtonCall)
        )
        settings.accessibilityLabel = String(localized: "Settings")
        navigationItem.rightBarButtonItem = settings

        refreshControl.alpha = 0
    }

    @objc
    func rightButtonCall() {
        let target = SettingsController()
        present(next: target)
    }
}
