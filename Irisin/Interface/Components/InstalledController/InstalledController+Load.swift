//
//  InstalledController+Load.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import UIKit

extension InstalledController {
    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(localized: "Installed")

        view.backgroundColor = .plainBackground

        setupBarItems()

        collectionView.collectionViewLayout = makeLayout()
        collectionView.dataSource = diffableDataSource
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .clear
        collectionView.allowsMultipleSelectionDuringEditing = true
        collectionView.register(InstalledPackageCell.self, forCellWithReuseIdentifier: cellId)
        collectionView.register(
            PackageSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: headerId
        )
        collectionView.register(
            ListFootnoteView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: footerId
        )

        searchController.searchBar.placeholder = String(localized: "Search installed packages")
        searchController.searchBar.setValue(
            String(localized: "Cancel"),
            forKey: "cancelButtonText"
        )
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.searchBar.delegate = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.searchTextField.autocapitalizationType = .none
        searchController.searchBar.searchTextField.autocorrectionType = .no

        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.addSubview(refreshControl)

        justReload()

        // Finished refreshes and package records share one rebuild per second.
        Publishers.MergeMany([
            RepositoryCenter.metadataUpdate,
            RepositoryCenter.registrationUpdate,
            PackageCenter.packageRecordChanged,
        ].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .filter { !$0.isRepositoryProgress }
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in self?.justReload() }
        .store(in: &subscriptions)
    }
}
