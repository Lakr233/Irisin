//
//  InterfaceHostController.swift
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
class InterfaceHostController: UIViewController {
    private var tabs: TabInterfaceController?
    private var split: SplitInterfaceController?
    /// The layout on screen right now.
    private(set) var current: UIViewController?

    /// Where a page opened from outside the interface goes: the detail
    /// column on the iPad, the selected tab's stack elsewhere.
    var pageStack: UINavigationController? {
        if let split = current as? SplitInterfaceController {
            return split.navigator
        }
        return (current as? UITabBarController)?.selectedViewController as? UINavigationController
    }

    /// The interface `controller` is in, or is presented over.
    static func enclosing(_ controller: UIViewController) -> InterfaceHostController? {
        var node: UIViewController? = controller
        while let current = node {
            if let interface = current as? InterfaceHostController {
                return interface
            }
            node = current.parent ?? current.presentingViewController
        }
        return nil
    }

    /// Shows the Queue page: whatever sheet is up leaves, then the Queue
    /// card or tab is selected as a tap selects it.
    func openQueue() {
        if presentedViewController != nil {
            dismiss(animated: true)
        }
        (current as? SplitInterfaceController)?.showQueue()
        (current as? TabInterfaceController)?.showQueue()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground
    }

    /// Takes the size it is about to be presented at and lays out, so the
    /// layout is picked for that size and every page under it has its width
    /// before its first snapshot: a page that fills in with no width draws
    /// `PackageListRow.minimumSize` cells for a frame. Then waits for the split
    /// layout's first page, up to `budget`, so the interface is presented
    /// whole: the sidebar has its cards at once, and a detail column that
    /// fills in a moment later reads as a blink.
    func prepare(filling bounds: CGRect, within budget: Duration) async {
        loadViewIfNeeded()
        view.frame = bounds
        installRootIfNeeded()
        view.layoutIfNeeded()
        await split?.prepare(within: budget)
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
        installRootIfNeeded()
    }

    override var childForStatusBarStyle: UIViewController? {
        current
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        current
    }

    func installRootIfNeeded() {
        let target: UIViewController
        if usesSplitLayout {
            let controller = split ?? SplitInterfaceController()
            split = controller
            target = controller
        } else {
            let controller = tabs ?? TabInterfaceController()
            tabs = controller
            target = controller
        }
        guard target !== current else { return }
        Dog.shared.join(
            "Interface",
            "loading the \(target is SplitInterfaceController ? "split" : "tab bar") interface",
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

    var usesSplitLayout: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && view.frame.width > 700 && view.frame.height > 700
    }
}
