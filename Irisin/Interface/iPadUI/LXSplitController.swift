//
//  LXSplitController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import SnapKit
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
    private let panel = LXSplitPanelController()
    private lazy var column = LXColumnHostController(content: navigator)

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
        panel.dashNavCard.onSelect = { [navigator] page in navigator.show(page) }
        let sidebar = UINavigationController(rootViewController: panel)
        sidebar.navigationBar.prefersLargeTitles = true
        setViewController(sidebar, for: .primary)
        // A column that is not a navigation controller gets one from UIKit,
        // bar and all, stacked on the navigator's own. Ours has no bar; the
        // button that brings the sidebar back goes on the navigator's.
        let secondary = UINavigationController(rootViewController: column)
        secondary.setNavigationBarHidden(true, animated: false)
        setViewController(secondary, for: .secondary)
        delegate = self
        navigator.delegate = self
    }

    /// Loads and lays out both columns, then waits for the detail column's
    /// first page, up to `budget`, so the two arrive in the same frame.
    func prepare(within budget: Duration) async {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        await navigator.prepare(within: budget)
    }

    /// The Queue card, as a tap on it.
    func showQueue() {
        panel.dashNavCard.open(.queue)
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

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated _: Bool
    ) {
        syncSidebarToggle(on: viewController)
        // the Queue page and what it pushes need no way to the queue
        column.isQueueOpen = navigationController.viewControllers.first is QueueController
    }
}

/// Hosts a column's content inside the column's safe area, so a screen
/// that lays out to its view's edges lays out to the visible pane. The
/// queue's bar floats at the bottom of that pane: the sidebar's Queue card
/// says as much while it is there, and the sidebar can be hidden.
final class LXColumnHostController: UIViewController {
    let content: UIViewController
    private var queueBar: QueueBarDock?

    /// The content shows the Queue page: see `QueueBarDock.isQueueOpen`.
    var isQueueOpen = false {
        didSet { queueBar?.isQueueOpen = isQueueOpen }
    }

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
        view.addSubview(content.view)
        content.view.snp.makeConstraints { x in
            x.leading.equalTo(view.safeAreaLayoutGuide)
            x.trailing.top.bottom.equalToSuperview()
        }
        content.didMove(toParent: self)

        let pane = UILayoutGuide()
        view.addLayoutGuide(pane)
        pane.snp.makeConstraints { x in
            x.edges.equalTo(content.view)
        }
        queueBar = QueueBarDock(host: self, centeredIn: pane) { [content] in [content] }
        queueBar?.isQueueOpen = isQueueOpen
        queueBar?.bottomInset = view.safeAreaInsets.bottom
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        queueBar?.bottomInset = view.safeAreaInsets.bottom
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
