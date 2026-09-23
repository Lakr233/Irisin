//
//  PackageVersionPickerController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/20.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import OrderedCollections
import UIKit

/// The choose-version sheet: an optional local-selection header, then every
/// version of the package on offer, one section per repository. A repository
/// row is checked only when its repository and version match the page. A tap
/// hands the chosen package to `onPick` and closes the sheet; the caller
/// decides where it goes.
class PackageVersionPickerController: UITableViewController {
    private nonisolated enum Section: Hashable, Sendable {
        case localSelectionNotice
        case repository(URL)
    }

    let current: Package

    /// The versions on offer, one section per repository, in the order of
    /// the repositories' names.
    let available: OrderedDictionary<URL, [Package]>

    var onPick: ((Package) -> Void)?

    private lazy var dataSource = EditableTableDiffableDataSource<Section, Package>(
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
        dataSource.headerTitle = { section in
            switch section {
            case .localSelectionNotice:
                String(localized: "Current Selection: Local Version")
            case let .repository(url):
                RepositoryCenter.default.obtainImmutableRepository(withUrl: url)?.nickName
            }
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Package>()
        if current.repoRef == nil {
            snapshot.appendSections([.localSelectionNotice])
        }
        for (url, packages) in available {
            let section = Section.repository(url)
            snapshot.appendSections([section])
            snapshot.appendItems(packages.uniqued(), toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The same version from the same place as the page shows. Compared by
    /// repository and version, not by value: the repository may have
    /// re-described the package since the page was opened. A dpkg record or
    /// local `.deb` names no repository, so no offered version is current.
    private func isCurrent(_ package: Package) -> Bool {
        guard let currentRepository = current.repoRef else { return false }
        return package.repoRef == currentRepository && package.latestVersion == current.latestVersion
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let package = dataSource.itemIdentifier(for: indexPath) else { return }
        dismiss(animated: true)
        onPick?(package)
    }
}
