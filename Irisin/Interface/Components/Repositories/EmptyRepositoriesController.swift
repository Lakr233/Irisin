//
//  EmptyRepositoriesController.swift
//  Irisin
//

import AptRepository
import SPIndicator
import UIKit

/// The repositories that offer no packages, listed to be deleted together:
/// every row starts checked, and one unchecked stays. A repository in the
/// refresh queue is not listed; its packages may be on their way.
class EmptyRepositoriesController: UITableViewController {
    private nonisolated enum Section: Hashable {
        case repositories
    }

    /// The repositories the sheet would list now, by name.
    static func emptyRepositories() -> [URL] {
        let center = RepositoryCenter.default
        return center.obtainRepositoryUrls(sortedByName: true)
            .filter { center.refreshHealth(withUrl: $0) == .failed }
            .uniqued()
    }

    /// The sheet, which says so when there is nothing to list.
    static func present(from host: UIViewController) {
        host.present(UINavigationController.halfSheet(root: EmptyRepositoriesController(urls: emptyRepositories())), animated: true)
    }

    private let urls: [URL]

    private lazy var deleteButton = UIBarButtonItem(
        title: String(localized: "Delete"),
        primaryAction: UIAction { [weak self] _ in self?.confirmDelete() }
    )

    private lazy var dataSource = EditableTableDiffableDataSource<Section, URL>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, url in
        let cell = tableView.dequeueReusableCell(withIdentifier: "repository", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        let repo = RepositoryCenter.default.obtainImmutableRepository(withUrl: url)
        content.text = repo?.nickName ?? url.absoluteString
        content.secondaryText = url.absoluteString
        content.secondaryTextProperties.color = .textSubtitle
        content.image = icon(of: url, data: repo?.avatar ?? Data())
        content.imageProperties.maximumSize = CGSize(width: 33, height: 33)
        content.imageProperties.cornerRadius = 8
        cell.contentConfiguration = content
        // the checkmark says a row is chosen; the row keeps its ground
        cell.backgroundConfiguration = .listGroupedCell()
        cell.automaticallyUpdatesBackgroundConfiguration = false
        return cell
    }

    init(urls: [URL]) {
        self.urls = urls
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(localized: "Empty Repositories")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        deleteButton.tintColor = .swipeDelete
        navigationItem.rightBarButtonItem = deleteButton

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "repository")
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)
        tableView.dataSource = dataSource
        dataSource.footerTitle = { _ in
            String(localized: "These repositories had no packages at their last refresh. The address may be wrong, or the server may be down.")
        }

        // nothing to list: no section, so no footer, and the line in its place
        var snapshot = NSDiffableDataSourceSnapshot<Section, URL>()
        if urls.isEmpty {
            tableView.backgroundView = EmptyStateView(
                icon: .bookCompass24Regular,
                text: String(localized: "Every repository offers packages.")
            )
        } else {
            snapshot.appendSections([.repositories])
            snapshot.appendItems(urls)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        for url in urls {
            if let indexPath = dataSource.indexPath(for: url) {
                tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
            }
        }
        updateDeleteButton()
    }

    override func tableView(_: UITableView, didSelectRowAt _: IndexPath) {
        updateDeleteButton()
    }

    override func tableView(_: UITableView, didDeselectRowAt _: IndexPath) {
        updateDeleteButton()
    }

    private var selectedUrls: [URL] {
        (tableView.indexPathsForSelectedRows ?? [])
            .sorted()
            .compactMap { dataSource.itemIdentifier(for: $0) }
    }

    private func updateDeleteButton() {
        deleteButton.isEnabled = !selectedUrls.isEmpty
    }

    /// The avatar where it has been made; the stand-in until then, with the
    /// row drawn again once it arrives.
    private func icon(of url: URL, data: Data) -> UIImage {
        let fallback = UIImage.fluent(.bookCompass24Filled)
        guard !data.isEmpty else { return fallback }
        if let cached = RepositoryAvatar.cached(for: url, data: data) {
            return cached ?? fallback
        }
        Task { [weak self] in
            _ = await RepositoryAvatar.icon(for: url, data: data)
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            guard snapshot.indexOfItem(url) != nil else { return }
            // a reconfigure keeps the row, and its checkmark with it
            snapshot.reconfigureItems([url])
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
        return fallback
    }

    private func confirmDelete() {
        let urls = selectedUrls
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
            urls.forEach(RepositoriesController.remove)
            SPIndicator.present(title: String(localized: "Deleted"), preset: .done)
            self?.dismiss(animated: true)
        }
    }
}
