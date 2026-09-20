//
//  InstalledController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/29.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import SPIndicator
import Then
import UIKit

class InstalledController: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    var subscriptions = Set<AnyCancellable>()
    var updateSetTask: Task<Void, Never>?

    // MARK: - SORT OPTION

    enum SortOption: String, CaseIterable {
        case name
        case lastModification

        func convertToInterfaceString() -> String {
            switch self {
            case .name:
                String(localized: "Name")
            case .lastModification:
                String(localized: "Last Modified")
            }
        }
    }

    private let sortOptionStore = PropertiesWrapper(
        key: "installed.sortOption",
        defaultValue: SortOption.lastModification.rawValue
    )
    private let sortReversedStore = PropertiesWrapper(key: "installed.sortReversed", defaultValue: false)

    var sortOption: SortOption {
        SortOption(rawValue: sortOptionStore.wrappedValue) ?? .name
    }

    var sortReversed: Bool {
        get { sortReversedStore.wrappedValue }
        set {
            sortReversedStore.wrappedValue = newValue
            Task { updateSource() }
        }
    }

    // MARK: - FILTER

    /// The `Section:` fields the list is narrowed to; empty shows everything.
    private let selectedSectionsStore = PropertiesWrapper(key: "installed.sections", defaultValue: [String]())
    var selectedSections: Set<String> {
        get { Set(selectedSectionsStore.wrappedValue) }
        set {
            selectedSectionsStore.wrappedValue = newValue.sorted()
            Task { updateSource(withSearchText: searchController.searchBar.text) }
        }
    }

    /// The authors the list is narrowed to; empty shows everything.
    private let selectedAuthorsStore = PropertiesWrapper(key: "installed.authors", defaultValue: [String]())
    var selectedAuthors: Set<String> {
        get { Set(selectedAuthorsStore.wrappedValue) }
        set {
            selectedAuthorsStore.wrappedValue = newValue.sorted()
            Task { updateSource(withSearchText: searchController.searchBar.text) }
        }
    }

    /// Every section and author among the installed packages and how many
    /// packages carry each, before the filter and the search apply.
    /// Refreshed by `updateSource`.
    var sectionCounts: [String: Int] = [:]
    var authorCounts: [String: Int] = [:]

    static func section(of package: Package) -> String {
        let section = package.latestMetadata?["section"] ?? ""
        return section.isEmpty ? String(localized: "Unknown Section") : section.sectionDisplayName
    }

    /// Each author the way the package page names them: the name alone,
    /// without the `<address>` or `<https://...>` after it.
    static func authors(of package: Package) -> [String] {
        let authors = PackageCenter.authors(of: package)
            .map { PackageController.contact($0).text }
            .filter { !$0.isEmpty }
        return authors.isEmpty ? [String(localized: "Unknown Author")] : authors
    }

    // MARK: - PROPERTY

    let searchController = UISearchController()
    let cellId = UUID().uuidString
    let headerId = UUID().uuidString

    struct InstalledData {
        let key: Date? // the section: the modification date, nil when unsorted or never modified
        let section: String?
        var package: [Package]
    }

    var dataSource: [InstalledData] = []
    /// Installed packages with a candidate. Answering this per row costs two
    /// index lookups, so the whole set is refreshed on a reload and read from.
    /// The install origins by identity, as of the last reload: the rows are
    /// dpkg's, and they sort and search by the name the origin gives them.
    var origins: [String: Package] = [:]
    var identitiesWithUpdate: Set<String> = []
    var updateFound: Bool {
        !identitiesWithUpdate.isEmpty
    }

    private(set) lazy var diffableDataSource: UICollectionViewDiffableDataSource<Date?, Package> = {
        let source = UICollectionViewDiffableDataSource<Date?, Package>(
            collectionView: collectionView
        ) { [unowned self] collectionView, indexPath, package in
            configureCell(collectionView, at: indexPath, for: package)
        }
        source.supplementaryViewProvider = { [unowned self] collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionFooter {
                let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: footerId,
                    for: indexPath
                )
                (view as? FootnoteView)?.label.text = footerText
                footerView = view as? FootnoteView
                return view
            }
            let view = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: headerId,
                for: indexPath
            )
            if let view = view as? ReuseTimerHeaderView,
               let key = diffableDataSource.sectionIdentifier(for: indexPath.section)
            {
                view.horizontalPadding = 0
                view.loadText(dataSource.first { $0.key == key }?.section ?? "")
            }
            return view
        }
        return source
    }()

    func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Date?, Package>()
        var seen = Set<Package>()
        for section in dataSource {
            snapshot.appendSections([section.key])
            snapshot.appendItems(section.package.filter { seen.insert($0).inserted }, toSection: section.key)
        }
        // the update indicator lives outside the package: repaint survivors
        snapshot.reconfigureItems(survivingFrom: diffableDataSource.snapshot())
        diffableDataSource.apply(snapshot, animatingDifferences: collectionView.shouldAnimateDiff)
        // the footer is not a row: a diff never redraws it, so tell it directly
        footerView?.label.text = footerText
        rebuildMoreMenu()
        updateEmptyState()
    }

    /// Nothing to list is said, and says whether a search or a filter is
    /// the reason; a blank screen looks like a broken one.
    private func updateEmptyState() {
        guard dataSource.allSatisfy(\.package.isEmpty) else {
            collectionView.backgroundView = nil
            return
        }
        emptyStateLabel.text = isNarrowed
            ? String(localized: "No installed packages match the search or filter.")
            : String(localized: "No packages are installed.")
        collectionView.backgroundView = emptyStateLabel
    }

    /// Whether a search or a filter is holding rows back.
    private var isNarrowed: Bool {
        !(searchController.searchBar.text ?? "").isEmpty
            || !selectedSections.isEmpty
            || !selectedAuthors.isEmpty
    }

    private let emptyStateLabel = EmptyStateView()

    // MARK: - FOOTER

    let footerId = UUID().uuidString
    /// The one footer on screen, so a new list can retitle it without a reload.
    weak var footerView: FootnoteView?

    /// What the list shows, filter and search applied.
    var footerText: String {
        let shown = dataSource.flatMap(\.package)
        let sections = Set(shown.map(Self.section(of:))).count
        return String(localized: "Packages: \(shown.count) · Sections: \(sections)")
    }

    let formatter = DateFormatter().then {
        $0.formatterBehavior = .behavior10_4
        $0.dateStyle = .medium
        $0.timeStyle = .medium
    }

    let refreshControl = UIRefreshControl()

    var collectionViewFrameCache: CGSize?
    /// The text size the cached cell size was measured at: a row is as tall
    /// as its lines, so a change of text size has to measure it again.
    var collectionViewTextSizeCache: UIContentSizeCategory?
    var collectionViewCellSizeCache = InterfaceBridge.minimumPackageCellSize

    init() {
        let flowLayout = UICollectionViewFlowLayout()
        flowLayout.sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        flowLayout.scrollDirection = UICollectionView.ScrollDirection.vertical
        flowLayout.minimumInteritemSpacing = 0.0
        super.init(collectionViewLayout: flowLayout)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    func justReload() {
        updateSource(withSearchText: searchController.searchBar.searchTextField.text)
        refreshUpdateSet()
    }

    @objc
    func refresh() {
        Task {
            await InterfaceBridge.reloadLocalPackages()
            refreshControl.endRefreshing()
            justReload()
            SPIndicator
                .present(
                    title: String(localized: "Installed packages refreshed"),
                    message: "",
                    preset: .done,
                    from: .top,
                    completion: nil
                )
        }
    }

    @objc
    func sendUpdate() {
        UpdateController.show(from: self)
    }

    // MARK: - MORE MENU

    /// The ellipsis left of the update button: refresh, export, the filters
    /// and the sort order. A `UIButton`, because reassigning its `menu`
    /// redraws the menu while it is open — `updateVisibleMenu` does not, and
    /// a deferred element is resolved once per presentation — so a filter
    /// toggled with `keepsMenuPresented` ticks at once. `applySnapshot`
    /// rebuilds it, and every change to the list goes through there.
    private let moreButton = UIButton(type: .system).then {
        $0.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        $0.tintColor = .textTitle
        $0.showsMenuAsPrimaryAction = true
        $0.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
    }

    lazy var moreItem = UIBarButtonItem(customView: moreButton)

    func rebuildMoreMenu() {
        moreButton.menu = UIMenu(identifier: .init("installed.more"), children: buildMoreMenu())
    }

    private func buildMoreMenu() -> [UIMenuElement] {
        // multi-selection reads better with the menu staying open, iOS 16 has that
        var stays: UIMenuElement.Attributes = []
        if #available(iOS 16.0, *) {
            stays.insert(.keepsMenuPresented)
        }

        // the list sorts dates newest first when not reversed, names A to Z
        let sort = UIMenu(
            title: String(localized: "Sort By"),
            subtitle: sortOption.convertToInterfaceString(),
            image: UIImage(systemName: "arrow.up.arrow.down"),
            identifier: .init("installed.sort"),
            children: SortOption.allCases.map { option in
                let ascendingIsReversed = option == .lastModification
                let directions = [
                    (true, String(localized: "Ascending"), "arrow.up"),
                    (false, String(localized: "Descending"), "arrow.down"),
                ]
                return UIMenu(
                    title: option.convertToInterfaceString(),
                    image: UIImage(systemName: option == .name ? "textformat" : "clock"),
                    identifier: .init("installed.sort.\(option.rawValue)"),
                    children: directions.map { ascending, title, icon in
                        let reversed = ascending == ascendingIsReversed
                        return UIAction(
                            title: title,
                            image: UIImage(systemName: icon),
                            state: sortOption == option && sortReversed == reversed ? .on : .off
                        ) { [weak self] _ in
                            guard let self else { return }
                            sortOptionStore.wrappedValue = option.rawValue // one rebuild, below
                            sortReversed = reversed
                        }
                    }
                )
            }
        )

        let filtering = !selectedSections.isEmpty || !selectedAuthors.isEmpty
        let total = sectionCounts.values.reduce(0, +)
        let filter = UIMenu(
            title: String(localized: "Filter"),
            subtitle: filtering ? nil : String(localized: "\(total) Packages"),
            image: UIImage(
                systemName: filtering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            ),
            identifier: .init("installed.filter"),
            children: [
                choiceMenu(
                    title: String(localized: "Section"),
                    image: "square.grid.2x2",
                    identifier: "installed.filter.section",
                    all: String(localized: "All Sections"),
                    counts: sectionCounts,
                    selection: \.selectedSections,
                    stays: stays
                ),
                choiceMenu(
                    title: String(localized: "Author"),
                    image: "person",
                    identifier: "installed.filter.author",
                    all: String(localized: "All Authors"),
                    counts: authorCounts,
                    selection: \.selectedAuthors,
                    stays: stays
                ),
            ]
        )

        var top: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Refresh"),
                image: UIImage(systemName: "arrow.clockwise")
            ) { [weak self] _ in self?.refresh() },
        ]
        if updateFound {
            top.append(UIAction(
                title: String(localized: "Block All Updates"),
                image: UIImage(systemName: "hand.raised"),
                attributes: .destructive
            ) { [weak self] _ in self?.blockUpdateAll() })
        }

        return [
            UIMenu(options: .displayInline, children: top),
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Export Package List"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in self?.exportPackageList() },
                UIAction(
                    title: String(localized: "Export dpkg Status"),
                    image: UIImage(systemName: "doc.text")
                ) { [weak self] _ in self?.exportStatus() },
            ]),
            UIMenu(options: .displayInline, children: [filter, sort]),
        ]
    }

    /// A multi-selection over `counts`: "all" on top, then every choice with
    /// its count, ticked when selected. The selection is read through the key
    /// path on every tap, so a menu that stays open never toggles a stale set.
    private func choiceMenu(
        title: String,
        image: String,
        identifier: String,
        all: String,
        counts: [String: Int],
        selection: ReferenceWritableKeyPath<InstalledController, Set<String>>,
        stays: UIMenuElement.Attributes
    ) -> UIMenu {
        let selected = self[keyPath: selection]
        let allAction = UIAction(
            title: all,
            attributes: stays,
            state: selected.isEmpty ? .on : .off
        ) { [weak self] _ in self?[keyPath: selection] = [] }
        let choices = counts.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { choice in
                UIAction(
                    title: choice,
                    subtitle: String(counts[choice, default: 0]),
                    attributes: stays,
                    state: selected.contains(choice) ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    var next = self[keyPath: selection]
                    if next.remove(choice) == nil {
                        next.insert(choice)
                    }
                    self[keyPath: selection] = next
                }
            }
        return UIMenu(
            title: title,
            subtitle: selected.isEmpty ? nil : selected.sorted().joined(separator: ", "),
            image: UIImage(systemName: image),
            identifier: .init(identifier),
            children: [
                UIMenu(options: .displayInline, children: [allAction]),
                UIMenu(options: .displayInline, children: choices),
            ]
        )
    }

    /// The rows as they are filtered and sorted right now, one package a line.
    private func exportPackageList() {
        let packages = dataSource.flatMap(\.package)
        guard !packages.isEmpty else {
            presentNotice(title: "Nothing to Export", dismissTitle: "OK")
            return
        }
        ExportFile.share(
            ExportFile.packageText(packages),
            named: "installed-\(ExportFile.stamp()).txt",
            from: self,
            anchor: PopoverAnchor(moreButton)
        )
    }

    /// Shares dpkg's own status file, the raw record every row here came from.
    /// A copy, so the sheet never holds the bootstrap's file open while dpkg
    /// rewrites it.
    func exportStatus() {
        let source = URL(fileURLWithPath: JailbreakRoot.installedPath("/Library/dpkg/status"))
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpkg-status-\(ExportFile.stamp()).txt")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            presentNotice(
                title: "Unable to Export",
                message: "The dpkg status file could not be copied. Try again."
            )
            return
        }
        share(copy)
    }

    private func share(_ item: Any) {
        InterfaceBridge.presentShareSheet([item], anchor: PopoverAnchor(moreButton), from: self)
    }

    @objc
    func showAllUpdateToDate() {
        let nothingInstalled = dataSource.allSatisfy(\.package.isEmpty) && !isNarrowed
        SPIndicator.present(
            title: nothingInstalled
                ? String(localized: "No packages are installed.")
                : String(localized: "All packages are up to date"),
            preset: .done
        )
    }

    @objc
    func blockUpdateAll() {
        TaskManager.shared.blockUpdateEverything()
        refreshUpdateSet()
    }

    func setupRightButtonItem() {
        let rightItem: UIBarButtonItem
        if updateFound {
            rightItem = UIBarButtonItem(
                image: .fluent(.arrowUpCircle24Filled),
                style: .plain,
                target: self,
                action: #selector(sendUpdate)
            )
        } else {
            rightItem = UIBarButtonItem(
                image: .fluent(.checkmarkCircle24Filled),
                style: .plain,
                target: self,
                action: #selector(showAllUpdateToDate)
            )
            rightItem.tintColor = .upToDate
        }
        navigationItem.rightBarButtonItems = [rightItem, moreItem]
    }
}
