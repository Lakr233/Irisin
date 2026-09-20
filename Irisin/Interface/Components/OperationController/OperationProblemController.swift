import IrisinProtocol
import UIKit

/// What went wrong with one package: what happened, in which state that
/// leaves the package, what to do about it, and what the package's own
/// scripts said, which is the only place on the operation's pages where the
/// helper's lines show. The action button hands the same account out as text.
final class OperationProblemController: UIViewController {
    nonisolated enum Section: Hashable {
        case package, happened, next, output
    }

    nonisolated enum Row: Hashable {
        case package
        case text(String)
        case output(String)
    }

    private let change: QueueChange
    private let icon: UIImage?
    private let state: OperationPackages.State
    private let output: [String]
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private lazy var dataSource: EditableTableDiffableDataSource<Section, Row> = .init(
        tableView: tableView
    ) { [unowned self] (table: UITableView, indexPath: IndexPath, row: Row) -> UITableViewCell in
        let cell = table.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.selectionStyle = .none
        switch row {
        case .package:
            cell.contentConfiguration = change.content(icon: icon, details: [change.package.identity, change.versions])
        case let .text(text):
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.font = .subheadline
            content.textProperties.color = .textTitle
            cell.contentConfiguration = content
        case let .output(text):
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.font = .monospaced(.caption)
            content.textProperties.color = .textTitle
            cell.contentConfiguration = content
        }
        return cell
    }

    init(change: QueueChange, icon: UIImage?, state: OperationPackages.State, output: [String]) {
        self.change = change
        self.icon = icon
        self.state = state
        self.output = output
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(change:icon:state:output:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Problem")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() }
        )

        tableView.backgroundColor = .groupedBackground
        tableView.allowsSelection = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.dataSource = dataSource
        dataSource.headerTitle = { section in
            switch section {
            case .package: nil
            case .happened: String(localized: "What Happened")
            case .next: String(localized: "What to Do")
            case .output: String(localized: "Script Output")
            }
        }
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.package, .happened, .next])
        snapshot.appendItems([.package], toSection: .package)
        snapshot.appendItems([.text(happened)], toSection: .happened)
        snapshot.appendItems([.text(advice)], toSection: .next)
        if !output.isEmpty {
            snapshot.appendSections([.output])
            snapshot.appendItems([.output(output.joined(separator: "\n"))], toSection: .output)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The helper's own reason when it gave one.
    private var happened: String {
        if let problem = state.problem {
            return problem.localizedDescription
        }
        switch state.status {
        case .incomplete:
            return String(localized: "This package was unpacked, but the operation stopped at another package before this one was set up.")
        case .failed:
            return String(localized: "The installer stopped while it was working on this package and did not say why.")
        default:
            return InstallerEvent.Problem.packageNeedsRepair(identity: change.package.identity).localizedDescription
        }
    }

    /// What the state the package is left in asks of the user.
    private var advice: String {
        if state.ignoredScriptFailure {
            return String(localized: "Review the script output. If the package does not work, remove it or install a fixed version.")
        }
        if state.needsRepair {
            return String(localized: "The package is half-installed. Install it again to repair it, or remove it.")
        }
        switch state.status {
        case .failed(step: .verifying):
            return String(localized: "Nothing was changed for this package. Remove it from the queue and add it again to download a fresh copy.")
        case .failed(step: .unpacking):
            return String(localized: "The package was put back as it was before. Go back and choose Try Again.")
        case .failed(step: .removing):
            return String(localized: "The package is still installed. Go back and choose Try Again.")
        case .failed:
            return String(localized: "The package's files are in place, but it is not set up and may not work. Go back and choose Try Again, or remove the package.")
        default:
            return String(localized: "Go back and choose Try Again to finish setting up this package.")
        }
    }

    private func share() {
        let report = ([
            "\(change.package.identity) \(change.versions)",
            // the helper's words, not the translation: a report is read by
            // whoever maintains the package
            state.problem?.description ?? happened,
            "",
        ] + output).joined(separator: "\n")
        ShareSheet.present(
            [report],
            anchor: navigationItem.rightBarButtonItem.map { PopoverAnchor($0) },
            from: self
        )
    }
}
