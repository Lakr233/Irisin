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

class PackageCollectionController: UIViewController, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout {
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
    var collectionViewCellSizeCache = PackageListRow.minimumSize

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
        diffableDataSource.apply(snapshot, animatingDifferences: collectionView.shouldAnimateDiff)
        updateGuiderOpacity()
    }

    let collectionView: UICollectionView = {
        let flowLayout = UICollectionViewFlowLayout()
        flowLayout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        flowLayout.scrollDirection = UICollectionView.ScrollDirection.vertical
        flowLayout.minimumInteritemSpacing = 0.0
        let view = UICollectionView(frame: CGRect(), collectionViewLayout: flowLayout)
        view.backgroundColor = .clear
        return view
    }()

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

        updateCellSize()
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

    /// Before the collection view lays out, never after it: a size that
    /// arrives a turn late leaves a frame of `PackageListRow.minimumSize` cells.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateCellSize()
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

    func updateCellSize() {
        let inset: CGFloat = 15
        collectionView.contentInset = UIEdgeInsets(top: 10, left: inset, bottom: 10, right: inset)
        let size = PackageListRow
            // we are not inside UICollectionViewController
            // so don't use collectionView.contentSize
            // otherwise it will load all of the cells when boot
            .layout(inWidth: view.frame.width - inset * 2).size
        // asked on every layout pass; only a new size is worth a new layout
        guard size != collectionViewCellSizeCache else { return }
        collectionViewCellSizeCache = size
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func collectionView(_: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt _: IndexPath) -> CGSize {
        collectionViewCellSizeCache
    }

    func collectionView(
        _: UICollectionView,
        layout _: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard let title = diffableDataSource.sectionIdentifier(for: section), !title.isEmpty else { return .zero }
        return CGSize(width: 300, height: 20)
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
