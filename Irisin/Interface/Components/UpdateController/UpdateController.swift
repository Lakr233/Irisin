//
//  UpdateController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import UIKit

class UpdateController: UIViewController, UITableViewDelegate {
    private var subscriptions = Set<AnyCancellable>()
    private let notificationCenter: NotificationCenter
    private var reloadTask: Task<Void, Never>?

    let tableView = UITableView()
    let cellID = UUID().uuidString

    nonisolated struct Row: Hashable {
        let installed: Package
        let candidate: Package
    }

    private lazy var diffableDataSource = UITableViewDiffableDataSource<Int, Row>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, fetch in
        let cell = tableView.dequeueReusableCell(withIdentifier: cellID, for: indexPath) as! PackageUpdateTableCell
        if view.frame.width > 500 {
            cell.padding = 15
        } else {
            cell.padding = 5
        } // not horizontalPadding
        cell.loadValue(package: fetch.installed)
        cell.loadUpdateValue(package: fetch.candidate)

        // every row on this screen is a package with a candidate: `reload`
        // builds no other kind, so the indicator needs no lookup to confirm it
        cell.overrideIndicator(with: .fluent(.arrowUpCircle24Filled), and: .updateAvailable)

        return cell
    }

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .plainBackground

        tableView.separatorColor = .clear
        tableView.register(PackageUpdateTableCell.self, forCellReuseIdentifier: cellID)
        tableView.delegate = self
        tableView.dataSource = diffableDataSource
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        // the bar carries the title: `show` loads this view before the page
        // has a navigation controller, and `present(next:)` always gives it one
        title = String(localized: "Updates")

        let rightItem = UIBarButtonItem(
            title: String(localized: "Update All"),
            style: .done,
            target: self,
            action: #selector(updateAll)
        )
        navigationItem.rightBarButtonItem = rightItem

        reload()

        // Repository download ticks share one rebuild per second.
        Publishers.MergeMany([
            RepositoryCenter.metadataUpdate,
            RepositoryCenter.registrationUpdate,
            PackageCenter.packageRecordChanged,
        ].map {
            notificationCenter.publisher(for: $0)
        })
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] _ in self?.reload() }
        .store(in: &subscriptions)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // arriving, the list viewDidLoad started is still the current one
        guard !isMovingToParent, !isBeingPresented else { return }
        reload()
    }

    /// Waits for the first list, up to `budget`, so the page is pushed with
    /// its rows in place; a slower list animates in after the push.
    func prepare(within budget: Duration) async {
        loadViewIfNeeded()
        await reloadTask?.wait(upTo: budget)
    }

    /// Pushes the page from `host` once its first list is in, or 200 ms on.
    static func show(from host: UIViewController?) {
        let page = UpdateController()
        Task {
            await page.prepare(within: .milliseconds(200))
            host?.present(next: page)
        }
    }

    @objc
    func updateAll() {
        Task { await QueueChangeController.show(.updateAll, from: self) }
    }

    func reload() {
        reloadTask?.cancel()
        let index = PackageCenter.default.index
        reloadTask = Task { [weak self] in
            let rows = await Self.rows(in: index)
            guard !Task.isCancelled, let self else { return }
            var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
            snapshot.appendSections([0])
            snapshot.appendItems(rows)
            snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
            await diffableDataSource.apply(
                snapshot,
                animatingDifferences: tableView.shouldAnimateDiff
            )
            guard !Task.isCancelled else { return }
            if rows.isEmpty {
                if let navigator = navigationController {
                    navigator.popViewController(animated: true)
                } else {
                    dismiss(animated: true, completion: nil)
                }
            }
        }
    }

    /// The whole installed list, walked off the main actor.
    @concurrent
    private nonisolated static func rows(in index: PackageIndex) async -> [Row] {
        index.updateCandidates().map { Row(installed: $0.installed, candidate: $0.candidate) }.uniqued()
    }

    // a tap opens the candidate; a long press previews it with its actions,
    // the same as every other package list

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = diffableDataSource.itemIdentifier(for: indexPath) else { return }
        present(next: PackageController(package: row.candidate))
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let row = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return PackageMenu.contextMenu(
            for: row.candidate,
            from: self,
            anchor: tableView.cellForRow(at: indexPath)
        )
    }

    func tableView(
        _: UITableView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        show(preview: animator)
    }
}
