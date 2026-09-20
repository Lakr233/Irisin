//
//  RepositoriesController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import Dog
import SPIndicator
import Then
import UIKit
import UniformTypeIdentifiers

class RepositoriesNavigator: UINavigationController {
    private var subscriptions = Set<AnyCancellable>()

    init() {
        super.init(rootViewController: RepositoriesController())

        navigationBar.prefersLargeTitles = true

        tabBarItem = UITabBarItem(
            title: String(localized: "Repositories"),
            image: UIImage.fluent(.bookCompass24Regular),
            tag: 0
        )

        tabBarItem.badgeColor = .buttonNormal
        NotificationCenter.default.publisher(for: RepositoryCenter.metadataUpdate)
            .receive(on: DispatchQueue.main)
            .map { _ in RepositoryCenter.default.obtainUpdateRemain() }
            .removeDuplicates()
            .sink { [weak self] count in self?.setTabBadge(count > 0 ? String(count) : nil) }
            .store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The registered repositories, one list, nothing else. The iPad lists them
/// in its sidebar (`SidebarController`).
class RepositoriesController: UIViewController {
    private var subscriptions = Set<AnyCancellable>()

    let tableView = UITableView(frame: .zero, style: .plain)
    let refreshControl = SettlingRefreshControl()
    private let cellIdentity = "repository"

    private let footer = ListFootnoteView()

    /// Read as the view loads, never at init: the tab bar makes this page
    /// at launch and nothing listens until the tab is opened, so what
    /// onboarding added in between would be missing.
    private var dataSourceCache: [URL] = []
    private var lastUpdateTouched: Date?

    nonisolated enum Row: Hashable {
        case repository(URL)
        case none
    }

    lazy var diffableDataSource = EditableTableDiffableDataSource<Int, Row>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, row in
        let cell = tableView
            .dequeueReusableCell(withIdentifier: cellIdentity, for: indexPath)
            as! RepositoryTableCell
        cell.backgroundColor = .clear
        cell.contentInsets = UIEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        switch row {
        case .none: cell.setNoRepoAvailable()
        case let .repository(url): cell.setRepository(withUrl: url)
        }
        return cell
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(localized: "Repositories")
        view.backgroundColor = .pageBackground

        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)

        tableView.register(RepositoryTableCell.self, forCellReuseIdentifier: cellIdentity)
        tableView.dataSource = diffableDataSource
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.refreshControl = refreshControl
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        setEditing(false, animated: false)

        reloadDataSource(animated: false)

        Publishers.MergeMany([RepositoryCenter.registrationUpdate, RepositoryCenter.metadataUpdate].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in self?.reloadDataSource() }
        .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: RepositoryCenter.metadataUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settleRefreshControl() }
            .store(in: &subscriptions)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutFooter()
    }

    private var hasListedRepositories = false

    private func applySnapshot(animatingDifferences: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(dataSourceCache.isEmpty ? [.none] : dataSourceCache.uniqued().map(Row.repository))
        snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
        diffableDataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    private func reloadDataSource(animated: Bool = true) {
        // Before the repositories are read there is no list to show, and
        // "No repositories" would be a guess; the first list arrives whole.
        guard RepositoryCenter.default.isLoaded else { return }
        let animated = animated && hasListedRepositories
        hasListedRepositories = true
        dataSourceCache = RepositoryCenter
            .default
            .obtainRepositoryUrls(sortedByName: true)
        applySnapshot(animatingDifferences: animated && tableView.shouldAnimateDiff)
        updateFooter()
    }

    // MARK: - FOOTER

    /// The line under the list, here and under the iPad sidebar's.
    static var footnote: String {
        // no count before there is one: zero would be a guess
        guard RepositoryCenter.default.isLoaded else { return "" }
        let repositories = RepositoryCenter
            .default
            .obtainRepositoryUrls()
            .compactMap { RepositoryCenter.default.obtainImmutableRepository(withUrl: $0) }
        let packages = repositories.reduce(0) { $0 + $1.packageCount }
        return String(localized: "Repositories: \(repositories.count) · Packages: \(packages)")
    }

    private func updateFooter() {
        footer.label.text = Self.footnote
        layoutFooter()
    }

    private func layoutFooter() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let height = footer.label
            .sizeThatFits(CGSize(width: width - 40, height: .greatestFiniteMagnitude))
            .height + 32
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        guard tableView.tableFooterView == nil || footer.frame != frame else { return }
        footer.frame = frame
        tableView.tableFooterView = footer
    }

    // MARK: - EDITING

    /// Editing is multi-selection: a two-finger drag on the list or Edit in
    /// the menu enters it, Done leaves it, and the bar carries what applies
    /// to the selected rows.
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
        if editing {
            navigationItem.setLeftBarButton(deleteSelectedItem, animated: animated)
            navigationItem.setRightBarButtonItems([
                UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(endEditing)),
                refreshSelectedItem,
            ], animated: animated)
        } else {
            navigationItem.setLeftBarButton(nil, animated: animated)
            // one liquid glass group: the ellipsis, then add
            navigationItem.setRightBarButtonItems([
                UIBarButtonItem(
                    image: UIImage(systemName: "plus"),
                    style: .plain,
                    target: self,
                    action: #selector(openAdd)
                ),
                UIBarButtonItem(
                    image: UIImage(systemName: "ellipsis"),
                    menu: moreMenu
                ).then { $0.tintColor = .textTitle },
            ], animated: animated)
        }
        updateSelectionItems()
    }

    private lazy var deleteSelectedItem = UIBarButtonItem(
        title: String(localized: "Delete"),
        style: .plain,
        target: self,
        action: #selector(deleteSelected)
    ).then {
        $0.tintColor = .destructiveAction
    }

    private lazy var refreshSelectedItem = UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        style: .plain,
        target: self,
        action: #selector(refreshSelected)
    )

    private var selectedUrls: [URL] {
        (tableView.indexPathsForSelectedRows ?? []).compactMap { url(at: $0) }
    }

    func updateSelectionItems() {
        let any = !selectedUrls.isEmpty
        deleteSelectedItem.isEnabled = any
        refreshSelectedItem.isEnabled = any
    }

    @objc
    private func endEditing() {
        setEditing(false, animated: true)
    }

    @objc
    private func deleteSelected() {
        let urls = selectedUrls
        guard !urls.isEmpty else { return }
        delete(urls)
        setEditing(false, animated: true)
    }

    /// Asks first: a repository takes its whole catalogue with it.
    func delete(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let names = urls.compactMap { RepositoryCenter.default.obtainImmutableRepository(withUrl: $0)?.nickName }
        presentConfirmation(
            title: urls.count == 1 ? "Delete Repository?" : "Delete \(urls.count) Repositories?",
            message: String.LocalizationValue(
                String(localized: "Packages from deleted repositories will no longer be listed. This cannot be undone.")
                    + (names.isEmpty ? "" : "\n\n" + names.joined(separator: "\n"))
            ),
            confirmTitle: "Delete",
            destructive: true
        ) { [weak self] in
            self?.performDelete(urls)
        }
    }

    /// The rows leave first; the engine hears about it once they are gone.
    private func performDelete(_ urls: [URL]) {
        dataSourceCache.removeAll { urls.contains($0) }
        applySnapshot(animatingDifferences: true)
        SPIndicator.present(title: String(localized: "Deleted"), preset: .done)
        Task {
            try? await Task.sleep(seconds: 0.5) // let the rows animate out
            for url in urls {
                Self.remove(url)
            }
        }
    }

    /// Drops a repository and everything cached for it. The sidebar removes
    /// through here too.
    static func remove(_ url: URL) {
        // first: the sign-in record is found through the repository, which
        // must still be registered
        VendorAccount.shared.deleteSignInRecord(for: url)
        Dog.shared.join("Repository", "user removed \(url.absoluteString)", level: .info)
        RepositoryCenter.default.deleteRepository(withUrl: url)
    }

    func refreshRepository(_ url: URL) {
        RepositoryCenter.default.dispatchUpdateOnRepository(withUrl: url)
        SPIndicator.present(title: String(localized: "Refreshing…"), preset: .done)
    }

    func share(_ url: URL, from cell: UIView?) {
        ExportFile.shareRepository(url, from: self, anchor: cell.map { PopoverAnchor($0) })
    }

    @objc
    private func refreshSelected() {
        let urls = selectedUrls
        guard !urls.isEmpty else { return }
        for url in urls {
            RepositoryCenter.default.dispatchUpdateOnRepository(withUrl: url)
        }
        NotificationCenter.default.post(name: .RepositoryQueueChanged, object: nil)
        setEditing(false, animated: true)
        SPIndicator.present(title: String(localized: "Refreshing…"), preset: .done)
    }

    // MARK: - ACTIONS

    /// Refresh on top; the list itself (select, import, export) in the
    /// middle; the one destructive action alone at the bottom.
    private var moreMenu: UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Refresh"),
                    image: UIImage(systemName: "arrow.clockwise")
                ) { [weak self] _ in self?.refreshAll() },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Select"),
                    image: UIImage(systemName: "checkmark.circle")
                ) { [weak self] _ in self?.setEditing(true, animated: true) },
                UIAction(
                    title: String(localized: "Import Repository List…"),
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { [weak self] _ in self?.openImport() },
                UIAction(
                    title: String(localized: "Export Repository List"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in self?.exportList() },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Remove Broken Repositories"),
                    image: UIImage(systemName: "wand.and.rays"),
                    attributes: .destructive
                ) { [weak self] _ in self?.clean() },
            ]),
        ])
    }

    // MARK: - EXPORT

    /// Every registered repository as one `.irisinrepos`.
    private func exportList() {
        ExportFile.shareRepositoryList(from: self)
    }

    // MARK: - IMPORT

    /// Only our own files: a repository list, or one repository whole.
    private func openImport() {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.irisinRepositoryList, .irisinRepository],
            asCopy: true
        )
        picker.delegate = self
        present(picker, animated: true)
    }

    /// The file's addresses become the add sheet's candidates: the user
    /// picks, one row at a time or all of them, and sees what each one is
    /// before it joins the list.
    func importRepositories(from file: URL) {
        guard let data = try? Data(contentsOf: file),
              let sources = try? RepositoryListFile.sources(in: data)
        else {
            presentNotice(title: "Unable to Import", message: "This file could not be read. Choose another file.")
            return
        }
        let registered = Set(RepositoryCenter.default.obtainRepositoryUrls())
        let fresh = sources.filter { !registered.contains($0.url) }
        guard !fresh.isEmpty else {
            presentNotice(
                title: "Nothing to Import",
                message: "This file has no new repositories to add."
            )
            return
        }
        present(RepositoryAddController.sheet(candidates: fresh, origin: .file), animated: true)
    }

    @objc
    func openAdd() {
        present(RepositoryAddController.sheet(), animated: true)
    }

    /// Pulling forces every repository and the control spins until the
    /// queue has drained.
    @objc
    private func refresh() {
        RepositoryCenter.default.dispatchForceUpdateRequestOnAll()
        NotificationCenter.default.post(name: .RepositoryQueueChanged, object: nil)
        lastUpdateTouched = Date()
        settleRefreshControl()
    }

    /// The Repositories tab tapped again over its own list: every
    /// repository is forced, as pulling the list does.
    func refreshFromTab() {
        refresh()
    }

    private func settleRefreshControl() {
        guard refreshControl.isRefreshing, RepositoryCenter.default.obtainUpdateRemain() == 0 else { return }
        refreshControl.endRefreshing()
    }

    /// Smart update; asking again within two seconds forces every repository.
    private func refreshAll() {
        if let date = lastUpdateTouched, abs(date.timeIntervalSinceNow) < 2 {
            RepositoryCenter.default.dispatchForceUpdateRequestOnAll()
            NotificationCenter.default.post(name: .RepositoryQueueChanged, object: nil)
        } else if RepositoryCenter.default.dispatchSmartUpdateRequestOnAll() {
            NotificationCenter.default.post(name: .RepositoryQueueChanged, object: nil)
        } else {
            SPIndicator.present(
                title: String(localized: "No update required"),
                message: String(localized: "Tap again to refresh all."),
                preset: .done,
                from: .top,
                completion: nil
            )
        }
        lastUpdateTouched = Date()
    }

    private func clean() {
        let broken = RepositoryCenter.default.brokenRepositoryUrls()
            .compactMap { RepositoryCenter.default.obtainImmutableRepository(withUrl: $0)?.nickName }
            .sorted { $0.lowercased() < $1.lowercased() }
        guard !broken.isEmpty else {
            SPIndicator.present(title: String(localized: "No broken repositories"), preset: .done)
            return
        }
        presentConfirmation(
            title: "Remove Broken Repositories?",
            message: String.LocalizationValue(
                String(localized: "Repositories that could not be loaded will be removed. This cannot be undone.")
                    + "\n\n" + broken.joined(separator: "\n")
            ),
            confirmTitle: "Remove All",
            destructive: true
        ) {
            RepositoryCenter
                .default
                .cleanBrokenRepos()
            SPIndicator.present(
                title: String(localized: "Broken repositories removed"),
                message: "",
                preset: .done,
                from: .top,
                completion: nil
            )
        }
    }
}

extension RepositoriesController: UIDocumentPickerDelegate {
    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let file = urls.first else { return }
        importRepositories(from: file)
    }
}
