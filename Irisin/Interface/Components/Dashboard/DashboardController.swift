//
//  DashboardController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/10.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import UIKit

class DashboardController: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    private var subscriptions = Set<AnyCancellable>()

    var dataSource = [InterfaceBridge.DashboardDataSection]()
    var reloadID = UUID()
    let refreshControl = UIRefreshControl()

    let packageCellID = UUID().uuidString
    let generalHeaderID = UUID().uuidString
    let footerID = UUID().uuidString

    var collectionViewFrameCache: CGSize?
    /// The text size the cached cell size was measured at: a row is as tall
    /// as its lines, so a change of text size has to measure it again.
    var collectionViewTextSizeCache: UIContentSizeCategory?
    var collectionViewCellSizeCache = CGSize()

    var cellLimit = 16

    /// A package can sit in more than one section; the row is scoped to its section.
    nonisolated enum Item: Hashable {
        case package(section: String, Package)
    }

    private(set) lazy var diffableDataSource: UICollectionViewDiffableDataSource<String, Item> = {
        let source = UICollectionViewDiffableDataSource<String, Item>(
            collectionView: collectionView
        ) { [unowned self] collectionView, indexPath, item in
            configureCell(collectionView, at: indexPath, for: item)
        }
        source.supplementaryViewProvider = { [unowned self] collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionFooter {
                return collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: footerID,
                    for: indexPath
                )
            }
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: generalHeaderID,
                for: indexPath
            )
            if let view = view as? LXDashboardSupplementHeaderCell,
               let section = section(at: indexPath.section)
            {
                view.prepareNewValue()
                view.loadSection(data: section)
                view.currentSection = { [weak self, title = section.title] in
                    self?.dataSource.first { $0.title == title }
                }
                view.overrideButtonAction = section.action
            }
            return view
        }
        return source
    }()

    let emptyStateLabel = EmptyStateView()

    func configureCell(
        _ collectionView: UICollectionView,
        at indexPath: IndexPath,
        for item: Item
    ) -> UICollectionViewCell {
        switch item {
        case let .package(_, package):
            let cell = collectionView
                .dequeueReusableCell(withReuseIdentifier: packageCellID, for: indexPath)
                as! DashboardPackageCell
            cell.prepareForNewValue()
            cell.loadValue(package: package)
            return cell
        }
    }

    init() {
        let flowLayout = UICollectionViewFlowLayout()
        flowLayout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        flowLayout.scrollDirection = UICollectionView.ScrollDirection.vertical
        flowLayout.minimumInteritemSpacing = 0.0
        super.init(collectionViewLayout: flowLayout)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        collectionView.clipsToBounds = false
        collectionView.contentInset = UIEdgeInsets(top: 10, left: 20, bottom: 50, right: 20)
        collectionView.dataSource = diffableDataSource
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.register(
            LXDashboardSupplementHeaderCell.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: generalHeaderID
        )
        collectionView.register(
            DashboardFooterView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: footerID
        )
        collectionView.register(
            DashboardPackageCell.self,
            forCellWithReuseIdentifier: packageCellID
        )

        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.addSubview(refreshControl)

        Task { await reload(animated: false) }

        // Repository download ticks share one rebuild per second.
        Publishers.MergeMany([
            RepositoryCenter.metadataUpdate,
            RepositoryCenter.registrationUpdate,
            PackageCenter.packageRecordChanged,
        ].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in
            Task { await self?.reload(animated: true) }
        }
        .store(in: &subscriptions)
    }
}

/// A package on the dashboard: no card behind it, so its icon starts at the
/// cell's edge, where the section title above it starts.
private final class DashboardPackageCell: PackageCollectionCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        // PackageCell holds its icon 4 in from the edge, for rows on a card
        horizontalPadding = -4
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
