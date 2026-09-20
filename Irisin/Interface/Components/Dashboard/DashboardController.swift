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

    /// The load viewDidLoad started, for whoever waits to show the page.
    private var firstLoad: Task<Void, Never>?

    var dataSource = [DashboardController.Section]()
    var reloadID = UUID()
    let refreshControl = UIRefreshControl()

    let packageCellID = UUID().uuidString
    let generalHeaderID = UUID().uuidString
    let footerID = UUID().uuidString

    var collectionViewFrameCache: CGSize?
    /// The text size the cached cell size was measured at: a row is as tall
    /// as its lines, so a change of text size has to measure it again.
    var collectionViewTextSizeCache: UIContentSizeCategory?
    var collectionViewCellSizeCache = PackageListRow.minimumSize

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
            if let view = view as? DashboardSectionHeader,
               let section = section(at: indexPath.section)
            {
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
                as! PackageCollectionCell
            // no card behind a dashboard row, so its icon starts at the cell's
            // edge, where the section title starts: PackageListRow holds it 4
            // in, for rows on a card
            cell.horizontalPadding = -4
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

    /// Lays out at the width its container gave it, so the first snapshot
    /// is cut and sized for that width, then waits for the first sections,
    /// up to `budget`, so the page appears with its rows in place; a slower
    /// load lands after it.
    func prepare(within budget: Duration) async {
        loadViewIfNeeded()
        view.layoutIfNeeded()
        await firstLoad?.wait(upTo: budget)
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
            DashboardSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: generalHeaderID
        )
        collectionView.register(
            DashboardFooterView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: footerID
        )
        collectionView.register(
            PackageCollectionCell.self,
            forCellWithReuseIdentifier: packageCellID
        )

        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.addSubview(refreshControl)

        firstLoad = Task { await reload(animated: false) }

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
