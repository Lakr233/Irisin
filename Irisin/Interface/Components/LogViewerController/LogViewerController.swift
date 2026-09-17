//
//  LogViewerController.swift
//  Irisin
//

import Dog
import SnapKit
import UIKit

/// Dog's current log file, read back as rows.
///
/// The file is parsed once into `parsed` and filtered from there, so a filter
/// change costs a filter rather than a re-parse. While the screen is up it
/// follows the file: the poll compares the file's size, and only a file that
/// actually grew is read again.
final class LogViewerController: UIViewController, UITableViewDelegate {
    let tableView = UITableView(frame: .zero, style: .plain)

    /// Every line in the file, filters not yet applied.
    var parsed: [LogLine] = []
    /// What the table is showing.
    var shown: [LogLine] = []

    var selectedLevels: Set<Dog.DogLevel> = [.verbose, .info, .warning, .error, .critical]
    var selectedCategories: Set<String> = []
    var allCategories: Set<String> {
        Set(parsed.map(\.category))
    }

    var hiddenPrefixCount = 0

    /// Size of the file at the last parse, so the poll can skip a file that
    /// has not moved.
    var lastReadLength = -1
    private var tail: Timer?
    /// The first parse, running from init so the caller can hold the push
    /// for it; nil once the rows are in `parsed`.
    var work: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
        lastReadLength = Self.fileLength
        let text = logText()
        work = Task { [weak self] in
            let lines = await Self.parse(text)
            guard let self, !Task.isCancelled else { return }
            work = nil
            parsed = lines
            if isViewLoaded {
                applyFilters(stickToBottom: true)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// Waits for the first parse, up to `budget`, and lays the page out with
    /// it. A page pushed after this shows its rows at once when the parse
    /// made it in time; otherwise the rows land when it does.
    func prepare(within budget: Duration) async {
        if let work {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await work.value }
                group.addTask { try? await Task.sleep(for: budget) }
                await group.next()
                group.cancelAll()
            }
        }
        loadViewIfNeeded()
        view.layoutIfNeeded()
    }

    /// A line's place in the log is its identity: the same text can be
    /// written twice and both rows have to exist.
    nonisolated struct Row: Hashable, Sendable {
        let index: Int
        let line: LogLine
    }

    lazy var dataSource = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) { tableView, _, row in
        let id = "LogCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        Self.configure(cell, with: row.line)
        return cell
    }

    /// Unchecked only because `Dog.DogLevel` predates Sendable; it is an
    /// enum over string raw values and every other field is a `String`.
    nonisolated struct LogLine: Hashable, @unchecked Sendable {
        let timestamp: String
        let level: Dog.DogLevel
        let category: String
        let message: String
        let fullText: String

        func appending(_ line: String) -> LogLine {
            LogLine(
                timestamp: timestamp,
                level: level,
                category: category,
                message: message + "\n" + line,
                fullText: fullText + "\n" + line
            )
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Logs")
        view.backgroundColor = .plainBackground
        navigationItem.largeTitleDisplayMode = .never

        setupNavigationItems()
        setupTableView()
        // rows already parsed go up with the view; otherwise the first
        // parse applies them when it lands
        if work == nil {
            applyFilters(stickToBottom: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The log is being written while it is being read — an install runs
        // in a sheet over this one. Following the file is the whole point.
        // A sheet dismissed over this screen appears it again without ever
        // disappearing it: the previous timer goes first.
        tail?.invalidate()
        tail = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfFileGrew() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tail?.invalidate()
        tail = nil
    }

    private func setupTableView() {
        tableView.dataSource = dataSource
        tableView.delegate = self
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .singleLine
        tableView.backgroundColor = .plainBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    func applyFilters(stickToBottom: Bool) {
        shown = parsed.filter { line in
            selectedLevels.contains(line.level)
                && (selectedCategories.isEmpty || selectedCategories.contains(line.category))
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.enumerated().map { Row(index: $0.offset, line: $0.element) })
        dataSource.apply(snapshot, animatingDifferences: false)
        if stickToBottom {
            scrollToBottom()
        }
    }

    /// Following the file must not fight someone reading further up, so new
    /// lines only pull the view down when it was already at the end.
    var isNearBottom: Bool {
        guard tableView.contentSize.height > tableView.bounds.height else { return true }
        let distance = tableView.contentSize.height
            - tableView.contentOffset.y
            - tableView.bounds.height
            + tableView.adjustedContentInset.bottom
        return distance < 60
    }

    private func scrollToBottom() {
        guard !shown.isEmpty else { return }
        // the snapshot applied without animation, so a layout pass now has
        // the rows and the scroll lands before the page is on screen
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: shown.count - 1, section: 0), at: .bottom, animated: false)
    }

    private static func configure(_ cell: UITableViewCell, with logLine: LogLine) {
        cell.textLabel?.font = .monospaced(.caption2)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.text = logLine.message

        cell.detailTextLabel?.font = .monospaced(.caption2)
        cell.detailTextLabel?.numberOfLines = 1
        if logLine.timestamp.isEmpty {
            cell.detailTextLabel?.text = logLine.category
        } else {
            cell.detailTextLabel?.text = "\(logLine.timestamp) • \(logLine.category)"
        }

        switch logLine.level {
        case .verbose:
            cell.textLabel?.textColor = .logVerbose
            cell.detailTextLabel?.textColor = .logVerboseDetail
            cell.backgroundColor = .plainBackground
        case .info:
            cell.textLabel?.textColor = .label
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.backgroundColor = .plainBackground
        case .warning:
            cell.textLabel?.textColor = .logProblem
            cell.detailTextLabel?.textColor = .logProblemDetail
            cell.backgroundColor = .plainBackground
        case .error:
            cell.textLabel?.textColor = .logProblem
            cell.detailTextLabel?.textColor = .logProblemDetail
            cell.backgroundColor = .logErrorBackground
        case .critical:
            cell.textLabel?.textColor = .logProblem
            cell.detailTextLabel?.textColor = .logProblemDetail
            cell.backgroundColor = .logCriticalBackground
        }

        cell.selectionStyle = .none
    }
}

extension UIViewController {
    func presentLogViewer() {
        let viewer = LogViewerController()
        Task {
            // the push waits for the parse up to about twelve frames, so
            // the rows land with the page instead of after it
            await viewer.prepare(within: .milliseconds(200))
            present(next: viewer)
        }
    }
}
