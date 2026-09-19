//
//  LXSplitController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Then
import UIKit

/// The iPad interface: the panel of cards on the left, the detail navigator
/// on the right. Column style, tiled. iOS 26 still hands the secondary
/// column the whole window and marks the panel's width as a left safe
/// area, so the navigator is hosted inside that safe area: every detail
/// screen then lays out in the visible pane and never under the panel.
class LXSplitController: UISplitViewController {
    /// The detail column's stack, where the sidebar opens a repository.
    let navigator = LXMainNavigator()

    init() {
        super.init(style: .doubleColumn)
        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        applySplitWidth()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        makeViewControllers()
    }

    func makeViewControllers() {
        let notificationToken = UUID().uuidString
        let split = LXSplitPanelController()
        split.notificationToken = notificationToken
        navigator.notificationToken = notificationToken
        let sidebar = UINavigationController(rootViewController: split)
        sidebar.navigationBar.prefersLargeTitles = true
        setViewController(sidebar, for: .primary)
        // A column that is not a navigation controller gets one from UIKit,
        // bar and all, stacked on the navigator's own. Ours has no bar; the
        // button that brings the sidebar back goes on the navigator's.
        let column = UINavigationController(rootViewController: LXColumnHostController(content: navigator))
        column.setNavigationBarHidden(true, animated: false)
        setViewController(column, for: .secondary)
        delegate = self
        navigator.delegate = self
    }

    /// Loads both columns and waits for the detail column's first page, up
    /// to `budget`, so the two arrive in the same frame.
    func prepare(within budget: Duration) async {
        loadViewIfNeeded()
        await navigator.prepare(within: budget)
    }

    private var isSidebarHidden = false

    /// One item per screen: a bar button item has one view, and a push
    /// draws the departing and the arriving bar together.
    private func syncSidebarToggle(on controller: UIViewController) {
        let item = controller.navigationItem
        var items = (item.leftBarButtonItems ?? []).filter { !($0 is SidebarToggleItem) }
        if isSidebarHidden {
            if items.isEmpty {
                item.leftItemsSupplementBackButton = true
            }
            items.insert(SidebarToggleItem(
                image: UIImage(systemName: "sidebar.leading"),
                primaryAction: UIAction { [weak self] _ in self?.show(.primary) }
            ).then { $0.accessibilityLabel = String(localized: "Show Sidebar") }, at: 0)
        }
        item.leftBarButtonItems = items.isEmpty ? nil : items
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applySplitWidth()
    }

    func applySplitWidth() {
        preferredPrimaryColumnWidthFraction = 0.34
        maximumPrimaryColumnWidth = 340
        minimumPrimaryColumnWidth = 340
    }
}

private final class SidebarToggleItem: UIBarButtonItem {}

extension LXSplitController: UISplitViewControllerDelegate, UINavigationControllerDelegate {
    func splitViewController(_: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
        isSidebarHidden = displayMode == .secondaryOnly
        if let top = navigator.topViewController {
            syncSidebarToggle(on: top)
        }
    }

    func navigationController(_: UINavigationController, willShow viewController: UIViewController, animated _: Bool) {
        syncSidebarToggle(on: viewController)
    }
}

/// Hosts a column's content inside the column's safe area, so a screen
/// that lays out to its view's edges lays out to the visible pane.
final class LXColumnHostController: UIViewController {
    let content: UIViewController

    init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(content:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // the detail column sits a step above the sidebar: in the dark its
        // grounds resolve to their elevated shade, as a sheet's do
        if #available(iOS 17.0, *) {
            traitOverrides.userInterfaceLevel = .elevated
        }
        view.backgroundColor = .pageBackground
        addChild(content)
        if #unavailable(iOS 17.0) {
            setOverrideTraitCollection(UITraitCollection(userInterfaceLevel: .elevated), forChild: content)
        }
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.didMove(toParent: self)
    }

    override var childForStatusBarStyle: UIViewController? {
        content
    }

    override var childForStatusBarHidden: UIViewController? {
        content
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        content
    }
}
