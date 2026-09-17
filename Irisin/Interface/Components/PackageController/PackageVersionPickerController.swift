//
//  PackageVersionPickerController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/20.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Collections
import UIKit

/// The choose-version sheet: every version of the package on offer, one
/// section per repository. The checkmark is on the version the page shows,
/// so a pick is checked the next time the sheet opens. A tap hands the chosen
/// package to `onPick` and closes the sheet; the caller decides where it goes.
class PackageVersionPickerController: UITableViewController {
    let current: Package

    /// The versions on offer, one section per repository, in the order of
    /// the repositories' names.
    let available: OrderedDictionary<URL, [Package]>

    var onPick: ((Package) -> Void)?

    private lazy var dataSource = EditableTableDiffableDataSource<URL, Package>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, package in
        let cell = tableView.dequeueReusableCell(withIdentifier: "version", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = package.latestVersion ?? String(localized: "Unknown")
        cell.contentConfiguration = content
        cell.accessoryType = isCurrent(package) ? .checkmark : .none
        return cell
    }

    /// The sheet the callers present: Cancel over the list, half height on
    /// the iPhone until the list needs more.
    static func sheet(package: Package, onPick: @escaping (Package) -> Void) -> UINavigationController {
        let controller = PackageVersionPickerController(package: package)
        controller.onPick = onPick
        return .halfSheet(root: controller)
    }

    init(package: Package) {
        current = package
        let center = PackageCenter.default
        let summary = center.obtainPackageSummary(with: package.identity)
        let byName = summary.keys
            .map { ($0, RepositoryCenter.default.obtainImmutableRepository(withUrl: $0)?.nickName ?? "") }
            .sorted { $0.1 < $1.1 }
        available = OrderedDictionary(uniqueKeysWithValues: byName.map { url, _ in
            (url, center.versionTrimmedSingleSubPackages(of: summary[url]!))
        })
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(localized: "Choose Version")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "version")
        tableView.dataSource = dataSource
        dataSource.headerTitle = { url in
            RepositoryCenter.default.obtainImmutableRepository(withUrl: url)?.nickName
        }

        var snapshot = NSDiffableDataSourceSnapshot<URL, Package>()
        for (url, packages) in available {
            snapshot.appendSections([url])
            snapshot.appendItems(packages.uniqued(), toSection: url)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The same version from the same place as the page shows. Compared by
    /// repository and version, not by value: the repository may have
    /// re-described the package since the page was opened. A page opened
    /// from dpkg's row names no repository, so there the version decides.
    private func isCurrent(_ package: Package) -> Bool {
        guard package.latestVersion == current.latestVersion else { return false }
        return current.repoRef == nil || package.repoRef == current.repoRef
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let package = dataSource.itemIdentifier(for: indexPath) else { return }
        dismiss(animated: true)
        onPick?(package)
    }
}
