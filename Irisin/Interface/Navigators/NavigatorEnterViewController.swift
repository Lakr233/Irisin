//
//  NavigatorEnterViewController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Dog
import UIKit

/// The root container: the split layout on a wide iPad, the tab bar layout
/// everywhere else, swapped as the window is resized. A plain child
/// controller, not a tab bar controller: on iPadOS 18 a tab bar controller
/// puts its bar at the top of the screen and keeps that space even when the
/// bar is hidden.
class NavigatorEnterViewController: UIViewController {
    private var hdMain: HandyTabBarController?
    private var lxMain: LXSplitController?
    /// The layout on screen right now.
    private(set) var current: UIViewController?

    /// Where a page opened from outside the interface goes: the detail
    /// column on the iPad, the selected tab's stack elsewhere.
    var pageStack: UINavigationController? {
        if let split = current as? LXSplitController {
            return split.navigator
        }
        return (current as? UITabBarController)?.selectedViewController as? UINavigationController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground
        setExceptedRootViewController()
    }

    /// Waits for the split layout's first page, up to `budget`, so the
    /// interface is presented whole: the sidebar has its cards at once,
    /// and a detail column that fills in a moment later reads as a blink.
    func prepare(within budget: Duration) async {
        loadViewIfNeeded()
        await lxMain?.prepare(within: budget)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // a link that opened the app gets its sheet; onboarding waits for
        // the next time the interface appears
        if WelcomeController.shouldPresent, presentedViewController == nil {
            present(WelcomeController.makeNavigator(), animated: true)
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        setExceptedRootViewController()
    }

    override var childForStatusBarStyle: UIViewController? {
        current
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        current
    }

    func setExceptedRootViewController() {
        let target: UIViewController
        if shouldUseLargeUI() {
            let controller = lxMain ?? LXSplitController()
            lxMain = controller
            target = controller
        } else {
            let controller = hdMain ?? HandyTabBarController()
            hdMain = controller
            target = controller
        }
        guard target !== current else { return }
        Dog.shared.join(
            "Interface",
            "loading the \(target is LXSplitController ? "split" : "tab bar") interface",
            level: .info
        )

        if let current {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        addChild(target)
        target.view.frame = view.bounds
        target.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(target.view)
        target.didMove(toParent: self)
        current = target
    }

    func shouldUseLargeUI() -> Bool {
        if UIDevice.current.userInterfaceIdiom != .pad {
            return false
        }
        if !(view.frame.width > 700 && view.frame.height > 700) {
            return false
        }
        return true
    }
}
