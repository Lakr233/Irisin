//
//  DetailNavigator.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

/// What a sidebar card opens in the detail column.
enum DetailPage {
    case dashboard, settings, installed, queue
}

/// The detail column. The page a sidebar card picks is the stack's root,
/// so there is nothing under it to go back to: no back button, no swipe,
/// and a page that pops itself stops there.
class DetailNavigator: UINavigationController {
    private let dashboard = SplitDashboardController()
    private let settings = SettingsController()
    private let installed = SplitInstalledController()
    private let queue = QueueController()

    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = [dashboard]
        // the detail side never grows a large title, whatever a page asks for
        navigationBar.prefersLargeTitles = false
    }

    /// Puts `page` at the root of the column.
    func show(_ page: DetailPage) {
        let target: UIViewController = switch page {
        case .dashboard: dashboard
        case .settings: settings
        case .installed: installed
        case .queue: queue
        }
        guard topViewController !== target else { return }
        // one step: a pop followed by a push lands on a stack two screens
        // deep only after the next touch
        setViewControllers([target], animated: false)
    }
}
