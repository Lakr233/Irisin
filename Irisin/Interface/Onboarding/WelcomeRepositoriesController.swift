//
//  WelcomeRepositoriesController.swift
//  Irisin
//
//  The second page of onboarding: the repositories most people start from
//  on this bootstrap, each with its own Add, as on the add sheet, and a row
//  that opens the add sheet for any other. Its button leads to the caution
//  page, which finishes.
//

import AptRepository
import Dog
import IrisinAdapter
import SnapKit
import Then
import UIKit

class WelcomeRepositoriesController: UIViewController, UITableViewDelegate {
    nonisolated enum Section: Hashable {
        /// No rows: the note on what a repository is, over everything.
        case notice
        case recommended
        case more
    }

    nonisolated enum Row: Hashable {
        case source(String)
        case addMore
    }

    /// Rootless and roothide get separate lists, never mixed. Havoc,
    /// Chariz and BigBoss publish rootless packages only, which roothide
    /// installs through the adapter; ElleKit is rootless alone, since
    /// roothide brings its own injector. BigBoss is a suite and plain
    /// HTTP: a bare address has no Release, and its certificate expired.
    private static var recommendedSources: [String] {
        if PackagedArchitecture.architecture == BootstrapArchitecture.roothide.rawValue {
            return [
                "https://roothide.github.io",
                // roothide's own Procursus build: 1800 is iOS 15, below the
                // app's floor, and iOS 17 and later use 1900 too
                "deb https://roothide.github.io/procursus iphoneos-arm64e/1900 main",
                "https://havoc.app",
                "https://repo.chariz.com",
                "deb http://apt.thebigboss.org/repofiles/cydia stable main",
                "https://apt.owngoal.dev",
            ]
        }
        return [
            "deb https://apt.procurs.us \(procursusSuite) main",
            "https://havoc.app",
            "https://repo.chariz.com",
            "deb http://apt.thebigboss.org/repofiles/cydia stable main",
            "https://ellekit.space",
            "https://apt.owngoal.dev",
        ]
    }

    /// Procursus has one rootless suite per iOS release, named after
    /// CoreFoundation's version; iOS 18 was 3000, and nothing newer exists.
    private static var procursusSuite: String {
        switch ProcessInfo.processInfo.operatingSystemVersion.majorVersion {
        case ..<17: "1900"
        case 17: "2000"
        default: "3000"
        }
    }

    private let onFinish: () -> Void
    private let lines = WelcomeRepositoriesController.recommendedSources
    private var previews: [String: RepositoryAddCandidateCell.Preview] = [:]
    private var registered = Set(RepositoryCenter.default.obtainRepositoryUrls())
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private lazy var dataSource = UITableViewDiffableDataSource<Section, Row>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, row in
        switch row {
        case let .source(line):
            let cell = tableView
                .dequeueReusableCell(withIdentifier: "candidate", for: indexPath) as! RepositoryAddCandidateCell
            let added = RepositorySource(line: line).map { registered.contains($0.url) } ?? false
            cell.configure(line: line, preview: previews[line] ?? .loading, added: added)
            cell.onAdd = { [weak self] in self?.add(line) }
            return cell
        case .addMore:
            let cell = tableView.dequeueReusableCell(withIdentifier: "action", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Add More…")
            content.textProperties.color = .buttonNormal
            cell.contentConfiguration = content
            return cell
        }
    }

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add Repositories")
        view.backgroundColor = .groupedBackground

        let actionBar = WelcomeActionBar(title: String(localized: "Next")) { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(WelcomeCautionController(onFinish: onFinish), animated: true)
        }
        view.addSubview(tableView)
        view.addSubview(actionBar)
        tableView.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.bottom.equalTo(actionBar.snp.top)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }

        tableView.backgroundColor = .groupedBackground
        tableView.register(RepositoryAddCandidateCell.self, forCellReuseIdentifier: "candidate")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "action")
        tableView.register(RepositoryAddSectionHeaderView.self, forHeaderFooterViewReuseIdentifier: "recommended")
        tableView.dataSource = dataSource
        tableView.delegate = self

        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.notice, .recommended, .more])
        snapshot.appendItems(lines.map { .source($0) }, toSection: .recommended)
        snapshot.appendItems([.addMore], toSection: .more)
        dataSource.apply(snapshot, animatingDifferences: false)

        for line in lines {
            loadPreview(of: line)
        }
    }

    /// A source that does not answer is said so, and can still be added.
    private func loadPreview(of line: String) {
        guard let source = RepositorySource(line: line) else { return }
        Task { [weak self] in
            let info = await RepositoryCenter.default.preview(of: source)
            guard let self else { return }
            previews[line] = info.map { .loaded($0) } ?? .failed
            reconfigure(line)
        }
    }

    private func add(_ line: String) {
        guard let source = RepositorySource(line: line), !registered.contains(source.url) else { return }
        Dog.shared.join("Repository", "user added \(source.line)", level: .info)
        RepositoryCenter.default.registerRepository(source)
        registered.insert(source.url)
        reconfigure(line)
        updateRecommendedHeader()
    }

    /// Add All, in the header over the list: every source not registered yet.
    private func addAll() {
        for line in lines {
            add(line)
        }
    }

    private var offersAddAll: Bool {
        lines.contains { line in
            RepositorySource(line: line).map { !registered.contains($0.url) } ?? false
        }
    }

    /// Add All leaves with the last source it could add.
    private func updateRecommendedHeader() {
        guard let index = dataSource.snapshot().indexOfSection(.recommended),
              let header = tableView.headerView(forSection: index) as? RepositoryAddSectionHeaderView
        else { return }
        header.showsButton = offersAddAll
    }

    private func reconfigure(_ line: String) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.source(line)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - TABLE VIEW

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .addMore else { return }
        present(RepositoryAddController.sheet(), animated: true)
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch dataSource.sectionIdentifier(for: section) {
        case .notice:
            return Self.text(.groupedHeader(), "A repository can include apps, plugins, themes, and ringtones. Anyone can host one, and we cannot verify that its packages are safe.")
        case .recommended:
            let header = tableView
                .dequeueReusableHeaderFooterView(withIdentifier: "recommended") as? RepositoryAddSectionHeaderView
            header?.configure(title: String(localized: "Recommended Repositories"), showsButton: offersAddAll)
            header?.onAddAll = { [weak self] in self?.addAll() }
            return header
        default:
            return nil
        }
    }

    func tableView(_: UITableView, viewForFooterInSection section: Int) -> UIView? {
        switch dataSource.sectionIdentifier(for: section) {
        case .recommended:
            Self.text(.groupedFooter(), "These repositories are widely used. We recommend starting here.")
        case .more:
            Self.text(.groupedFooter(), "You can add more later in the app.")
        default:
            nil
        }
    }

    /// Header or footer text in the list's own style: the delegate's views,
    /// since the plain diffable data source has no titles.
    private static func text(
        _ configuration: UIListContentConfiguration,
        _ text: String.LocalizationValue
    ) -> UIView {
        var configuration = configuration
        configuration.text = String(resolving: text)
        return UITableViewHeaderFooterView().then { $0.contentConfiguration = configuration }
    }
}
