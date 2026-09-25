//
//  RepositoryDetailController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import OrderedCollections
import SPIndicator
import Then
import UIKit

/// One repository: what it says about itself, its vendor, its featured
/// packages, its sections as an inset grouped list, and where it all comes
/// from underneath. One collection view with a compositional layout draws
/// the whole page.
class RepositoryDetailController: UIViewController {
    private(set) var repo: Repository
    private var subscriptions = Set<AnyCancellable>()

    nonisolated enum Section: Hashable {
        case featured
        /// The "All" row over the description.
        case all
        /// One row per section over the counts and the last update.
        case sections
    }

    /// One row of the list: a section of the repository, or everything.
    nonisolated enum Filter: Hashable {
        case section(String)
        case all
    }

    nonisolated enum Item: Hashable {
        case banner(Int)
        case filter(Filter)
    }

    /// Section name to package count, in name order.
    private var sections: OrderedDictionary<String, Int>
    private let paymentEndpoint: URL?
    private let banners: [[String: Any]]
    /// Built once each: a banner owns a Metal view and loads its picture,
    /// and a cell that scrolls back in shows the same one.
    private var bannerViews: [Int: FeaturedBanner] = [:]

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout()).then {
        $0.backgroundColor = .clear
        $0.alwaysBounceVertical = true
        // room under the last footer, clear of the floating tab bar
        $0.contentInset.bottom = 128
        $0.delegate = self
        $0.register(RepositoryDetailHostCell.self, forCellWithReuseIdentifier: "host")
        $0.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "filter")
        for kind in [UICollectionView.elementKindSectionHeader, UICollectionView.elementKindSectionFooter] {
            $0.register(UICollectionViewListCell.self, forSupplementaryViewOfKind: kind, withReuseIdentifier: kind)
        }
    }

    private lazy var dataSource = UICollectionViewDiffableDataSource<Section, Item>(
        collectionView: collectionView
    ) { [unowned self] collectionView, indexPath, item in
        switch item {
        case let .banner(index):
            let cell = collectionView
                .dequeueReusableCell(withReuseIdentifier: "host", for: indexPath) as! RepositoryDetailHostCell
            if let banner = bannerViews[index] ?? FeaturedBanner(banner: banners[index], inside: repo) {
                bannerViews[index] = banner
                cell.host(banner)
            }
            return cell
        case let .filter(filter):
            let cell = collectionView
                .dequeueReusableCell(withReuseIdentifier: "filter", for: indexPath) as! UICollectionViewListCell
            var content = UIListContentConfiguration.valueCell()
            switch filter {
            case .all:
                content.text = String(localized: "All")
                content.secondaryText = String(repo.packageCount)
            case let .section(key):
                content.text = key.sectionDisplayName
                content.secondaryText = String(sections[key] ?? 0)
            }
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
            return cell
        }
    }.then { dataSource in
        dataSource.supplementaryViewProvider = { [unowned self] collectionView, kind, indexPath in
            let cell = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: kind,
                for: indexPath
            ) as! UICollectionViewListCell
            configure(cell, ofKind: kind, for: dataSource.sectionIdentifier(for: indexPath.section))
            return cell
        }
    }

    /// The system's grouped header or footer text for a section.
    private func configure(_ cell: UICollectionViewListCell, ofKind kind: String, for section: Section?) {
        if kind == UICollectionView.elementKindSectionHeader {
            var content = UIListContentConfiguration.groupedHeader()
            content.text = headerText(for: section)
            cell.contentConfiguration = content
        } else {
            var content = UIListContentConfiguration.groupedFooter()
            content.text = footerText(for: section)
            // the counts close the page, centred; the description reads on
            content.textProperties.alignment = section == .sections ? .center : .natural
            cell.contentConfiguration = content
        }
    }

    init(withRepo: Repository) {
        repo = withRepo

        // one column of the repository's rows, counted; the packages
        // themselves are fetched when a chip is tapped
        sections = Self.sectionCounts(in: withRepo.url)

        paymentEndpoint = withRepo.paymentInfo[.endpoint].flatMap(URL.init(string:))

        // only the banners that point at a package this repository has
        banners = FeaturedBanner.entries(in: withRepo)
            .filter { FeaturedBanner.package(for: $0, inside: withRepo) != nil }

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = repo.nickName
        // the grouped ground, so the inset list rows read as cards
        view.backgroundColor = .groupedBackground

        let share = UIBarButtonItem(image: .fluent(.shareIos24Filled), menu: shareMenu)
        share.accessibilityLabel = String(localized: "Share")
        navigationItem.rightBarButtonItems = [share]
        if paymentEndpoint != nil {
            updateAccountItem()
            NotificationCenter.default.publisher(for: .RepositoryPaymentChanged)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateAccountItem() }
                .store(in: &subscriptions)
        }

        view.addSubview(collectionView)
        collectionView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if !banners.isEmpty {
            snapshot.appendSections([.featured])
            snapshot.appendItems(banners.indices.map(Item.banner), toSection: .featured)
        }
        snapshot.appendSections([.all, .sections])
        snapshot.appendItems([.filter(.all)], toSection: .all)
        snapshot.appendItems(sectionRows, toSection: .sections)
        dataSource.apply(snapshot, animatingDifferences: false)

        // the page is opened right after an add, before the refresh lands:
        // every finished refresh of this repository redraws the counts
        NotificationCenter.default.publisher(for: RepositoryCenter.metadataUpdate)
            .compactMap { $0.object as? RepositoryCenter.UpdateNotification }
            .filter { [url = repo.url] in $0.repository == url && $0.complete }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadRepository() }
            .store(in: &subscriptions)
    }

    /// The vendor account beside Share: the purchases and sign out as a
    /// menu, or, with sign in the only thing to do, a tap that does it.
    private func updateAccountItem() {
        guard let share = navigationItem.rightBarButtonItems?.first else { return }
        let elements = VendorAccount.shared.accountMenu(for: repo) { [weak self] in self }
        let only = elements.count == 1 ? elements.first as? UIAction : nil
        let account = UIBarButtonItem(
            image: UIImage(systemName: "person.crop.circle"),
            primaryAction: only,
            menu: only == nil ? UIMenu(children: elements) : nil
        )
        account.accessibilityLabel = String(localized: "Account")
        navigationItem.rightBarButtonItems = [share, account]
    }

    private var sectionRows: [Item] {
        sections.keys.map { .filter(.section($0)) }
    }

    private static func sectionCounts(in url: URL) -> OrderedDictionary<String, Int> {
        OrderedDictionary(uniqueKeysWithValues: PackageCenter.default
            .obtainSectionCounts(in: url)
            .sorted { $0.key.lowercased() < $1.key.lowercased() })
    }

    /// Re-reads the repository and its counts and redraws the list, the
    /// header and the footer in place.
    private func reloadRepository() {
        guard let latest = RepositoryCenter.default.obtainImmutableRepository(withUrl: repo.url) else { return }
        repo = latest
        sections = Self.sectionCounts(in: latest.url)
        title = latest.nickName
        var snapshot = dataSource.snapshot()
        let previous = snapshot.itemIdentifiers(inSection: .sections)
        let current = sectionRows
        snapshot.deleteItems(previous)
        snapshot.appendItems(current, toSection: .sections)
        snapshot.reconfigureItems([.filter(.all)] + current.filter { previous.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: true)
        for kind in [UICollectionView.elementKindSectionHeader, UICollectionView.elementKindSectionFooter] {
            for case let cell as UICollectionViewListCell in collectionView.visibleSupplementaryViews(ofKind: kind) {
                let index = collectionView.indexPath(forSupplementaryView: cell)?.section
                configure(cell, ofKind: kind, for: index.flatMap(dataSource.sectionIdentifier(for:)))
            }
        }
        // a footer redrawn in place keeps its height until it is measured
        // again, and a refresh's explanation can add lines to it
        collectionView.collectionViewLayout.invalidateLayout()
    }

    // MARK: - LAYOUT

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [unowned self] index, environment in
            let section = dataSource.snapshot().sectionIdentifiers[index]
            // 20 on each side: the edge the inset grouped rows below sit on
            let inset = NSDirectionalEdgeInsets(top: 10, leading: 20, bottom: 0, trailing: 20)
            switch section {
            case .featured:
                let size = NSCollectionLayoutSize(widthDimension: .absolute(300), heightDimension: .absolute(170))
                let group = NSCollectionLayoutGroup.horizontal(
                    layoutSize: size,
                    subitems: [NSCollectionLayoutItem(layoutSize: size)]
                )
                let layout = NSCollectionLayoutSection(group: group)
                layout.orthogonalScrollingBehavior = .continuous
                layout.interGroupSpacing = 10
                layout.contentInsets = inset
                return layout
            case .all, .sections:
                // the system's inset grouped list: one full-width row per section
                var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                configuration.headerMode = .supplementary
                configuration.footerMode = .supplementary
                return NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            }
        }
    }

    // MARK: - CONTENT

    /// The row's packages in name order, from a copy of the index: a large
    /// repository is a query and a sort that do not belong on the main actor.
    @concurrent
    private nonisolated static func packages(for filter: Filter, in url: URL, index: PackageIndex) async -> [Package] {
        let list = switch filter {
        case let .section(key): index.obtainPackageList(in: url, section: key)
        case .all: index.obtainPackageList(in: url)
        }
        let center = PackageCenter.default
        return list.sorted { center.name(of: $0) < center.name(of: $1) }
    }

    /// "Packages" over "All", "Sections" over the sections; the banners
    /// carry no header.
    private func headerText(for section: Section?) -> String? {
        switch section {
        case .all: String(localized: "Packages")
        case .sections: String(localized: "Sections")
        case .featured, nil: nil
        }
    }

    /// The description under "All"; the counts and the last update under
    /// the sections.
    private func footerText(for section: Section?) -> String? {
        switch section {
        case .all:
            return repo.repositoryDescription.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "No description.")
        case .sections:
            let formatter = DateFormatter().then {
                $0.formatterBehavior = .behavior10_4
                $0.dateStyle = .medium
                $0.timeStyle = .medium
            }
            let updated = repo.lastUpdatePackage.timeIntervalSince1970 > 0
                ? formatter.string(from: repo.lastUpdatePackage)
                : String(localized: "Never")
            return ([
                String(localized: "Packages: \(repo.packageCount) · Sections: \(sections.count)"),
                String(localized: "Last updated: \(updated)"),
            ] + [refreshExplanation(formatter)].compactMap(\.self)).joined(separator: "\n")
        case .featured, nil:
            return nil
        }
    }

    /// Why the last refresh left the repository as it is, a sentence for
    /// each thing that went wrong, under the counts; nil when it went
    /// through. On an empty page too, which otherwise says only "0".
    private func refreshExplanation(_ formatter: DateFormatter) -> String? {
        guard let report = repo.refreshReport, !report.issues.isEmpty else { return nil }
        let refreshed = formatter.string(from: report.date)
        var sentences = report.issues.map { issue in
            switch issue {
            case .unreachable:
                String(localized: "The last refresh, on \(refreshed), could not reach the server.")
            case .stalled:
                String(localized: "The server stopped responding during the last refresh.")
            case let .serverError(code):
                String(localized: "The server returned an error (HTTP \(code)) during the last refresh.")
            case .releaseMissing, .releaseMalformed:
                String(
                    localized: "This repository's Release file is missing or cannot be read, so its package lists cannot be verified."
                )
            case .releaseOutdated:
                String(
                    localized: "The server returned an older Release file than the one on this device, so it was ignored."
                )
            case .indexUnverified:
                String(
                    localized: "This repository's Release file does not list its package list, so the list cannot be verified."
                )
            case .noIndex:
                String(localized: "The server has no package list for this device.")
            }
        }
        if report.didNotConnect, repo.packageCount > 0, repo.lastUpdatePackage.timeIntervalSince1970 > 0 {
            sentences.append(String(localized: "These packages are from \(formatter.string(from: repo.lastUpdatePackage))."))
        }
        return "\n" + sentences.uniqued().joined(separator: " ")
    }

    // MARK: - SHARE

    /// The address three ways (copied bare, copied as a sources.list line,
    /// shared), then the whole catalogue as a file.
    private var shareMenu: UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Copy Address"),
                    image: UIImage(systemName: "link")
                ) { [weak self] _ in self?.copy(self?.repo.url.absoluteString) },
                UIAction(
                    title: String(localized: "Copy APT Source"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { [weak self] _ in self?.copy(self?.repo.source.line) },
                UIAction(
                    title: String(localized: "Share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in self?.openShareView() },
            ]),
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Export Packages"),
                    image: UIImage(systemName: "doc.plaintext")
                ) { [weak self] _ in self?.exportPackages() },
                ExportFile.exportRepositoryAction(
                    repo.url,
                    host: { [weak self] in self },
                    anchor: { nil }
                ),
            ]),
        ])
    }

    /// Every package this repository offers, one a line.
    private func exportPackages() {
        // ponytail: a query on the main actor; a share is rare enough
        let packages = PackageCenter.default.index.obtainPackageList(in: repo.url)
        guard !packages.isEmpty else {
            presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        ExportFile.share(
            ExportFile.packageText(packages),
            named: "\(repo.url.host ?? "repository")-\(ExportFile.stamp()).txt",
            from: self
        )
    }

    private func copy(_ text: String?) {
        guard let text else { return }
        UIPasteboard.general.string = text
        SPIndicator.present(title: String(localized: "Copied"), preset: .done)
    }

    private func openShareView() {
        ExportFile.shareRepository(repo.url, from: self, anchor: nil)
    }
}

extension RepositoryDetailController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case let .filter(filter) = dataSource.itemIdentifier(for: indexPath) else { return }
        let index = PackageCenter.default.index
        let url = repo.url
        Task { [weak self] in
            let packages = await Self.packages(for: filter, in: url, index: index)
            guard let self else { return }
            guard !packages.isEmpty else {
                presentNotice(
                    title: "No Packages",
                    message: "Refresh the repository and try again."
                )
                return
            }
            if packages.count == 1 {
                present(next: PackageController(package: packages[0]))
                return
            }
            let collection = PackageCollectionController()
            collection.title = switch filter {
            case .all: repo.nickName
            case let .section(key): key.sectionDisplayName
            }
            collection.dataSource = packages
            present(next: collection)
        }
    }
}

// MARK: - CELLS

/// A cell around a view that draws and handles itself: a featured banner.
final class RepositoryDetailHostCell: UICollectionViewCell {
    /// A banner that cannot be made hosts nothing, not the last one's view.
    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.subviews.forEach { $0.removeFromSuperview() }
    }

    func host(_ view: UIView) {
        contentView.subviews.forEach { $0.removeFromSuperview() }
        contentView.addSubview(view)
        view.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }
}
