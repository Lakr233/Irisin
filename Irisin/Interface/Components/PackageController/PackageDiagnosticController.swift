import AptRepository
import AptResolver
import Dog
import UIKit

final class PackageDiagnosticController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var dataSource: UITableViewDiffableDataSource<String, ResolutionCheck>!
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
    private let recoveryFooter = UIView()
    private lazy var recoveryButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAttributedTitle(
            NSAttributedString(
                string: String(localized: "Install Using Recovery Mode"),
                attributes: [
                    .font: UIFont.footnote,
                    .foregroundColor: UIColor.buttonNormal,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ]
            ),
            for: .normal
        )
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.addAction(UIAction { [weak self] _ in self?.confirmRecoveryInstallation() }, for: .touchUpInside)
        return button
    }()

    init(closesSheet: Bool, recoveryPackage: Package? = nil) {
        self.closesSheet = closesSheet
        self.recoveryPackage = recoveryPackage
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
        tableView.allowsSelection = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "requirement")
        view.addSubview(tableView)
        let tableBottom: NSLayoutYAxisAnchor
        if recoveryPackage != nil {
            configureRecoveryFooter()
            tableBottom = recoveryFooter.topAnchor
        } else {
            tableBottom = view.bottomAnchor
        }
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: tableBottom),
        ])
        dataSource = UITableViewDiffableDataSource(tableView: tableView) { [unowned self] table, indexPath, check in
            let cell = table.dequeueReusableCell(withIdentifier: "requirement", for: indexPath)
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

    private func configureRecoveryFooter() {
        recoveryFooter.translatesAutoresizingMaskIntoConstraints = false
        recoveryFooter.backgroundColor = .groupedBackground
        view.addSubview(recoveryFooter)
        recoveryFooter.addSubview(recoveryButton)
        NSLayoutConstraint.activate([
            recoveryFooter.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            recoveryFooter.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            recoveryFooter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            recoveryButton.topAnchor.constraint(equalTo: recoveryFooter.topAnchor, constant: 8),
            recoveryButton.leadingAnchor.constraint(equalTo: recoveryFooter.leadingAnchor, constant: 20),
            recoveryButton.trailingAnchor.constraint(equalTo: recoveryFooter.trailingAnchor, constant: -20),
            recoveryButton.bottomAnchor.constraint(equalTo: recoveryFooter.bottomAnchor, constant: -8),
            recoveryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func applyReport() {
        var snapshot = NSDiffableDataSourceSnapshot<String, ResolutionCheck>()
        let summaryCheck = ResolutionCheck(
            package: "",
            requirement: summary,
            outcome: .conflictingRequirements
        )
        snapshot.appendSections([summaryCheck.package])
        snapshot.appendItems([summaryCheck], toSection: summaryCheck.package)
        var seen: Set<ResolutionCheck> = [summaryCheck]
        for check in report where seen.insert(check).inserted {
            if !snapshot.sectionIdentifiers.contains(check.package) {
                snapshot.appendSections([check.package])
            }
            snapshot.appendItems([check], toSection: check.package)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
        let identity = dataSource.snapshot().sectionIdentifiers[section]
        header.textLabel?.text = identity.isEmpty ? String(localized: "What Happened") : identity
        header.textLabel?.font = .rounded(.subheadline, emphasized: true)
        header.textLabel?.textColor = .textTitle
        header.textLabel?.numberOfLines = 0
        return header
    }

    @objc private func shareReport() {
        let details = report.map { "\($0.package)\n\($0.requirement)\n\($0.detailText)" }.joined(separator: "\n\n")
        let controller = UIActivityViewController(
            // the reason alone is already the summary
            activityItems: [reasonOnly ? summary : summary + "\n\n" + details],
            applicationActivities: nil
        )
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
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
            self?.prepareRecoveryInstallation()
        }
    }

    private func prepareRecoveryInstallation() {
        guard let recoveryPackage else { return }
        let progress = progressAlert(
            title: "Preparing…",
            message: "Checking packages…"
        )
        Task { [weak self] in
            guard let self else { return }
            await withCheckedContinuation { ready in
                present(progress, animated: true) { ready.resume() }
            }
            let payload = await TaskProcessor.shared.createRecoveryOperationPayload(package: recoveryPackage)
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
