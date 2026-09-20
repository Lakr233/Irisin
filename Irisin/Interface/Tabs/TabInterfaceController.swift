//
//  TabInterfaceController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import Combine
import UIKit

class TabInterfaceController: UITabBarController {
    private var subscriptions = Set<AnyCancellable>()
    private let queue = QueueNavigator()
    /// Every tab, the Queue tab included: `UITab`s from iOS 18, the
    /// controllers before it.
    private var everyTab: [AnyObject] = []
    /// The bar over every tab but the Queue's own, while there is a queue.
    private var queueBar: QueueBarDock?

    override func viewDidLoad() {
        super.viewDidLoad()

        let dashboard = DashboardNavigator()
        let repositories = RepositoriesNavigator()
        let installed = InstalledNavigator()
        let queue = queue
        let search = SearchNavigator()

        if #available(iOS 18.0, *) {
            let searchTab = UISearchTab { _ in search }
            // iOS 26 set the search tab apart on its own; from iOS 27 that
            // place is the prominent tab's, and a search tab only takes it
            // unasked when it activates search by itself, which ours does not.
            //
            // Set through KVC, not `prominentTabIdentifier =`: the property
            // arrived in the iOS 27 SDK and the runners have Xcode 26, whose
            // SDK has no such symbol to compile against — `#available` guards
            // the call at run time, not the reference at build time. The name
            // is the property's own, so the effect is the same wherever this
            // was built. Put `prominentTabIdentifier = searchTab.identifier`
            // back the day the runner image ships Xcode 27.
            if #available(iOS 27.0, *) {
                setValue(searchTab.identifier, forKey: "prominentTabIdentifier")
            }
            everyTab = [
                UITab(
                    title: dashboard.tabBarItem.title ?? "",
                    image: dashboard.tabBarItem.image,
                    identifier: "dashboard"
                ) { _ in dashboard },
                UITab(
                    title: repositories.tabBarItem.title ?? "",
                    image: repositories.tabBarItem.image,
                    identifier: "repositories"
                ) { _ in repositories },
                UITab(
                    title: installed.tabBarItem.title ?? "",
                    image: installed.tabBarItem.image,
                    identifier: "installed"
                ) { _ in installed },
                UITab(
                    title: queue.tabBarItem.title ?? "",
                    image: queue.tabBarItem.image,
                    identifier: "queue"
                ) { _ in queue },
                searchTab,
            ]
            tabs = everyTab.compactMap { $0 as? UITab }
        } else {
            everyTab = [dashboard, repositories, installed, queue, search]
            viewControllers = everyTab.compactMap { $0 as? UIViewController }
        }

        NotificationCenter.default.publisher(for: .PackageQueueChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateQueueTab() }
            .store(in: &subscriptions)

        selectedIndex = 0
        // the bar opens without the Queue tab; taking it out is not a change
        // for the user to watch
        updateQueueTab(animated: false)

        let pages = [dashboard, repositories, installed, search]
        queueBar = QueueBarDock(host: self, centeredIn: view.safeAreaLayoutGuide) { pages }
        // The Queue tab says when it is the one on screen, as it arrives:
        // however it was selected, the bar is gone before its page shows.
        queue.visibilityChanged = { [weak self] visible in self?.queueBar?.isQueueOpen = visible }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Above the tab bar where it is at the bottom; an iPad window wide
        // enough has it at the top, and the bar keeps to the safe area.
        let atBottom = !tabBar.isHidden && tabBar.frame.midY > view.bounds.midY
        queueBar?.bottomInset = atBottom ? view.bounds.maxY - tabBar.frame.minY : view.safeAreaInsets.bottom
    }

    /// The Queue tab is there while there is a queue, and while it is open:
    /// a queue that finishes does not pull the page from under the user.
    /// `UITab.isHidden` only hides a tab from the sidebar, so the tab
    /// leaves the list instead.
    private func updateQueueTab(animated: Bool = true) {
        let shown = PackageQueue.shared.plan != nil || selectedViewController === queue
        if #available(iOS 18.0, *) {
            let every = everyTab.compactMap { $0 as? UITab }
            guard tabs.contains(where: { $0.identifier == "queue" }) != shown else { return }
            setTabs(shown ? every : every.filter { $0.identifier != "queue" }, animated: animated)
        } else {
            let every = everyTab.compactMap { $0 as? UIViewController }
            guard viewControllers?.contains(queue) != shown else { return }
            setViewControllers(shown ? every : every.filter { $0 !== queue }, animated: animated)
        }
    }

    /// Selects the Queue tab, at its list. With no queue there is no tab.
    func showQueue() {
        updateQueueTab()
        if #available(iOS 18.0, *) {
            guard let tab = tabs.first(where: { $0.identifier == "queue" }) else { return }
            selectedTab = tab
        } else {
            guard viewControllers?.contains(queue) == true else { return }
            selectedViewController = queue
        }
        queue.popToRootViewController(animated: false)
    }

    private var lastSelectedIndex: Int?
    private var tapCount = 0
    override func tabBar(_: UITabBar, didSelect _: UITabBarItem) {
        // double tap to select search bar, or to refresh the repositories; the tab has switched once this returns
        Task { [self] in
            updateQueueTab()
            if lastSelectedIndex == selectedIndex {
                tapCount += 1
                if tapCount >= 2 {
                    lastSelectedIndex = nil
                    let page = (selectedViewController as? UINavigationController)?.topViewController
                    if let controller = page as? SearchController {
                        controller.searchController.searchBar.becomeFirstResponder()
                    }
                    if let controller = page as? InstalledController {
                        controller.searchController.searchBar.becomeFirstResponder()
                    }
                    if let controller = page as? RepositoriesController {
                        controller.refreshFromTab()
                    }
                }
            } else {
                lastSelectedIndex = selectedIndex
                tapCount = 0
            }
        }
    }
}

class QueueNavigator: UINavigationController {
    private var subscriptions = Set<AnyCancellable>()

    /// The tab comes on screen (true, before it shows) or has left it.
    var visibilityChanged: ((Bool) -> Void)?

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visibilityChanged?(true)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visibilityChanged?(false)
    }

    init() {
        super.init(rootViewController: QueueController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(localized: "Queue"),
            image: UIImage(systemName: "tray.full.fill"),
            tag: 0
        )

        NotificationCenter.default.publisher(for: .PackageQueueChanged)
            .receive(on: DispatchQueue.main)
            .map { _ in QueueController.badge }
            .prepend(QueueController.badge)
            .removeDuplicates()
            .sink { [weak self] badge in self?.setTabBadge(badge) }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
