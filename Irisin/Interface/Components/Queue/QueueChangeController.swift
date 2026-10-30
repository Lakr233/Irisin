//
//  QueueChangeController.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/17.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import Combine
import SPIndicator
import UIKit

/// What a tap does to the queue, as a diff, before it does it. Every request
/// comes up here, the first one too, and so does a package leaving the
/// queue: a section per kind of change, what was asked for ahead of the
/// dependencies it brings, each row a `QueueChange` with its version at the
/// trailing edge. A removal that leaves dependencies nobody needs lists them
/// below as boxes to tick, none ticked. The sheet solves on its own, again
/// on every tick and whenever the queue or the packages move, and Confirm
/// takes exactly what it shows; when that is nothing, Open Queue takes its
/// place. While the repositories refresh the sheet keeps the catalogue it
/// was solved with, and Confirm holds the answer against the one there is:
/// a package no longer offered as it was asks to check again, in an alert
/// the user may cancel. A request the solver refuses shows none of
/// this: `PackageDiagnosticController` is the sheet, with Close in place of
/// a way back. A refusal that comes later, from a tick or a queue that
/// moved, is pushed over the last answer, which is still there to go back to.
/// Update All that held updates back for packages only another repository
/// than their own offers names them under Needs Another Repository, each
/// with the move, and Migrate and Update pushes the update with them moved.
final class QueueChangeController: UIViewController, UITableViewDelegate {
    enum Request {
        case actions([ResolutionAction])
        case updateAll
        /// Update All with the packages that need another repository moved
        /// there (`PackageQueue.Migration`).
        case migrate
        /// The package leaves the queue, with whatever it came with.
        case withdraw(String)
    }

    nonisolated enum Section: Hashable {
        case changes(QueueChange.Kind, dependencies: Bool)
        case cleanup, dropped
        /// Update All's packages that need another repository, and the
        /// row that moves them.
        case migration
        /// The footer that closes the sheet. The text is the identity, so a
        /// new text is a new section and the table asks for it again.
        case note(String)
    }

    nonisolated enum Row: Hashable {
        case change(QueueChange)
        case dropped(QueueChange)
        /// An unneeded package; its box follows `ticked`.
        case cleanup(String)
        case unchanged
        /// A package Update All needs from another repository.
        case move(QueueChange)
        /// Migrate and Update.
        case migrate
    }

    private let request: Request
    private var proposal: PackageQueue.Proposal?
    private var failure: ResolutionFailure?
    /// The unneeded packages the user ticked; nil until the first answer,
    /// which starts from the queue's own.
    private var ticked: Set<String>?
    /// The last plan's unneeded list, kept while the next one is solved so
    /// the rows stay where they are.
    private var unneeded: [String: [String]] = [:]
    /// What Update All offers to move, while the sheet shows Update All.
    private var migration: PackageQueue.Migration?
    /// The packages this sheet's plan moves to another repository: a
    /// change row says so.
    private var moves: [String: (package: Package, origin: URL)] = [:]
    private var work: Task<Void, Never>?
    /// Confirm was tapped and the answer is being held against the
    /// packages as they are now.
    private var confirming: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private lazy var icons = PackageIconCache { [weak self] in self?.redraw() }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private lazy var confirmButton = UIBarButtonItem(
        primaryAction: UIAction(title: String(localized: "Confirm")) { [weak self] _ in self?.commit() }
    )
    /// Stands in for Confirm when the request leaves the queue as it is:
    /// there is nothing to confirm, and the queue is where the user was going.
    private lazy var openQueueButton = UIBarButtonItem(
        primaryAction: UIAction(title: String(localized: "Open Queue")) { [weak self] _ in
            guard let self else { return }
            InterfaceHostController.enclosing(self)?.openQueue()
        }
    )
    private let spinner = UIActivityIndicatorView(style: .medium)

    private lazy var dataSource: EditableTableDiffableDataSource<Section, Row> = .init(
        tableView: tableView
    ) { [unowned self] table, indexPath, row in
        let cell = table.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.contentConfiguration = content(for: row)
        cell.selectionStyle = switch row {
        case let .cleanup(name): blockers(of: name).isEmpty ? .default : .none
        case .migrate: .default
        default: .none
        }
        // a cleanup row's tick is an icon in its own content and nothing
        // else says it: the trait carries it, and a blocked row says that
        // it cannot be ticked at all
        cell.accessibilityTraits = switch row {
        case let .cleanup(name) where !blockers(of: name).isEmpty: .notEnabled
        case let .cleanup(name): (ticked ?? []).contains(name) ? [.button, .selected] : .button
        case .migrate: .button
        default: .staticText
        }
        cell.accessoryView = versionLabel(for: row, reusing: cell.accessoryView as? UILabel)
        return cell
    }

    /// Set around a swipe's action (`PackageMenu.swipeConfiguration`): the
    /// row the user swiped is all they saw, so an answer that changes the
    /// queue by that package alone joins it without the sheet, and one
    /// that brings anything along still shows it (`takeIfPlain`).
    @TaskLocal static var takesPlainChanges = false

    /// Presents the sheet, after waiting a moment for the solver so a quick
    /// answer lands with it. A request that cannot be met has no changes to
    /// show: its report is the sheet, and closing the report closes it.
    /// Under `takesPlainChanges` the wait is longer, since an answer that
    /// needs no sheet shows none.
    static func show(_ request: Request, from host: UIViewController) async {
        let controller = QueueChangeController(request: request)
        if takesPlainChanges {
            await controller.prepare(within: 1)
            if await controller.takeIfPlain() { return }
        } else {
            await controller.prepare(within: 0.2)
        }
        let root = controller.failure.map {
            report(of: $0, alone: true, recoveryPackage: controller.recoveryPackage, recoveryRemoval: controller.recoveryRemoval)
        } ?? controller
        host.present(UINavigationController.halfSheet(root: root), animated: true)
    }

    /// `alone` when the report is all the sheet holds, and so closes it.
    private static func report(
        of failure: ResolutionFailure,
        alone: Bool,
        recoveryPackage: Package? = nil,
        recoveryRemoval: String? = nil
    ) -> UIViewController {
        // the page reads the report as it opens: this failure, and only it
        PackageActionReport.shared.clear()
        PackageActionReport.shared.record(failure.message, checks: failure.checks)
        return PackageDiagnosticController(
            closesSheet: alone,
            recoveryPackage: recoveryPackage,
            recoveryRemoval: recoveryRemoval
        )
    }

    /// Recovery Mode is for one archive the user already has, never a
    /// repository candidate or a mixed queue whose consequences are unclear.
    private var recoveryPackage: Package? {
        guard case let .actions(actions) = request,
              actions.count == 1,
              case let .install(package) = actions[0],
              package.localFileURL != nil,
              package.isSupportedOnDevice
        else { return nil }
        return package
    }

    /// A failed single-package removal can offer recovery removal for that
    /// installed package. The helper rechecks protection when it executes.
    private var recoveryRemoval: String? {
        guard case let .actions(actions) = request, actions.count == 1,
              case let .remove(identity) = actions[0],
              let installed = PackageCenter.default.obtainPackageInstallationInfo(with: identity)?.representObject
        else { return nil }
        let fields = installed.latestMetadata ?? [:]
        guard fields["status"]?.hasPrefix("hold ") != true else { return nil }
        let protected = fields["essential"] == "yes" || fields["protected"] == "yes"
            || ["apt", "dpkg", "essential", "firmware", "bash", "coreutils",
                "base", "base-files", "base-passwd", "libroot", "roothide"].contains(installed.identity)
        guard PackageQueue.shared.allowSystemRemoval || !protected else { return nil }
        return installed.identity
    }

    init(request: Request) {
        self.request = request
        super.init(nibName: nil, bundle: nil)
        solve()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func prepare(within budget: TimeInterval) async {
        await work?.wait(upTo: budget)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.backgroundColor = .groupedBackground
        tableView.register(ListContentCell.self, forCellReuseIdentifier: "row")
        tableView.delegate = self
        tableView.dataSource = dataSource
        dataSource.defaultRowAnimation = .fade
        dataSource.headerTitle = { section in
            switch section {
            case let .changes(kind, dependencies): kind.title(dependencies: dependencies)
            case .cleanup: String(localized: "No Longer Needed")
            case .dropped: String(localized: "No Longer Queued")
            case .migration: String(localized: "Needs Another Repository")
            case .note: nil
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .cleanup:
                String(localized: "These were installed as dependencies and nothing needs them now. Tick one to remove it with the queue.")
            case .migration:
                String(localized: "Held-back updates need these packages from a repository other than the one each was installed from. Migrate and Update installs them from there, and their updates come from there afterwards.")
            case let .note(text):
                text.isEmpty ? nil : text
            case .changes, .dropped:
                nil
            }
        }
        view.addSubview(tableView)
        view.addSubview(spinner)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        spinner.snp.makeConstraints { x in
            x.center.equalTo(tableView)
        }
        spinner.hidesWhenStopped = true

        // no Cancel: the sheet is pulled down to leave
        title = String(localized: "Queue Changes")
        if #available(iOS 26.0, *) {
            confirmButton.style = .prominent
            openQueueButton.style = .prominent
        }

        // the queue or the packages moved: what the sheet shows is solved again
        NotificationCenter.default.publisher(for: .PackageQueueChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.solve() }
            .store(in: &subscriptions)

        render(animated: false)
    }

    // MARK: - Solving

    private func solve() {
        work?.cancel()
        let request = request
        let ticked = ticked
        work = Task { [weak self] in
            let (result, offer): (Result<PackageQueue.Proposal, ResolutionFailure>, PackageQueue.Migration?) = switch request {
            case let .actions(actions):
                await (PackageQueue.shared.propose(actions, cleanup: ticked), nil)
            case .updateAll, .migrate:
                await Self.proposeUpdate(for: request, cleanup: ticked)
            case let .withdraw(identity):
                await (PackageQueue.shared.proposeWithdrawal(of: identity, cleanup: ticked), nil)
            }
            guard !Task.isCancelled, let self else { return }
            work = nil
            if case .migrate = request {
                moves = offer?.moves ?? [:]
            } else {
                migration = offer
            }
            switch result {
            case let .success(proposal):
                // the refusal did not last, a refresh caught mid-solve: its
                // report leaves as the red line it replaced used to
                if failure != nil, navigationController?.topViewController !== self {
                    navigationController?.popToViewController(self, animated: true)
                }
                self.proposal = proposal
                failure = nil
                self.ticked = proposal.cleanup
                unneeded = proposal.plan?.unneeded ?? [:]
            case let .failure(failure):
                self.failure = failure
                guard let proposal else {
                    // no answer was ever shown: the report takes the sheet over
                    subscriptions.removeAll()
                    navigationController?.setViewControllers(
                        [Self.report(of: failure, alone: true, recoveryPackage: recoveryPackage, recoveryRemoval: recoveryRemoval)],
                        animated: true
                    )
                    return
                }
                // a tick or a queue that moved: the report goes on top, and
                // the way back is the last answer with its own ticks
                self.ticked = proposal.cleanup
                if navigationController?.topViewController === self {
                    navigationController?.pushViewController(
                        Self.report(of: failure, alone: false),
                        animated: true
                    )
                }
            }
            if isViewLoaded {
                render(animated: view.shouldAnimateDiff)
            }
        }
        if isViewLoaded {
            render(animated: view.shouldAnimateDiff)
        }
    }

    /// Update All's answer as a proposal, and the migration it offers:
    /// the update as it is, or for `.migrate` the update with the moves,
    /// which a migration no longer needed leaves as it is.
    private static func proposeUpdate(
        for request: Request,
        cleanup: Set<String>?
    ) async -> (Result<PackageQueue.Proposal, ResolutionFailure>, PackageQueue.Migration?) {
        let update: PackageQueue.UpdateAll
        switch await PackageQueue.shared.updateAllActions() {
        case let .success(found): update = found
        case let .failure(failure): return (.failure(failure), nil)
        }
        var actions = update.actions
        var notices = update.notices
        if case .migrate = request, let migration = update.migration {
            actions = migration.actions
            notices.append(String(localized: "The packages that change repository are installed from the new one, and their updates come from there afterwards."))
        }
        let proposal = await PackageQueue.shared.propose(actions, cleanup: cleanup, keepingQueued: true, notices: notices)
        return (proposal, update.migration)
    }

    private func toggle(_ name: String) {
        var ticked = ticked ?? []
        if !ticked.insert(name).inserted {
            ticked.remove(name)
        }
        // a package still needed by one left unticked cannot go, and
        // unticking one keeps what it needs
        self.ticked = ResolutionPlan.removable(ticked, unneeded: unneeded)
        solve()
    }

    /// Ticked packages a package still needs, unticked.
    private func blockers(of name: String) -> [String] {
        unneeded[name, default: []].filter { !(ticked ?? []).contains($0) }
    }

    private func commit() {
        guard confirming == nil else { return }
        if let work {
            // a tick is still being solved: Confirm takes its answer
            Task { [weak self] in
                await work.value
                self?.commit()
            }
            return
        }
        guard let proposal else { return }
        // solved against the catalogue as it was: a refresh may have
        // written it since
        confirming = Task { [weak self] in
            let currency = await PackageQueue.shared.currency(of: proposal)
            guard let self else { return }
            confirming = nil
            // a tick or a queue that moved during the check: Confirm takes
            // what the sheet shows now
            guard work == nil, self.proposal?.plan?.id == proposal.plan?.id,
                  self.proposal?.cleanup == proposal.cleanup
            else {
                return commit()
            }
            switch currency {
            case .current:
                take(proposal)
            case .moved:
                solve()
            case let .withdrawn(packages):
                let names = ListFormatter.localizedString(byJoining: packages.map(name(of:)))
                presentConfirmation(
                    title: "Repositories Changed",
                    message: "While you reviewed this change, a refresh updated or removed these packages: \(names). Check the change again before you confirm.",
                    confirmTitle: "Check Again"
                ) { [weak self] in
                    PackageQueue.shared.readCatalogue()
                    self?.solve()
                }
            }
        }
    }

    /// Takes the answer without the sheet when there is nothing in it to
    /// read or decide: the queue changes by the requested package alone, no
    /// notice, no unneeded package to tick, and the catalogue it was solved
    /// with is still the one there is. Everything else, a solve
    /// still running included, is the sheet's, which `show` presents.
    private func takeIfPlain() async -> Bool {
        guard work == nil, failure == nil, let proposal, proposal.notices.isEmpty else { return false }
        let (changes, dropped) = diff
        let plain = switch request {
        case let .actions(actions):
            dropped.isEmpty && changes.count == 1
                && Set(actions.map(\.identity)) == [changes[0].package.identity]
        case let .withdraw(identity):
            changes.isEmpty && dropped.map(\.package.identity) == [identity]
        case .updateAll, .migrate:
            false
        }
        guard plain else { return false }
        if proposal.plan?.remove.isEmpty == false, !unneeded.isEmpty {
            return false
        }
        switch await PackageQueue.shared.currency(of: proposal) {
        case .current:
            guard PackageQueue.shared.commit(proposal) else {
                solve()
                return false
            }
            announce()
            return true
        case .moved:
            solve()
            return false
        case .withdrawn:
            // Confirm asks to check again, in the sheet
            return false
        }
    }

    /// The proposal becomes the queue, and the sheet leaves.
    private func take(_ proposal: PackageQueue.Proposal) {
        guard PackageQueue.shared.commit(proposal) else {
            // the queue moved under the sheet; its notification solves again
            return solve()
        }
        // the commit's own notification is not a reason to solve again
        subscriptions.removeAll()
        dismiss(animated: true)
        announce()
    }

    /// What the queue was just told, at the top of the screen.
    private func announce() {
        let withdrawn = if case .withdraw = request {
            true
        } else {
            false
        }
        SPIndicator.present(
            title: withdrawn ? String(localized: "Removed from Queue") : String(localized: "Added to Queue"),
            message: nil,
            preset: .done,
            haptic: .success,
            from: .top,
            completion: nil
        )
    }

    // MARK: - Content

    /// The queue's plan against the proposal's, entries that differ.
    private var diff: (changes: [QueueChange], dropped: [QueueChange]) {
        guard let proposal else { return ([], []) }
        let manager = PackageQueue.shared
        let before = QueueChange.changes(of: manager.plan, requested: Set(manager.actions.map(\.identity)))
        let after = QueueChange.changes(of: proposal.plan, requested: Set(proposal.actions.map(\.identity)))
        let order: (QueueChange, QueueChange) -> Bool = {
            ($0.kind.rawValue, self.name(of: $0.package)) < ($1.kind.rawValue, self.name(of: $1.package))
        }
        return (
            after.values.filter { before[$0.package.identity] != $0 }.sorted(by: order),
            before.filter { after[$0.key] == nil }.map(\.value).sorted(by: order)
        )
    }

    private func name(of package: Package) -> String {
        PackageCenter.default.name(of: package)
    }

    private func render(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let (changes, dropped) = diff
        if let proposal {
            for group in QueueChange.sections(of: changes) {
                let section = Section.changes(group.kind, dependencies: group.dependencies)
                snapshot.appendSections([section])
                snapshot.appendItems(group.changes.map(Row.change), toSection: section)
            }
            // unneeded dependencies are offered when the queue removes something
            if proposal.plan?.remove.isEmpty == false, !unneeded.isEmpty {
                snapshot.appendSections([.cleanup])
                snapshot.appendItems(unneeded.keys.sorted().map(Row.cleanup), toSection: .cleanup)
            }
            if !dropped.isEmpty {
                snapshot.appendSections([.dropped])
                snapshot.appendItems(dropped.map(Row.dropped), toSection: .dropped)
            }
            if case .updateAll = request, let migration, !migration.moves.isEmpty {
                let installed = Dictionary(
                    PackageCenter.default.index.obtainInstalledPackageList().map { ($0.identity, $0.latestVersion) },
                    uniquingKeysWith: { a, _ in a }
                )
                let rows = migration.moves.values
                    .map { QueueChange(kind: .update, package: $0.package, current: installed[$0.package.identity] ?? nil, requested: false) }
                    .sorted { $0.name < $1.name }
                snapshot.appendSections([.migration])
                snapshot.appendItems(rows.map(Row.move) + [.migrate], toSection: .migration)
            }
            let unchanged = changes.isEmpty && dropped.isEmpty
            var lines = proposal.notices
            // an emptied queue has nothing left to install
            if !unchanged, proposal.plan != nil {
                lines.append(String(localized: "After you confirm, the queue prepares everything the install needs. Finish installing from the Queue page."))
            }
            let note = Section.note(lines.joined(separator: "\n\n"))
            snapshot.appendSections([note])
            if unchanged {
                snapshot.appendItems([.unchanged], toSection: note)
            }
        }
        snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
        dataSource.apply(snapshot, animatingDifferences: animated)

        if work == nil {
            spinner.stopAnimating()
        } else if proposal == nil {
            spinner.startAnimating()
        }
        // a solve in flight leaves the last answer on screen, and the button with it,
        // so a tick does not blink it
        let unchanged = changes.isEmpty && dropped.isEmpty
        confirmButton.isEnabled = !unchanged
        // an answer that changes nothing, with a queue to open
        let button = unchanged && proposal != nil && PackageQueue.shared.plan != nil
            ? openQueueButton
            : confirmButton
        if navigationItem.rightBarButtonItem !== button {
            navigationItem.setRightBarButton(button, animated: animated)
        }
    }

    private func content(for row: Row) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.font = .body
        content.secondaryTextProperties.font = .footnote
        content.secondaryTextProperties.color = .textSubtitle
        switch row {
        case let .change(change):
            var details = change.details(in: proposal?.plan, cleanup: proposal?.cleanup ?? [])
            if let move = moves[change.package.identity] {
                details.insert(repositoryMove(from: move.origin, to: move.package.repoRef), at: 0)
            }
            content = change.content(icon: icons.icon(of: change.package), details: details)
        case let .move(change):
            let identity = change.package.identity
            var details: [String] = []
            if let origin = migration?.moves[identity]?.origin {
                details.append(repositoryMove(from: origin, to: change.package.repoRef))
            }
            if let dependents = migration?.requiredBy[identity], !dependents.isEmpty {
                details.append(String(localized: "Required by \(ListFormatter.localizedString(byJoining: dependents))"))
            }
            content = change.content(icon: icons.icon(of: change.package), details: details)
        case .migrate:
            content = .cell()
            content.attributedText = plainTitle(String(localized: "Migrate and Update"), color: .buttonNormal)
        case let .dropped(change):
            content = change.content(icon: icons.icon(of: change.package), details: [], muted: true)
        case let .cleanup(name):
            let blockedBy = blockers(of: name)
            let package = proposal?.plan?.snapshot.installed.first { $0.identity == name }
            content.image = UIImage(systemName: (ticked ?? []).contains(name) ? "checkmark.circle.fill" : "circle")
            content.imageProperties.tintColor = blockedBy.isEmpty ? .buttonNormal : .textSubtitle
            content.attributedText = plainTitle(
                package.map(self.name(of:)) ?? name,
                color: blockedBy.isEmpty ? .textTitle : .textSubtitle
            )
            var subtitle = [package?.latestVersion ?? ""]
            if !blockedBy.isEmpty {
                let installed = proposal?.plan?.snapshot.installed ?? []
                let names = blockedBy.map { dependent in
                    installed.first { $0.identity == dependent }.map(self.name(of:)) ?? dependent
                }
                subtitle.append(String(localized: "Required by \(ListFormatter.localizedString(byJoining: names))"))
            }
            content.secondaryText = subtitle.filter { !$0.isEmpty }.joined(separator: " · ")
        case .unchanged:
            content = .cell()
            content.image = UIImage(systemName: "checkmark.circle")
            content.imageProperties.tintColor = .textSubtitle
            // nothing to add to an empty queue, or nothing to take out of
            // one, is not "already queued"
            let adding = if case .withdraw = request {
                false
            } else {
                true
            }
            content.attributedText = plainTitle(
                adding && proposal?.plan != nil
                    ? String(localized: "Already in the queue")
                    : String(localized: "No changes"),
                color: .textSubtitle
            )
        }
        return content
    }

    /// "Old Repository → New Repository", each by the name the
    /// Repositories list shows.
    private func repositoryMove(from origin: URL, to destination: URL?) -> String {
        func name(_ url: URL) -> String {
            RepositoryCenter.default.obtainImmutableRepository(withUrl: url)?.nickName ?? url.host ?? url.absoluteString
        }
        return "\(name(origin)) → \(destination.map(name) ?? "")"
    }

    /// A row's text that is not a change's. It says that it is not struck
    /// through, as a change's does: a label keeps a removal's strikethrough
    /// through any later text that does not mention one.
    private func plainTitle(_ text: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.body,
            .foregroundColor: color,
            .strikethroughStyle: 0,
        ])
    }

    /// A change row's version, at the trailing edge so the name keeps one
    /// line to itself. The row keeps its label across redraws: a new one
    /// would grow in from nothing on every tick.
    private func versionLabel(for row: Row, reusing reused: UILabel?) -> UIView? {
        switch row {
        case let .change(change), let .dropped(change), let .move(change):
            let label = reused ?? UILabel()
            label.font = .footnote.monospacedDigitFont
            label.textColor = .textSubtitle
            if label.text != change.versions {
                label.text = change.versions
                label.sizeToFit()
            }
            return label
        default:
            return nil
        }
    }

    private func redraw() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Only a cleanup row that can be toggled answers a touch. The rest are
    /// a report: a cell that never highlights cannot keep the grey ground,
    /// whatever row it is reused for.
    func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .cleanup(name): blockers(of: name).isEmpty
        case .migrate: true
        default: false
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .cleanup(name) where blockers(of: name).isEmpty:
            toggle(name)
        case .migrate:
            navigationController?.pushViewController(QueueChangeController(request: .migrate), animated: true)
        default:
            break
        }
    }
}
