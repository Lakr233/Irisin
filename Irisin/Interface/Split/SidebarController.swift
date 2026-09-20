//
//  SidebarController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import SnapKit
import SPIndicator
import Then
import UIKit

/// The iPad sidebar: the four feature cards, then the repositories as an
/// inset grouped list. Adding is in the navigation bar; pulling the list
/// refreshes every repository, and one is refreshed from its own row.
class SidebarController: UIViewController {
    private nonisolated enum Section: Hashable {
        case features
        case repositories
    }

    private nonisolated enum Item: Hashable {
        case features
        case header
        case repository(URL)
        /// The hint that stands in for a list with no repositories.
        case none
    }

    private var subscriptions = Set<AnyCancellable>()

    let cards = SidebarCards()

    private let refreshControl = SettlingRefreshControl()

    /// The repositories are an inset grouped list. The cards are not a list
    /// row, whose group corners would clip theirs, but take the list's margins.
    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: UICollectionViewCompositionalLayout { [weak self] section, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            configuration.backgroundColor = .panelBackground
            if section == 0 {
                // the insets of a plain list: a footer would shrink the gap below
                let list = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(210))
                let cards = NSCollectionLayoutSection(
                    group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
                )
                cards.contentInsetsReference = list.contentInsetsReference
                cards.contentInsets = list.contentInsets
                cards.contentInsets.top = 0
                return cards
            }
            configuration.headerMode = .firstItemInSection
            configuration.footerMode = .supplementary
            configuration.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.leadingSwipeActions(at: indexPath)
            }
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.trailingSwipeActions(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
        }
    )

    private lazy var dataSource: UICollectionViewDiffableDataSource<Section, Item> = {
        let features = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [unowned self] cell, _, _ in
            guard cards.superview !== cell.contentView else { return }
            cell.contentView.addSubview(cards)
            cards.snp.remakeConstraints { x in
                x.edges.equalToSuperview()
                x.height.equalTo(210).priority(999)
            }
        }
        let header = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [unowned self] cell, _, _ in
            configureHeader(cell)
        }
        let row = UICollectionView.CellRegistration<RepoListCell, Item> { cell, _, item in
            cell.updateFill.url = nil
            if case let .repository(url) = item {
                cell.row.setRepository(withUrl: url)
                cell.updateFill.url = url
            } else {
                cell.row.setNoRepoAvailable()
            }
        }
        let footer = UICollectionView.SupplementaryRegistration<ListFootnoteView>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [unowned self] view, _, _ in
            view.label.text = RepositoriesController.footnote
            footnote = view
        }
        let source = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collection, indexPath, item in
            switch item {
            case .features: collection.dequeueConfiguredReusableCell(using: features, for: indexPath, item: item)
            case .header: collection.dequeueConfiguredReusableCell(using: header, for: indexPath, item: item)
            case .repository, .none: collection.dequeueConfiguredReusableCell(using: row, for: indexPath, item: item)
            }
        }
        // only the repositories are a list, so only they have a footer
        source.supplementaryViewProvider = { collection, _, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        return source
    }()

    /// The footer on screen: it is not a row, so a snapshot never retitles it.
    private weak var footnote: ListFootnoteView?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = .panelBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                self?.present(RepositoryAddController.sheet(), animated: true)
            }
        ).then { $0.accessibilityLabel = String(localized: "Add Repository") }

        refreshControl.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refreshControl
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.features, .repositories])
        snapshot.appendItems([.features], toSection: .features)
        dataSource.apply(snapshot, animatingDifferences: false)
        rebuild(animated: false)

        // a refresh changes the package count in the footer
        Publishers.MergeMany([RepositoryCenter.registrationUpdate, RepositoryCenter.metadataUpdate].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in self?.rebuild(animated: true) }
        .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: RepositoryCenter.metadataUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.settleRefreshControl() }
            .store(in: &subscriptions)
    }

    // MARK: - Rows

    private var hasListedRepositories = false

    /// A collapsed section stays collapsed across a rebuild. The rows that
    /// stay repaint themselves: `RepositoryRow` listens for its own repository.
    private func rebuild(animated: Bool) {
        // Before the repositories are read there is no list to show, and
        // "No repositories" would be a guess; the first list arrives whole.
        guard RepositoryCenter.default.isLoaded else { return }
        let animated = animated && hasListedRepositories
        hasListedRepositories = true
        let urls = RepositoryCenter.default.obtainRepositoryUrls(sortedByName: true).uniqued()
        let previous = dataSource.snapshot(for: .repositories)
        var outline = NSDiffableDataSourceSectionSnapshot<Item>()
        outline.append([.header])
        outline.append(urls.isEmpty ? [.none] : urls.map(Item.repository), to: .header)
        if !previous.contains(.header) || previous.isExpanded(.header) {
            outline.expand([.header])
        }
        dataSource.apply(outline, to: .repositories, animatingDifferences: animated)
        if let indexPath = dataSource.indexPath(for: .header),
           let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell
        {
            configureHeader(cell)
        }
        footnote?.label.text = RepositoriesController.footnote
    }

    private func configureHeader(_ cell: UICollectionViewListCell) {
        var content = UIListContentConfiguration.sidebarHeader()
        content.text = String(localized: "Repositories")
        cell.contentConfiguration = content
        cell.accessories = [
            .label(text: String(RepositoryCenter.default.obtainRepositoryCount())),
            .outlineDisclosure(options: .init(style: .header)),
        ]
    }

    // MARK: - Actions

    /// Where a repository opens: the detail column, never this one.
    private var detailNavigator: UINavigationController? {
        (splitViewController as? SplitInterfaceController)?.navigator
    }

    /// The spinner stays until the last repository has finished.
    private func refresh() {
        RepositoryCenter.default.dispatchForceUpdateRequestOnAll()
        NotificationCenter.default.post(name: .RepositoryQueueChanged, object: nil)
        settleRefreshControl()
    }

    private func settleRefreshControl() {
        guard refreshControl.isRefreshing, RepositoryCenter.default.obtainUpdateRemain() == 0 else { return }
        refreshControl.endRefreshing()
    }

    private func url(at indexPath: IndexPath) -> URL? {
        guard case let .repository(url) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return url
    }

    private func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let url = url(at: indexPath) else { return nil }
        let deleteItem = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
            // the swipe's own transaction has to end for the row to settle
            completion(true)
            let name = RepositoryCenter.default.obtainImmutableRepository(withUrl: url)?.nickName ?? url.absoluteString
            self?.presentConfirmation(
                title: "Delete Repository?",
                message: String.LocalizationValue(
                    String(localized: "Its packages will no longer be listed. This cannot be undone.") + "\n\n" + name
                ),
                confirmTitle: "Delete",
                destructive: true
            ) { [weak self] in
                RepositoriesController.remove(url)
                self?.rebuild(animated: true)
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done)
            }
        }
        // the column is narrow: icons, so the row stays legible beside them
        deleteItem.image = UIImage(systemName: "trash")
        deleteItem.accessibilityLabel = String(localized: "Delete")
        deleteItem.backgroundColor = .swipeDelete
        let reloadItem = UIContextualAction(style: .normal, title: nil) { _, _, completion in
            completion(true)
            RepositoryCenter.default.dispatchUpdateOnRepository(withUrl: url)
            SPIndicator.present(title: String(localized: "Refreshing…"), preset: .done)
        }
        reloadItem.image = UIImage(systemName: "arrow.clockwise")
        reloadItem.accessibilityLabel = String(localized: "Refresh")
        reloadItem.backgroundColor = .swipeRefresh
        return UISwipeActionsConfiguration(actions: [reloadItem, deleteItem])
    }

    private func cellAnchor(at indexPath: IndexPath) -> PopoverAnchor? {
        collectionView.cellForItem(at: indexPath).map { PopoverAnchor($0) }
    }

    private func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let url = url(at: indexPath) else { return nil }
        let shareItem = UIContextualAction(style: .normal, title: String(localized: "Share")) { [weak self] _, _, completion in
            completion(true)
            guard let self else { return }
            ExportFile.shareRepository(url, from: self, anchor: cellAnchor(at: indexPath))
        }
        shareItem.backgroundColor = .swipeShare
        return UISwipeActionsConfiguration(actions: [shareItem])
    }

    /// Refresh and Delete are the swipe's; the two that hand out a file are
    /// here, where the list on the iPhone keeps them too.
    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let url = url(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in
                    guard let self else { return }
                    ExportFile.shareRepository(url, from: self, anchor: cellAnchor(at: indexPath))
                },
                ExportFile.exportRepositoryAction(
                    url,
                    host: { self },
                    anchor: { self?.cellAnchor(at: indexPath) }
                ),
            ])
        }
    }
}

extension SidebarController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshControl.listDidScroll(scrollView)
    }

    /// The cards take their own touches and the placeholder row is not a row.
    func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .header, .repository: true
        default: false
        }
    }

    func collectionView(_: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        url(at: indexPath) != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let url = url(at: indexPath),
              let repo = RepositoryCenter.default.obtainImmutableRepository(withUrl: url),
              let navigator = detailNavigator,
              (navigator.topViewController as? RepositoryDetailController)?.repo.url != url
        else { return }
        navigator.pushViewController(RepositoryDetailController(withRepo: repo), animated: true)
    }
}

/// `RepositoryRow` as a list row, tinted rather than filled while it is pressed.
/// The update's progress is part of the background, so it keeps the
/// card's rounded corners.
private final class RepoListCell: UICollectionViewListCell {
    let row = RepositoryRow()
    let updateFill = RepositoryUpdateFill()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(row)
        row.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
        }
        separatorLayoutGuide.snp.makeConstraints { x in
            x.leading.equalTo(row.title)
        }
        // the focus ring is a rectangle around a card's rounded row
        focusEffect = nil
        configurationUpdateHandler = { [updateFill] cell, state in
            var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
            background.customView = updateFill
            background.backgroundColorTransformer = nil
            background.backgroundColor = state.isHighlighted || state.isSelected || state.isFocused
                ? .buttonNormal.withAlphaComponent(0.1)
                : .cardBackground
            cell.backgroundConfiguration = background
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
