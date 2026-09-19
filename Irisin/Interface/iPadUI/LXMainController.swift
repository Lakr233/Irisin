//
//  LXMainController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Combine
import Dog
import UIKit

/// The detail column. The page a sidebar card picks is the stack's root,
/// so there is nothing under it to go back to: no back button, no swipe,
/// and a page that pops itself stops there.
class LXMainNavigator: UINavigationController {
    var notificationToken: String = ""

    private var subscriptions = Set<AnyCancellable>()

    private let dashboard = LXDashboardController()
    private let setting = SettingController()
    private let installed = LXInstalledController()
    private let queue = QueueController()

    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = [dashboard]
        // the detail side never grows a large title, whatever a page asks for
        navigationBar.prefersLargeTitles = false

        Publishers.MergeMany([
            .LXMainControllerSwitchDashboard,
            .LXMainControllerSwitchSettings,
            .LXMainControllerSwitchInstalled,
            .LXMainControllerSwitchQueue,
        ].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in self?.switchRoot(withNotification: notification) }
        .store(in: &subscriptions)
    }

    /// The dashboard is what the column opens on: see
    /// `DashboardController.prepare(within:)`.
    func prepare(within budget: Duration) async {
        loadViewIfNeeded()
        await dashboard.prepare(within: budget)
    }

    private func switchRoot(withNotification notification: Notification) {
        if let token = notification.object as? String, token != notificationToken {
            Dog.shared.join(self, "ignoring a root controller request meant for \(token)", level: .warning)
            return
        }
        let target: UIViewController
        switch notification.name {
        case .LXMainControllerSwitchDashboard: target = dashboard
        case .LXMainControllerSwitchSettings: target = setting
        case .LXMainControllerSwitchInstalled: target = installed
        case .LXMainControllerSwitchQueue: target = queue
        default:
            Dog.shared.join(
                self,
                "failed to obtain coordinated view controller, giving up with notification [\(notification.name)]",
                level: .error
            )
            return
        }
        guard topViewController !== target else { return }
        // one step: a pop followed by a push lands on a stack two screens
        // deep only after the next touch
        setViewControllers([target], animated: false)
    }
}
