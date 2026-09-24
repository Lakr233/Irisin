//
//  QueueController.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import Combine
import Dog
import UIKit

/// The queue's plan, from the sheet that filled it to the operation console.
/// The list reads like the change sheet: a card per kind of change, the
/// requests ahead of their dependencies, and a download fills its row from
/// the leading edge. The files download from the moment the queue takes a change,
/// whether or not this page is open; the page only watches. Execute is the one
/// thing the user does: tapped at any time, it stages the transaction and
/// hands it to the console as soon as every file is here. A queue with a
/// package built for another bootstrap shows Patch in its place first: the
/// tap adapts those packages once their files are here, an alert says what
/// solving again took out of the queue or brought in, and the button is
/// Execute from then on. The bar says no more than the button does: a
/// spinner while the page works on its own, Retry after a failure whose
/// reason heads the list.
final class QueueController: UIViewController, UITableViewDelegate {
    nonisolated enum Section: Hashable {
        /// Why the last attempt stopped, at the top where it is seen
        /// without scrolling.
        case failure
        case changes(QueueChange.Kind, dependencies: Bool)
        /// The notices, as the footer that closes the list. The text is the
        /// identity, so a new text is a new section and the table asks for
        /// it again.
        case notices(String)
    }

    nonisolated enum Row: Hashable {
        case change(QueueChange)
        case failure(String)
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let listUpdates = WindowedListUpdates()
    private lazy var icons = PackageIconCache { [weak self] in self?.redraw() }
    private let emptyState = EmptyStateView(text: String(localized: "No packages in the queue"))
    private let executeButton = UIBarButtonItem()
    private let busyItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = String(localized: "Operation in Progress")
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    /// Export is built as the menu opens: it needs every file the queue
    /// installs to be here, and that changes under an open page.
    private lazy var menuItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self.map { [$0.exportAction()] } ?? [])
            },
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Clear Queue"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { _ in PackageQueue.shared.clear() },
            ]),
        ])
    )

    private var subscriptions = Set<AnyCancellable>()
    /// The poll that follows the downloads, while the page is on screen or
    /// a tap is waiting for them.
    private var watch: Task<Void, Never>?
    private var staging: Task<Void, Never>?
    private var patching: Task<Void, Never>?
    /// What Patch did to the queue, until the alert that says so is up: the
    /// page may be covered or off screen when Patch finishes.
    private var patchOutcome: PackageQueue.PatchOutcome?
    /// A tapped row whose page is not pushed yet; a second tap waits for it.
    private var opening: Task<Void, Never>?
    /// Patch or Execute was tapped while files were still downloading: it
    /// runs the moment they are here.
    private var committed = false {
        didSet { updateBar() }
    }
    private var bootstrapRequested = false

    /// The plan the page last showed, to tell a new one from a redraw.
    private var shownPlan: ResolutionPlan?
    private var failure: String?

    /// Where the queue stands, for the button to know what its tap means.
    private enum Stage {
        case empty, blocked, downloading, ready, patching, staging
        /// Retry runs the downloads again.
        case downloadFailed
        /// Patch tries again; the files are here.
        case patchFailed
        /// Retry stages again; the files are here.
        case stagingFailed
    }

    private var stage = Stage.empty {
        didSet { updateBar() }
    }

    private lazy var dataSource: EditableTableDiffableDataSource<Section, Row> = .init(
        tableView: tableView
    ) { [unowned self] (table: UITableView, indexPath: IndexPath, row: Row) -> UITableViewCell in
        switch row {
        case let .change(change):
            let cell = table.dequeueReusableCell(withIdentifier: "package", for: indexPath) as! QueuePackageCell
            let manager = PackageQueue.shared
            cell.apply(
                change.content(
                    icon: icons.icon(of: change.package),
                    details: [change.versions] + change.details(in: manager.plan, cleanup: manager.cleanup)
                ),
                download: change.kind != .remove && change.package.localFileURL == nil ? change.package : nil,
                opens: change.isInspectable
            )
            return cell
        case let .failure(text):
            let cell = table.dequeueReusableCell(withIdentifier: "failure", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.font = .footnote
            content.textProperties.color = .operationFailed
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .operationFailed
            cell.contentConfiguration = content
            return cell
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Queue")
        navigationItem.largeTitleDisplayMode = .always

        tableView.backgroundColor = .groupedBackground
        tableView.register(QueuePackageCell.self, forCellReuseIdentifier: "package")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "failure")
        tableView.delegate = self
        tableView.dataSource = dataSource
        dataSource.defaultRowAnimation = .fade
        dataSource.headerTitle = { section in
            guard case let .changes(kind, dependencies) = section else { return nil }
            return kind.title(dependencies: dependencies)
        }
        dataSource.footerTitle = { section in
            guard case let .notices(text) = section else { return nil }
            return text
        }
        view.addSubview(tableView)
        view.addSubview(emptyState)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        emptyState.snp.makeConstraints { x in
            x.edges.equalTo(view.safeAreaLayoutGuide)
        }

        // the title is the bar's to set: Patch, Execute or Retry
        executeButton.primaryAction = UIAction { [weak self] _ in self?.primaryAction() }
        executeButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self, let plan = PackageQueue.shared.plan,
                      Self.canBootstrapInstall(plan), PackageQueue.shared.unpatched.isEmpty
                else { return completion([]) }
                completion([UIAction(
                    title: String(localized: "Bootstrap Install"),
                    image: UIImage(systemName: "shippingbox")
                ) { [weak self] _ in self?.primaryAction(bootstrapInstall: true) }])
            },
        ])
        if #available(iOS 26.0, *) {
            executeButton.style = .prominent
        }
        menuItem.accessibilityLabel = String(localized: "More")
        navigationItem.rightBarButtonItems = [executeButton, busyItem, menuItem]
        updateBar()

        NotificationCenter.default.publisher(for: .PackageQueueChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &subscriptions)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        reload()
        listUpdates.applyPending()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentPatchOutcome()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // the downloads go on without the page; only a committed Execute
        // keeps watching them
        if !committed {
            watch?.cancel()
            watch = nil
        }
    }

    // MARK: - Content

    /// The queue as it is now: the rows, then what the downloads are doing.
    private func reload() {
        guard isViewLoaded else { return }
        let manager = PackageQueue.shared
        let plan = manager.plan
        if plan?.id != shownPlan?.id {
            committed = false
            bootstrapRequested = false
            shownPlan = plan
            failure = nil
        }
        emptyState.isHidden = plan != nil
        listUpdates.apply("rows", to: tableView, animated: view.shouldAnimateDiff) { [weak self] animated in
            self?.applyRows(animated: animated)
        }

        guard let plan else {
            stage = .empty
            watch?.cancel()
            watch = nil
            return
        }
        if manager.blocked != nil {
            stage = .blocked
            watch?.cancel()
            watch = nil
            return
        }
        // patching and staging run to their end, and a failure stays until
        // Retry or a new plan
        let failed = stage == .downloadFailed || stage == .patchFailed || stage == .stagingFailed
        if stage == .patching || stage == .staging || (failure != nil && failed) {
            return
        }
        follow(plan)
    }

    /// The rows of the queue as it is when this runs: the reason the last
    /// attempt stopped, a card per kind of change, then the notices.
    private func applyRows(animated: Bool) {
        let manager = PackageQueue.shared
        let plan = manager.plan
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let changes = QueueChange.changes(of: plan, requested: Set(manager.actions.map(\.identity)))
        if let reason = manager.blocked ?? failure {
            snapshot.appendSections([.failure])
            snapshot.appendItems([.failure(reason)], toSection: .failure)
        }
        for group in QueueChange.sections(of: changes.values) {
            let section = Section.changes(group.kind, dependencies: group.dependencies)
            snapshot.appendSections([section])
            snapshot.appendItems(group.changes.map(Row.change), toSection: section)
        }
        // the sections already count the packages; only what they cannot say
        if plan != nil, !manager.notices.isEmpty {
            snapshot.appendSections([.notices(manager.notices.uniqued().joined(separator: "\n\n"))])
        }
        snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// Patch while a package of the plan is still to be adapted and Execute
    /// once none is, a spinner in its place while the page works on its own,
    /// and Retry after a failure.
    private func updateBar() {
        let queued = PackageQueue.shared.plan != nil
        let busy = stage == .patching || stage == .staging || (stage == .downloading && committed)
        // a failed patch keeps Patch: the tap is the same one again
        let retries = stage == .downloadFailed || stage == .stagingFailed
        executeButton.title = if retries {
            String(localized: "Retry")
        } else if PackageQueue.shared.unpatched.isEmpty {
            String(localized: "Execute")
        } else {
            String(localized: "Patch")
        }
        executeButton.isEnabled = stage != .blocked
        executeButton.isHidden = !queued || busy
        busyItem.isHidden = !queued || !busy
        // the queue is not cleared from under a patch
        menuItem.isHidden = !queued || stage == .patching
    }

    // MARK: - Export

    /// Every package file the queue installs, to the share sheet. Grey with
    /// the reason under it while a file is missing or nothing is installed.
    private func exportAction() -> UIAction {
        let installs = PackageQueue.shared.plan?.install ?? []
        let files = installs.compactMap { package in package.fileOnDisk.map { (package, $0) } }
        let action = UIAction(
            title: String(localized: "Export All Packages"),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in self?.export(files) }
        if installs.isEmpty {
            action.attributes = .disabled
            action.subtitle = String(localized: "The queue installs nothing.")
        } else if files.count < installs.count {
            action.attributes = .disabled
            action.subtitle = String(localized: "Available once the downloads finish.")
        }
        return action
    }

    private func export(_ files: [(Package, URL)]) {
        Task { [weak self] in
            let copies = await Self.namedCopies(of: files)
            guard let self else { return }
            guard let copies else {
                // the copies took a while; the queue may have left by now
                ShareSheet.presentableController(for: self)?.presentNotice(
                    title: "Unable to Export",
                    message: "The file could not be written. Try again."
                )
                return
            }
            ShareSheet.present(copies, anchor: PopoverAnchor(menuItem), from: self)
        }
    }

    @concurrent
    private nonisolated static func namedCopies(of files: [(Package, URL)]) async -> [URL]? {
        try? files.map { try DownloadArchiveController.namedCopy(of: $1, for: $0) }
    }

    /// How many packages the queue touches.
    static var queuedCount: Int {
        (PackageQueue.shared.plan).map { $0.install.count + $0.remove.count } ?? 0
    }

    /// `queuedCount` for a tab or a card; nil when none.
    static var badge: String? {
        let count = queuedCount
        return count > 0 ? String(count) : nil
    }

    private func redraw() {
        listUpdates.apply("icons", to: tableView, animated: false) { [weak self] _ in
            guard let self else { return }
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    private func refreshVisibleProgress() {
        for cell in tableView.visibleCells {
            (cell as? QueuePackageCell)?.refreshProgress(animated: true)
        }
    }

    /// A row whose package can be read opens its page: the files the change
    /// touches and the scripts it runs. The read starts with the tap and the
    /// page waits a moment for it, so a quick one arrives with the page.
    /// Execute never waits for any of this.
    func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard case let .change(change) = dataSource.itemIdentifier(for: indexPath) else { return false }
        return change.isInspectable && opening == nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .change(change) = dataSource.itemIdentifier(for: indexPath),
              change.isInspectable, opening == nil
        else { return }
        let page = QueuePackageController(change: change)
        opening = Task { [weak self] in
            await page.prepare(within: .milliseconds(200))
            guard let self else { return }
            opening = nil
            // the page was left while the package was read
            guard view.window != nil, navigationController?.topViewController === self else { return }
            present(next: page)
        }
    }

    /// Every package leaves the queue with a swipe, through the change
    /// sheet: a dependency takes the requests that need it along.
    func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard case let .change(change) = dataSource.itemIdentifier(for: indexPath),
              !Installer.shared.inProcessingQueue, stage != .patching
        else { return nil }
        let action = UIContextualAction(
            style: .normal,
            title: String(localized: "Remove from Queue")
        ) { [weak self] _, _, completion in
            completion(true)
            guard let self else { return }
            Task { await QueueChangeController.show(.withdraw(change.package.identity), from: self) }
        }
        action.backgroundColor = .swipeDelete
        return UISwipeActionsConfiguration(actions: [action])
    }

    // MARK: - Download, patch and execute

    /// Patch or Execute: Retry repeats what failed, otherwise the tap
    /// commits the plan, now if every file is here and as soon as they are
    /// if not.
    private static func canBootstrapInstall(_ plan: ResolutionPlan) -> Bool {
        let installing = Set(plan.install.map(\.identity))
        let installed = Set(plan.snapshot.installed.map(\.identity))
        let configuring = Set(plan.stages.flatMap { stage -> [String] in
            if case let .configure(names) = stage { return names }
            return []
        })
        return !installing.isEmpty && plan.remove.isEmpty && !plan.recoveryMode
            && installing.isDisjoint(with: installed) && configuring.isSubset(of: installing)
    }

    private func primaryAction(bootstrapInstall: Bool = false) {
        guard let plan = PackageQueue.shared.plan else { return }
        bootstrapRequested = bootstrapInstall
        switch stage {
        case .downloadFailed:
            failure = nil
            Downloads.shared.download(plan.install)
            reload()
        case .patchFailed, .stagingFailed, .ready:
            run(plan)
        case .downloading:
            committed = true
        case .empty, .blocked, .patching, .staging:
            break
        }
    }

    /// What the button said when it was tapped, every file being here.
    private func run(_ plan: ResolutionPlan) {
        if PackageQueue.shared.unpatched.isEmpty {
            stageAndRun(plan, bootstrapInstall: bootstrapRequested)
        } else {
            patch()
        }
    }

    /// Follows the plan's missing files; each row follows its own.
    private func follow(_ plan: ResolutionPlan) {
        // one watch per plan: an earlier one waking later would stage again
        watch?.cancel()
        watch = nil
        let pending = plan.install.filter { $0.localFileURL == nil }
        guard !pending.isEmpty else {
            stage = .ready
            return
        }
        stage = .downloading
        refreshVisibleProgress()
        watch = Task { [weak self] in
            let failure = await Self.awaitDownloads(of: pending, in: plan.id) { [weak self] in
                self?.refreshVisibleProgress()
            }
            // a plan that replaced this one has a watch of its own
            guard !Task.isCancelled, let self, PackageQueue.shared.plan?.id == plan.id else { return }
            watch = nil
            refreshVisibleProgress()
            if let failure {
                Dog.shared.join("Queue", "download failed: \(failure)", level: .error)
                let purchased = pending.contains { $0.latestMetadata?["tag"]?.contains("cydia::commercial") ?? false }
                self.failure = purchased
                    ? failure + "\n" + String(localized: "A purchased package's download link expires. Remove it from the queue and add it again.")
                    : failure
                committed = false
                stage = .downloadFailed
                reload()
                return
            }
            if committed {
                run(plan)
            } else {
                stage = .ready
            }
        }
    }

    /// Adapts what the plan installs for another bootstrap and solves again
    /// with what the files showed. The button is Execute after this; a
    /// queue that is not what it was says so first.
    private func patch() {
        failure = nil
        committed = false
        stage = .patching
        patching = Task { [weak self] in
            let result = await PackageQueue.shared.patch()
            guard let self else { return }
            patching = nil
            switch result {
            case let .success(outcome):
                stage = .empty
                reload()
                if !(outcome.left.isEmpty && outcome.joined.isEmpty) {
                    patchOutcome = outcome
                    presentPatchOutcome()
                }
            case let .failure(reason):
                failure = reason.message
                // a file that is gone is downloaded again, not patched again
                stage = reason.missingDownload ? .downloadFailed : .patchFailed
                reload()
            }
        }
    }

    /// The alert for a queue Patch changed, now if the page is on screen
    /// with nothing over it, otherwise when it next appears.
    private func presentPatchOutcome() {
        guard let outcome = patchOutcome, view.window != nil, presentedViewController == nil else { return }
        patchOutcome = nil
        func names(_ packages: [Package]) -> String {
            ListFormatter.localizedString(byJoining: packages.map {
                PackageCenter.default.name(of: $0)
            })
        }
        var lines: [String] = []
        if !outcome.left.isEmpty {
            lines.append(String(localized: "Removed from the queue: \(names(outcome.left))."))
        }
        if !outcome.joined.isEmpty {
            lines.append(String(localized: "Added to the queue: \(names(outcome.joined))."))
        }
        lines.append(String(localized: "Review the queue before you execute."))
        presentNotice(title: "Queue Changed", message: lines.joined(separator: "\n\n"))
    }

    private func stageAndRun(_ plan: ResolutionPlan, bootstrapInstall: Bool) {
        failure = nil
        guard !Installer.shared.inProcessingQueue else {
            return stagingFailed(
                String(localized: "Another operation is already running. Wait for it to finish, then try again.")
            )
        }
        stage = .staging
        staging = Task { [weak self] in
            let payload = await Installer.shared.createOperationPayload(
                plan: plan,
                bootstrapInstall: bootstrapInstall
            )
            guard let self else { return }
            staging = nil
            // a page left while staging ran has nothing to present on
            guard view.window != nil else {
                stage = .empty
                return reload()
            }
            guard let payload, !payload.transaction.stages.isEmpty else {
                // staging said why in the report when it could
                let report = PackageActionReport.shared.allAvailable()
                stagingFailed(report.isEmpty ? String(localized: "Unable to prepare this operation. Try again.") : report)
                // a reason that asked to be an alert is one as well as the row
                if let title = PackageActionReport.shared.alertTitle {
                    presentNotice(title: String.LocalizationValue(title), message: report)
                }
                return
            }
            showConsole(payload)
        }
    }

    private func stagingFailed(_ reason: String) {
        committed = false
        failure = reason
        stage = .stagingFailed
        reload()
    }

    /// The sheet takes the system's form sheet size and no content size of
    /// its own: the iPad adds the navigation bar to a content size, the
    /// operation page has a large title and the log and the failed
    /// package's page have none, so the sheet would shrink on every push.
    private func showConsole(_ payload: Installer.OperationPayload) {
        let console = UINavigationController(rootViewController: OperationController(operation: payload))
        console.modalPresentationStyle = traitCollection.userInterfaceIdiom == .pad ? .formSheet : .fullScreen
        committed = false
        stage = .empty
        present(console, animated: true)
    }

    /// Waits until every one of these packages is on disk, or answers the
    /// first download's failure. Stops when `plan` is no longer the queue's.
    private static func awaitDownloads(
        of packages: [Package],
        in plan: UUID,
        progress: @MainActor () -> Void
    ) async -> String? {
        let downloads = Downloads.shared
        // ponytail: polls the statuses four times a second; a publisher on
        // the statuses if the tick ever shows
        while !Task.isCancelled, PackageQueue.shared.plan?.id == plan {
            let statuses = packages.map { (package: $0, status: downloads.status(for: $0.obtainDownloadLink())) }
            // a retry's download keeps the old error until it first reports
            if let failed = statuses.first(where: {
                $0.status?.errorDescription != nil && !downloads.isDownloading($0.package.obtainDownloadLink())
            })?.status?.errorDescription {
                return failed
            }
            if statuses.allSatisfy({ $0.status?.file != nil }) {
                return nil
            }
            // the queue starts every download it needs; one that is neither
            // done nor running was stopped from outside
            if statuses.contains(where: { $0.status?.file == nil && !downloads.isDownloading($0.package.obtainDownloadLink()) }) {
                return String(localized: "The download was interrupted.")
            }
            progress()
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }
}
