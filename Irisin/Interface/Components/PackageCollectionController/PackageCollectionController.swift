//
//  PackageCollectionController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/18.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Then
import UIKit

class PackageCollectionController: UIViewController, UICollectionViewDelegate {
    var dataSource: [Package] = [] {
        didSet {
            if isViewLoaded {
                applySnapshot()
            }
        }
    }

    let searchController = UISearchController()
    let cellId = UUID().uuidString
    let headerId = UUID().uuidString

    /// The rows are laid out in columns, where only `gridSwipe` swipes
    /// them; a single column is a list section, which swipes its own.
    private var laysOutGrid = false
    private lazy var gridSwipe = GridSwipeInteraction(collectionView: collectionView) { [weak self] in
        guard let self, laysOutGrid else { return nil }
        return swipeActions(at: $0)
    }

    /// Sections are their header text; the plain list is one untitled section.
    private(set) lazy var diffableDataSource: UICollectionViewDiffableDataSource<String, Package> = {
        let source = UICollectionViewDiffableDataSource<String, Package>(
            collectionView: collectionView
        ) { [unowned self] collectionView, indexPath, package in
            let cell = collectionView
                .dequeueReusableCell(withReuseIdentifier: cellId, for: indexPath)
                as! PackageCollectionCell
            cell.loadValue(package: package)
            return cell
        }
        source.supplementaryViewProvider = { [unowned self] collectionView, kind, indexPath in
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: headerId,
                for: indexPath
            )
            if let view = view as? PackageSectionHeaderView {
                view.horizontalPadding = 5
                view.loadText(diffableDataSource.sectionIdentifier(for: indexPath.section) ?? "")
            }
            return view
        }
        return source
    }()

    func buildSnapshot() -> NSDiffableDataSourceSnapshot<String, Package> {
        var snapshot = NSDiffableDataSourceSnapshot<String, Package>()
        snapshot.appendSections([""])
        snapshot.appendItems(dataSource.uniqued(), toSection: "")
        return snapshot
    }

    func applySnapshot() {
        var snapshot = buildSnapshot()
        // the search narrows whatever the page lists, a subclass's sections included
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if !query.isEmpty {
            snapshot.deleteItems(snapshot.itemIdentifiers.filter { package in
                !(PackageCenter.default.name(of: package).localizedStandardContains(query)
                    || PackageCenter.default.description(of: package).localizedStandardContains(query)
                    || package.identity.localizedStandardContains(query))
            })
            snapshot.deleteSections(snapshot.sectionIdentifiers.filter { snapshot.numberOfItems(inSection: $0) == 0 })
        }
        snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
        // an open swipe belongs to a cell, which the diff may move
        gridSwipe.close(animated: false)
        diffableDataSource.apply(snapshot, animatingDifferences: collectionView.shouldAnimateDiff)
        updateGuiderOpacity()
    }

    private(set) lazy var collectionView = UICollectionView(
        frame: CGRect(),
        collectionViewLayout: makeLayout()
    ).then {
        $0.backgroundColor = .clear
        // above the first row and below the last, as the flow layout had it
        $0.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
    }

    /// The rows' edge, the page's own before it was a compositional layout.
    static let horizontalInset: CGFloat = 15
    /// The gap between two rows.
    static let rowSpacing: CGFloat = 10

    /// One column is a list, whose rows swipe; a width that fits more is
    /// the grid, where a long press has the same actions. As the Installed
    /// page lays out.
    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            self?.makeSection(at: index, in: environment)
        }
    }

    private func makeSection(
        at index: Int,
        in environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width - Self.horizontalInset * 2
        let (cellSize, itemsPerRow) = PackageListRow.layout(inWidth: width)
        laysOutGrid = itemsPerRow > 1
        let section: NSCollectionLayoutSection
        if itemsPerRow < 2 {
            var list = UICollectionLayoutListConfiguration(appearance: .plain)
            list.showsSeparators = false
            list.backgroundColor = .clear
            list.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            section = .list(using: list, layoutEnvironment: environment)
        } else {
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .absolute(cellSize.width),
                heightDimension: .fractionalHeight(1)
            ))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(cellSize.height)
                ),
                subitems: [item]
            )
            // what is left of the width goes between the columns
            group.interItemSpacing = .flexible(0)
            section = NSCollectionLayoutSection(group: group)
        }
        section.interGroupSpacing = Self.rowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Self.horizontalInset,
            bottom: 0,
            trailing: Self.horizontalInset
        )
        if let title = diffableDataSource.sectionIdentifier(for: index), !title.isEmpty {
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(20)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )]
        }
        return section
    }

    /// Install or Update first, Remove last: the package menu's own
    /// actions, as every package list swipes.
    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let package = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return PackageMenu.swipeConfiguration(for: package, from: self) { [weak self] in
            self?.collectionView.cellForItem(at: indexPath).map { PopoverAnchor($0) }
        }
    }

    let emptyElementGuider = UIImageView().then {
        $0.tintColor = .placeholderGlyph
        $0.image = .init(systemName: "questionmark.circle.fill")
        $0.contentMode = .scaleAspectFit
    }

    let emptyElementLabel = UILabel().then {
        $0.text = String(localized: "No packages to show.")
        $0.font = .body
        $0.textColor = .textSubtitle
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if title?.count ?? 0 < 1 {
            title = String(localized: "Packages")
        }
        view.backgroundColor = .plainBackground

        // export is the only thing this page hands out, and there is one
        // shape to hand it out in, so the button does it rather than open a menu
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: .fluent(.shareIos24Filled),
            primaryAction: UIAction { [weak self] _ in self?.exportPackageList() }
        ).then { $0.accessibilityLabel = String(localized: "Share") }

        searchController.searchBar.placeholder = String(localized: "Search")
        searchController.searchBar.setValue(
            String(localized: "Cancel"),
            forKey: "cancelButtonText"
        )
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.searchTextField.autocapitalizationType = .none
        searchController.searchBar.searchTextField.autocorrectionType = .no
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = diffableDataSource
        _ = gridSwipe
        collectionView.delegate = self
        collectionView.register(PackageCollectionCell.self, forCellWithReuseIdentifier: cellId)
        collectionView.register(
            PackageSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: headerId
        )
        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        applySnapshot()

        view.addSubview(emptyElementGuider)
        emptyElementGuider.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.width.equalTo(80)
            x.height.equalTo(80)
        }
        view.addSubview(emptyElementLabel)
        emptyElementLabel.snp.makeConstraints { x in
            x.top.equalTo(emptyElementGuider.snp.bottom).offset(12)
            x.leading.trailing.equalToSuperview().inset(40)
        }
    }

    func updateGuiderOpacity() {
        if diffableDataSource.snapshot().numberOfItems == 0 {
            emptyElementGuider.isHidden = false
            emptyElementLabel.isHidden = false
        } else {
            emptyElementGuider.isHidden = true
            emptyElementLabel.isHidden = true
        }
    }

    /// A row is as tall as its text: a new text size is a new layout.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// What the page is showing, one package a line.
    private func exportPackageList() {
        let shown = diffableDataSource.snapshot().itemIdentifiers
        guard !shown.isEmpty else {
            presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        ExportFile.share(
            ExportFile.packageText(shown),
            named: "packages-\(ExportFile.stamp()).txt",
            from: self
        )
    }

    // didHighlightItemAt removed because we have add preview

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let data = diffableDataSource.itemIdentifier(for: indexPath) else { return }
        let target = PackageController(package: data)
        present(next: target)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let data = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return PackageMenu.contextMenu(
            for: data,
            from: self,
            anchor: collectionView.cellForItem(at: indexPath)
        )
    }

    func collectionView(
        _: UICollectionView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        show(preview: animator)
    }
}

extension PackageCollectionController: UISearchResultsUpdating {
    func updateSearchResults(for _: UISearchController) {
        applySnapshot()
    }
}
