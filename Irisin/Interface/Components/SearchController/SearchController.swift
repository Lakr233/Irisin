//
//  SearchController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/13.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import Dog
import UIKit

class SearchController: UITableViewController {
    let cellId = UUID().uuidString
    var searchController: UISearchController {
        hostedSearchController ?? ownSearchController
    }

    private lazy var ownSearchController = UISearchController()
    /// Weak: it owns this controller as its results.
    private weak var hostedSearchController: UISearchController?

    /// The screen whose bar carries the search field when this one is only
    /// the results under it: a results controller has no navigation
    /// controller of its own, so what a row opens is pushed from there.
    private weak var host: UIViewController?

    /// A search field for `host`'s navigation item, with the results shown
    /// over the host once something is typed.
    static func searchController(hostedBy host: UIViewController) -> UISearchController {
        let results = SearchController()
        let searchController = UISearchController(searchResultsController: results)
        results.host = host
        results.hostedSearchController = searchController
        results.configureSearchController()
        return searchController
    }

    var previousSearchValue = "" {
        didSet {
            if previousSearchValue.isEmpty {
                setSearchResult(with: [])
            }
            updateGuiderOpacity()
        }
    }

    /// The search in flight; a newer keystroke cancels it.
    private var searchTask: Task<Void, Never>?

    nonisolated enum Section: Hashable {
        case results(SearchResult.Section)
        case empty
    }

    nonisolated enum Item: Hashable {
        case result(SearchResult)
        case empty
    }

    private lazy var diffableDataSource = UITableViewDiffableDataSource<Section, Item>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, item in
        let cell = tableView.dequeueReusableCell(withIdentifier: cellId, for: indexPath) as! SearchCell
        switch item {
        case .empty: cell.makeEmptyHinter()
        case let .result(result): cell.insertValue(with: result)
        }
        return cell
    }

    let guider = EmptyStateView(
        icon: .bookSearch24Regular,
        text: String(localized: "Search packages, repositories and authors.")
    )

    private var subscriptions = Set<AnyCancellable>()

    /// Grouped so the section headers scroll with the rows instead of floating.
    init() {
        super.init(style: .grouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Publishers.MergeMany([RepositoryCenter.registrationUpdate, PackageCenter.packageRecordChanged].map {
            NotificationCenter.default.publisher(for: $0)
        })
        .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.searchAgain() }
        .store(in: &subscriptions)
        title = String(localized: "Search")
        view.backgroundColor = .plainBackground

        tableView.separatorColor = .clear
        tableView.backgroundColor = .plainBackground
        tableView.sectionFooterHeight = 0
        tableView.register(SearchCell.self, forCellReuseIdentifier: cellId)
        diffableDataSource.defaultRowAnimation = .fade
        tableView.dataSource = diffableDataSource

        if host == nil {
            configureSearchController()
            searchController.obscuresBackgroundDuringPresentation = false
            navigationItem.searchController = searchController
            navigationItem.hidesSearchBarWhenScrolling = false
        }

        // centred in what the keyboard leaves
        view.addSubview(guider)
        guider.snp.makeConstraints { x in
            x.top.equalTo(view.safeAreaLayoutGuide)
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide).inset(32)
            x.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
    }

    private func configureSearchController() {
        searchController.searchBar.placeholder = String(localized: "Search")
        searchController.searchBar.setValue(
            String(localized: "Cancel"),
            forKey: "cancelButtonText"
        )
        searchController.searchResultsUpdater = self
        searchController.delegate = self
        searchController.searchBar.delegate = self
        // the bar is focused on arrival; without this the title and the
        // scroll edge under the status bar go with it
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchBar.searchTextField.autocapitalizationType = .none
        searchController.searchBar.searchTextField.autocorrectionType = .no
        searchController.searchBar.searchTextField.smartQuotesType = .no
        searchController.searchBar.searchTextField.smartDashesType = .no
        searchController.searchBar.searchTextField.smartInsertDeleteType = .no
    }

    private var hasFocusedSearchBar = false

    /// The keyboard comes up the first time the screen is entered; coming
    /// back from a result leaves the results where they were.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard host == nil, !hasFocusedSearchBar else { return }
        hasFocusedSearchBar = true
        searchController.searchBar.becomeFirstResponder()
    }

    override func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard case .results = diffableDataSource.sectionIdentifier(for: section) else { return 0 }
        return UITableView.automaticDimension
    }

    override func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard case let .results(kind) = diffableDataSource.sectionIdentifier(for: section) else { return nil }
        let box = UIView()
        let label = UILabel()
        label.font = .captionEmphasized
        label.textColor = .sectionCaption
        box.addSubview(label)
        label.snp.makeConstraints { x in
            x.leading.equalToSuperview().offset(20)
            x.trailing.equalToSuperview().offset(-20)
            x.top.bottom.equalToSuperview().inset(3)
        }
        switch kind {
        case .author:
            label.text = String(localized: "Authors")
        case .installed:
            label.text = String(localized: "Installed")
        case .package:
            label.text = String(localized: "Packages")
        case .repository:
            label.text = String(localized: "Repositories")
        }
        return box
    }

    private func result(at indexPath: IndexPath) -> SearchResult? {
        guard case let .result(object) = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        return object
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let object = result(at: indexPath) else { return }
        switch object.associatedValue {
        case let .installed(package):
            let target = PackageController(package: package)
            (host ?? self).present(next: target)
        case let .package(identity, repository):
            if let lookup = PackageCenter.default.obtainPackage(with: identity, in: repository) {
                let target = PackageController(package: lookup)
                (host ?? self).present(next: target)
            }
        case let .repository(url):
            guard let repo = RepositoryCenter
                .default
                .obtainImmutableRepository(withUrl: url)
            else {
                return
            }
            let target = RepositoryDetailController(withRepo: repo)
            (host ?? self).present(next: target)
        case let .author(name):
            let list = PackageCenter.default.obtainPackage(by: name)
            let target = PackageCollectionController()
            target.dataSource = list.sorted {
                PackageCenter.default.name(of: $0)
                    < PackageCenter.default.name(of: $1)
            }
            (host ?? self).present(next: target)
        }
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let object = result(at: indexPath) else { return nil }
        switch object.associatedValue {
        case let .installed(package):
            return PackageMenu.contextMenu(
                for: package,
                from: self,
                anchor: tableView.cellForRow(at: indexPath)
            )
        case let .package(identity, repository):
            if let lookup = PackageCenter.default.obtainPackage(with: identity, in: repository) {
                return PackageMenu.contextMenu(
                    for: lookup,
                    from: self,
                    anchor: tableView.cellForRow(at: indexPath)
                )
            }
        case .repository, .author:
            return nil
        }
        return nil
    }

    override func tableView(
        _: UITableView,
        willPerformPreviewActionForMenuWith _: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        (host ?? self).show(preview: animator)
    }

    func updateGuiderOpacity() {
        UIView.animate(withDuration: 0.25) { [self] in
            guider.alpha = previousSearchValue.isEmpty ? 1 : 0
        }
    }

    func setSearchResult(with value: [[SearchResult]]) {
        Dog.shared.join(self, "\(value.count) result will be applied", level: .verbose)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if previousSearchValue.isEmpty {
            // nothing typed: the guider takes the screen
        } else if value.isEmpty {
            snapshot.appendSections([.empty])
            snapshot.appendItems([.empty], toSection: .empty)
        } else {
            for group in value {
                guard let first = group.first else { continue }
                let section = Section.results(first.section)
                if !snapshot.sectionIdentifiers.contains(section) {
                    snapshot.appendSections([section])
                }
                snapshot.appendItems(group.uniqued().map(Item.result), toSection: section)
            }
        }
        // the key moved under a row that stayed: repaint its highlight
        snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
        diffableDataSource.apply(snapshot, animatingDifferences: tableView.shouldAnimateDiff)
    }
}

extension SearchController: UISearchControllerDelegate, UISearchResultsUpdating, UISearchBarDelegate {
    /// The results on screen are a query over the catalogue; when the
    /// catalogue changes under them, the same query runs again.
    func searchAgain() {
        guard let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return }
        previousSearchValue = "\u{0}" // never equal to typed text: the same query runs again
        updateSearchResults(for: searchController)
    }

    func updateSearchResults(for searchController: UISearchController) {
        guard let text = searchController
            .searchBar
            .text?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            previousSearchValue != text
        else {
            return
        }
        previousSearchValue = text
        Dog.shared.join(self, "should search with text [\(text)]", level: .verbose)
        searchTask?.cancel()
        let index = PackageCenter.default.index
        let repositories = RepositoryCenter.default.repositories
        searchTask = Task {
            let results = await SearchResult.search(
                key: text,
                in: index,
                repositories: repositories
            )
            // a newer keystroke owns the table now
            guard !Task.isCancelled else { return }
            setSearchResult(with: results)
        }
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        guard var text = searchBar
            .text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if text.hasPrefix("http"), let url = URL(string: text) {
            if RepositoryCenter.default.obtainImmutableRepository(withUrl: url) != nil {
                return
            }
            guard let source = RepositorySource(line: url.absoluteString) else {
                return
            }
            Task { [weak self] in
                try? await Task.sleep(seconds: 0.6)
                guard let self else { return }
                // the user may have tapped a row, cancelled or left during the
                // wait; the search is no longer on screen and must not put the
                // add sheet over whatever replaced it
                let page = host ?? self
                guard searchController.isActive,
                      searchController.presentedViewController == nil,
                      page.view.window != nil,
                      page.navigationController?.topViewController === page
                else { return }
                searchController.present(
                    RepositoryAddController.sheet(initialInput: source.line),
                    animated: true
                )
            }
        }
    }
}
