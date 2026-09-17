//
//  RecentUpdateController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Then
import UIKit

class RecentUpdateController: PackageCollectionController {
    let formatter = DateFormatter().then {
        $0.formatterBehavior = .behavior10_4
        $0.dateStyle = .medium
        $0.timeStyle = .medium
    }

    var updateDataSource: [Date: [(String, URL?)]] = [:] {
        didSet {
            if isViewLoaded {
                applySnapshot()
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Recent Updates")
    }

    override func updateGuiderOpacity() {
        // this list has its own dated sections; nothing to show is not an error
        emptyElementGuider.isHidden = true
        emptyElementLabel.isHidden = true
    }

    override func buildSnapshot() -> NSDiffableDataSourceSnapshot<String, Package> {
        var snapshot = NSDiffableDataSourceSnapshot<String, Package>()
        var seen = Set<Package>() // a package updated twice shows once, under its newest date
        for date in updateDataSource.keys.sorted(by: >) {
            let packages = (updateDataSource[date] ?? [])
                .compactMap(resolve)
                .filter { seen.insert($0).inserted }
            guard !packages.isEmpty else { continue }
            let title = formatter.string(from: date)
            if !snapshot.sectionIdentifiers.contains(title) {
                snapshot.appendSections([title])
            }
            snapshot.appendItems(packages, toSection: title)
        }
        return snapshot
    }

    private func resolve(_ item: (String, URL?)) -> Package? {
        if let url = item.1,
           let package = PackageCenter.default.obtainPackage(with: item.0, in: url)
        {
            return package
        }
        return PackageCenter.default.newestPackage(
            of: Array(PackageCenter.default.obtainPackageSummary(with: item.0).values),
            preferring: PackageCenter.default.obtainInstallOrigin(of: item.0)?.repoRef
        )
    }
}
