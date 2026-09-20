import AptRepository
import AptResolver
import Dog
import SnapKit
import UIKit

final class PackageDiagnosticController: UIViewController, UITableViewDelegate {
    nonisolated enum Section: Hashable {
        case report(String)
        case recovery
    }

    nonisolated enum Row: Hashable {
        case check(ResolutionCheck)
        case recoveryInstallation
        case recoveryRemoval
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!
    private var report: [ResolutionCheck] = []
    private var summary = ""
    /// A reason of the app's own, an operation still running or packages
    /// that moved, comes with no checks: the row is the reason, and no
    /// verdict goes under it.
    private var reasonOnly = false
    /// The sheet's only page has no way back, so Close takes the sheet away.
    /// Whoever builds the sheet says so: the page cannot tell from its own
    /// place in the stack while that stack is still being replaced.
    private let closesSheet: Bool
    /// One local archive that may repair a system whose relationships can no
    /// longer be solved. Nil for every ordinary diagnostic report.
    private let recoveryPackage: Package?
    private let recoveryRemoval: String?

    init(closesSheet: Bool, recoveryPackage: Package? = nil, recoveryRemoval: String? = nil) {
        self.closesSheet = closesSheet
        self.recoveryPackage = recoveryPackage
        self.recoveryRemoval = recoveryRemoval
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Unable to Prepare Installation")
        navigationItem.largeTitleDisplayMode = .never
        // the sheet's ground, whether the page is its root or pushed in it
        view.backgroundColor = .groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: .fluent(.shareIos24Filled),
            style: .plain,
            target: self,
            action: #selector(shareReport)
        )
        if closesSheet {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }

        summary = PackageActionReport.shared.allAvailable()
        report = PackageActionReport.shared.checks
        reasonOnly = report.isEmpty
        Dog.shared.join(self, "showing the diagnostic report:\n\(summary)", level: .error)
        configureTable()
        applyReport()
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 44
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "requirement")
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.top.equalTo(view.safeAreaLayoutGuide)
            x.leading.trailing.bottom.equalToSuperview()
        }
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [unowned self] table, indexPath, row in
            let cell = table.dequeueReusableCell(withIdentifier: "requirement", for: indexPath)
            guard case let .check(check) = row else {
                var content = cell.defaultContentConfiguration()
                content.text = row == .recoveryRemoval
                    ? String(localized: "Remove Using Recovery Mode")
                    : String(localized: "Install Using Recovery Mode")
                content.textProperties.font = .body
                content.textProperties.color = row == .recoveryRemoval ? .swipeDelete : .buttonNormal
                content.textProperties.numberOfLines = 0
                cell.contentConfiguration = content
                cell.backgroundColor = .cardBackground
                cell.selectionStyle = .default
                cell.accessibilityTraits = .button
                cell.accessibilityLabel = content.text
                return cell
            }
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
            let isSummary = check.package.isEmpty && check.requirement == summary
            let detail = isSummary ? "" : check.detailText
            var content = cell.defaultContentConfiguration()
            content.text = check.requirement
            content.textProperties.font = .rounded(.body, emphasized: true)
            content.textProperties.color = .textTitle
            content.textProperties.numberOfLines = 0
            content.secondaryText = detail
            content.secondaryTextProperties.font = .rounded(.subheadline)
            content.secondaryTextProperties.color = .textSubtitle
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(
                systemName: check.outcome == .matched ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            content.imageProperties.tintColor = check.outcome == .matched ? .requirementMatched : .requirementIssue
            cell.contentConfiguration = content
            cell.backgroundColor = .cardBackground
            cell.accessibilityLabel = [check.requirement, detail].filter { !$0.isEmpty }.joined(separator: ". ")
            return cell
        }
    }

    private func applyReport() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        let summaryCheck = ResolutionCheck(
            package: "",
            requirement: summary,
            outcome: .conflictingRequirements
        )
        snapshot.appendSections([.report(summaryCheck.package)])
        snapshot.appendItems([.check(summaryCheck)], toSection: .report(summaryCheck.package))
        var seen: Set<ResolutionCheck> = [summaryCheck]
        for check in report where seen.insert(check).inserted {
            if !snapshot.sectionIdentifiers.contains(.report(check.package)) {
                snapshot.appendSections([.report(check.package)])
            }
            snapshot.appendItems([.check(check)], toSection: .report(check.package))
        }
        if recoveryPackage != nil {
            snapshot.appendSections([.recovery])
            snapshot.appendItems([.recoveryInstallation], toSection: .recovery)
        } else if recoveryRemoval != nil {
            snapshot.appendSections([.recovery])
            snapshot.appendItems([.recoveryRemoval], toSection: .recovery)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard case let .report(identity) = dataSource.snapshot().sectionIdentifiers[section] else { return nil }
        let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
        header.textLabel?.text = identity.isEmpty ? String(localized: "What Happened") : identity
        header.textLabel?.font = .rounded(.subheadline, emphasized: true)
        header.textLabel?.textColor = .textTitle
        header.textLabel?.numberOfLines = 0
        return header
    }

    func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .recoveryInstallation, .recoveryRemoval: true
        default: false
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .recoveryInstallation: confirmRecoveryInstallation()
        case .recoveryRemoval: confirmRecoveryRemoval()
        default: break
        }
    }

    @objc private func shareReport() {
        let details = report.map { "\($0.package)\n\($0.requirement)\n\($0.detailText)" }.joined(separator: "\n\n")
        ShareSheet.present(
            // the reason alone is already the summary
            [reasonOnly ? summary : summary + "\n\n" + details],
            anchor: navigationItem.rightBarButtonItem.map { PopoverAnchor($0) },
            from: self
        )
    }

    private func confirmRecoveryInstallation() {
        guard recoveryPackage != nil else { return }
        presentConfirmation(
            title: "Install in Recovery Mode?",
            message: "Recovery Mode installs only this package without checking its dependencies or conflicts. Maintainer scripts such as postinst and postrm still run, but their failures are ignored so installation can continue on a best-effort basis. Use it only when the system can no longer complete a normal installation. The package may not work, and the system may become less stable.",
            confirmTitle: "Install Anyway",
            destructive: true
        ) { [weak self] in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            self?.prepareRecoveryOperation()
        }
    }

    private func confirmRecoveryRemoval() {
        guard recoveryRemoval != nil else { return }
        presentConfirmation(
            title: "Remove in Recovery Mode?",
            message: "Recovery Mode removes only this package without checking whether other packages need it. Maintainer scripts still run, but their failures are ignored. Other packages or the system may stop working.",
            confirmTitle: "Remove",
            destructive: true
        ) { [weak self] in
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            self?.prepareRecoveryOperation(removing: true)
        }
    }

    private func prepareRecoveryOperation(removing: Bool = false) {
        guard removing ? recoveryRemoval != nil : recoveryPackage != nil else { return }
        let progress = progressAlert(
            title: "Preparing…",
            message: "Checking packages…"
        )
        Task { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { ready in
                present(progress, animated: true) { ready.resume() }
            }
            let payload: TaskProcessor.OperationPayload? = if removing, let recoveryRemoval {
                await TaskProcessor.shared.createRecoveryRemovalPayload(identity: recoveryRemoval)
            } else if let recoveryPackage {
                await TaskProcessor.shared.createRecoveryOperationPayload(package: recoveryPackage)
            } else {
                nil
            }
            await progress.dismissFinishing(animated: true)
            guard let payload else {
                let report = PackageActionReport.shared.allAvailable()
                presentNotice(
                    title: "Unable to Prepare Installation",
                    message: report.isEmpty
                        ? String(localized: "Unable to prepare the installation. Try again.")
                        : report
                )
                return
            }
            let sheet = navigationController ?? self
            guard let host = sheet.presentingViewController else { return }
            let console = UINavigationController(rootViewController: OperationController(operation: payload))
            console.modalPresentationStyle = traitCollection.userInterfaceIdiom == .pad ? .formSheet : .fullScreen
            await sheet.dismissFinishing(animated: true)
            guard host.view.window != nil else { return }
            host.present(console, animated: true)
        }
    }
}
