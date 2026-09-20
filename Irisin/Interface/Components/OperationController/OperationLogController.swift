import Combine
import UIKit

/// Every line the helper said, in order: the page behind the operation's
/// menu, for whoever wants the whole account. It follows a running
/// operation and reads the same once it is over.
final class OperationLogController: UIViewController {
    private let monitor: OperationMonitor
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var lines: [String] = []
    private var subscriptions = Set<AnyCancellable>()

    private lazy var dataSource = UITableViewDiffableDataSource<Int, Int>(
        tableView: tableView
    ) { [weak self] table, indexPath, line in
        let cell = table.dequeueReusableCell(withIdentifier: "log", for: indexPath) as! OperationLogCell
        cell.configure(number: line + 1, message: self?.lines[line] ?? "")
        return cell
    }

    init(monitor: OperationMonitor) {
        self.monitor = monitor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(monitor:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Operation Log")
        view.backgroundColor = .pageBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() }
        )

        tableView.backgroundColor = .pageBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 28
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        tableView.allowsSelection = false
        tableView.register(OperationLogCell.self, forCellReuseIdentifier: "log")
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        // Rows arrive in bursts while a script prints; the table is refreshed
        // at most ten times a second and always ends on the latest state.
        monitor.$lineCount
            .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                apply(monitor.lines)
            }
            .store(in: &subscriptions)
    }

    private func share() {
        ShareSheet.present(
            [monitor.lines.joined(separator: "\n")],
            anchor: navigationItem.rightBarButtonItem.map { PopoverAnchor($0) },
            from: self
        )
    }

    private func apply(_ lines: [String]) {
        let previous = dataSource.snapshot()
        let lastVisible = previous.itemIdentifiers.last.map {
            tableView.indexPathsForVisibleRows?.contains(IndexPath(row: $0, section: 0)) == true
        } ?? true
        let follow = lastVisible && !tableView.isTracking && !tableView.isDecelerating
        self.lines = lines
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        // A row is its position: the same text can be said twice and both
        // rows have to exist. Rows never change once said.
        snapshot.appendItems(Array(lines.indices))
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self, follow, !lines.isEmpty else { return }
            tableView.scrollToRow(at: IndexPath(row: lines.count - 1, section: 0), at: .bottom, animated: false)
        }
    }
}
