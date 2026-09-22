//
//  PathListController.swift
//  Irisin
//
//  Swift rewrite of Lessica's PathListTableViewController (2022), which used to
//  live in Packages/PathListTableViewController as Objective-C.
//

import SnapKit
import UIKit

/// The dpkg files list of an installed package, drawn as an indented tree.
///
/// Every ancestor directory of a listed file is synthesized as a row of its own,
/// so `/usr/lib/foo.dylib` also puts `/usr`, `/usr/lib` on screen and each row
/// indents by how deep its path sits.
final class PathListController: UITableViewController {
    private let entryPath: String
    private var contents: [String] = []
    private var filteredContents: [String] = []
    /// Whatever is the parent of another row. A directory the package ships
    /// empty is not known to be one from the list alone and reads as a file.
    private var directories: Set<String> = []

    private let searchController = UISearchController(searchResultsController: nil)

    private var visibleContents: [String] {
        searchController.isActive ? filteredContents : contents
    }

    private lazy var dataSource = UITableViewDiffableDataSource<Int, String>(
        tableView: tableView
    ) { [unowned self] tableView, indexPath, path in
        let cell = tableView.dequeueReusableCell(withIdentifier: PathCell.identifier, for: indexPath)
        let depth = max((path as NSString).pathComponents.count - 1, 0)
        let highlight = searchController.isActive ? searchController.searchBar.text : nil
        (cell as? PathCell)?.setPath(
            path,
            depth: depth,
            isDirectory: directories.contains(path),
            highlighting: highlight
        )
        return cell
    }

    init(path: String) {
        entryPath = path
        super.init(style: .plain)
        contents = Self.expandingAncestors(of: Self.readPaths(at: path))
        directories = Set(contents.map { ($0 as NSString).deletingLastPathComponent })
    }

    /// Paths that are in no list on disk yet: what a queued package brings.
    init(title: String, paths: [String]) {
        entryPath = ""
        super.init(style: .plain)
        self.title = title
        contents = Self.expandingAncestors(of: paths)
        directories = Set(contents.map { ($0 as NSString).deletingLastPathComponent })
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if title?.isEmpty ?? true {
            title = (entryPath as NSString).lastPathComponent
        }
        view.backgroundColor = .plainBackground

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = true
        navigationItem.hidesSearchBarWhenScrolling = true
        navigationItem.searchController = searchController

        tableView.separatorInset = .zero
        tableView.tableFooterView = UIView()
        tableView.register(PathCell.self, forCellReuseIdentifier: PathCell.identifier)
        tableView.dataSource = dataSource
        applySnapshot()
    }

    /// The highlight follows the search text, so surviving rows are
    /// reconfigured rather than left as they were.
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(visibleContents)
        snapshot.reconfigureItems(survivingFrom: dataSource.snapshot())
        dataSource.apply(snapshot, animatingDifferences: tableView.shouldAnimateDiff)
    }

    // MARK: - Contents

    private static func readPaths(at path: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
    }

    /// Adds every intermediate directory of each path, then sorts the lot.
    ///
    /// The order is by path component, never by the whole string: `-` sorts
    /// before `/`, so as strings `irisin-install` lands between `irisin`
    /// and `irisin/icli` and takes the directory's children for its own.
    static func expandingAncestors(of paths: [String]) -> [String] {
        var result = Set(paths)
        for path in paths {
            var components = (path as NSString).pathComponents
            while components.count > 1 {
                components.removeLast()
                result.insert(NSString.path(withComponents: components))
            }
        }
        result.subtract(["", "/"])
        return result
            .map { (path: $0, components: ($0 as NSString).pathComponents) }
            .sorted { lhs, rhs in
                for (left, right) in zip(lhs.components, rhs.components) {
                    let order = left.localizedCompare(right)
                    if order != .orderedSame {
                        return order == .orderedAscending
                    }
                }
                if lhs.components.count != rhs.components.count {
                    return lhs.components.count < rhs.components.count
                }
                return lhs.path < rhs.path
            }
            .map(\.path)
    }

    // MARK: - Table view

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let path = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: path, children: [
                UIAction(
                    title: String(localized: "Copy Name"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = (path as NSString).lastPathComponent
                },
                UIAction(
                    title: String(localized: "Copy Path"),
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { _ in
                    UIPasteboard.general.string = path
                },
                UIAction(
                    title: String(localized: "Reveal in Fila"),
                    image: UIImage(systemName: "folder")
                ) { [weak self] _ in
                    // Fila browses the raw filesystem, so the path a package
                    // lists has to carry the bootstrap root.
                    self?.revealInFila(path: JailbreakRoot.diskPath(ofListed: path))
                },
            ])
        }
    }
}

// MARK: - Search

extension PathListController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text ?? ""
        let matches = contents.filter {
            ($0 as NSString)
                .lastPathComponent
                .range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        filteredContents = Self.expandingAncestors(of: matches)
        applySnapshot()
    }
}

// MARK: - Cell

private final class PathCell: UITableViewCell {
    static let identifier = "PathCell"

    private static let indentationUnit: CGFloat = 14

    private let label = UILabel()
    private var indentConstraint: Constraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        label.numberOfLines = 1
        contentView.addSubview(label)
        label.snp.makeConstraints { make in
            indentConstraint = make.leading.equalToSuperview().constraint
            make.trailing.equalToSuperview().offset(-8)
            make.top.bottom.equalToSuperview().inset(4)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPath(
        _ path: String,
        depth: Int,
        isDirectory: Bool,
        highlighting search: String?
    ) {
        indentConstraint?.update(offset: CGFloat(depth) * Self.indentationUnit)

        let name = (path as NSString).lastPathComponent
        let text = NSMutableAttributedString(string: isDirectory ? name + "/" : name, attributes: [
            .font: UIFont.monospaced(.subheadline),
            .foregroundColor: UIColor.label,
        ])
        if let search, !search.isEmpty {
            let match = (name as NSString).range(
                of: search,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
            if match.location != NSNotFound {
                text.addAttributes([
                    .foregroundColor: UIColor.searchHighlightText,
                    .backgroundColor: UIColor.searchHighlight,
                ], range: match)
            }
        }
        label.attributedText = text
        // the row draws the last component alone, at the indent its depth
        // gives it: read out, a name on its own says nothing about where
        // it sits, so the row is read as the whole path
        isAccessibilityElement = true
        accessibilityLabel = path
        accessibilityTraits = .staticText
    }
}
