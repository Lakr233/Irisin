//
//  TableSheetViewController.swift
//  MarkdownView
//

import Litext
import UIKit

@MainActor
enum TableSheetPresenter {
    /// Presents every row of `tableView` in a full-height sheet over the
    /// view controller showing it.
    static func present(_ tableView: TableView) {
        guard let presenter = tableView.topPresentingViewController else { return }
        let controller = TableSheetViewController(content: TableSheetContent(tableView))
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        presenter.present(navigation, animated: true)
    }
}

/// Every row of a table in a collection view: one section per row, one
/// item per column, the header pinned while the rows scroll under it.
/// Tapping a header sorts by that column, and the rows slide into place.
final class TableSheetViewController: UIViewController, UICollectionViewDelegate {
    private typealias DataSource = UICollectionViewDiffableDataSource<Int, TableSheetItem>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<Int, TableSheetItem>

    let model: TableSheetModel
    private let content: TableSheetContent
    private let layout: TableSheetLayout
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var dataSource: DataSource?
    private(set) var sort: TableSort?
    /// The body rows as shown, as source indices.
    private(set) var order: [Int]
    private var fittedViewport: CGSize = .zero

    init(content: TableSheetContent) {
        self.content = content
        model = TableSheetModel(content: content, metrics: .compact)
        order = model.order(for: nil)
        layout = TableSheetLayout(table: content.theme.table)
        super.init(nibName: nil, bundle: nil)
        title = TableTitleText.table
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.isDirectionalLockEnabled = true
        collectionView.delegate = self
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(collectionView)
        configureDataSource()
        navigationItem.rightBarButtonItem = .sheetMenu(content.menuActions(
            from: { [weak self] in self?.view },
            close: { [weak self] in self?.dismiss(animated: true) }
        ))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitColumnsIfNeeded()
    }

    // MARK: - Data

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<TableSheetCell, TableSheetItem> {
            [weak self] cell, _, item in
            self?.configure(cell, for: item)
        }
        dataSource = DataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        dataSource?.apply(snapshot(), animatingDifferences: false)
    }

    /// The header section, then one section per body row in `order`.
    private func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        let columns = 0 ..< model.columnCount
        snapshot.appendSections([TableSheetItem.headerRow])
        snapshot.appendItems(columns.map { TableSheetItem(row: TableSheetItem.headerRow, column: $0) })
        for row in order {
            snapshot.appendSections([row])
            snapshot.appendItems(columns.map { TableSheetItem(row: row, column: $0) }, toSection: row)
        }
        return snapshot
    }

    private func configure(_ cell: TableSheetCell, for item: TableSheetItem) {
        let isHeader = item.row == TableSheetItem.headerRow
        let source = isHeader ? model.header[safe: item.column] : model.body[safe: item.row]?[safe: item.column]
        guard let source else { return }
        let padding = model.metrics.horizontalCellPadding
        let edge = layout.edgeInset
        cell.configure(.init(
            text: source.text,
            textHeight: source.textHeight,
            maximumTextWidth: model.maximumTextWidth(isHeader: isHeader),
            isHeader: isHeader,
            sortSymbol: isHeader ? sortSymbol(for: item.column) : nil,
            leadingInset: padding + (item.column == 0 ? edge : 0),
            trailingInset: padding + (item.column == model.columnCount - 1 ? edge : 0),
            theme: content.theme
        ))
        cell.label.delegate = isHeader ? nil : self
    }

    private func sortSymbol(for column: Int) -> String? {
        guard let sort, sort.column == column else { return nil }
        return sort.direction == .ascending ? TableSymbol.sortAscending : TableSymbol.sortDescending
    }

    // MARK: - Layout

    /// Stretches the columns to the visible width, once per width: the
    /// outer columns take the sheet's margins inside their backgrounds,
    /// so the text lines up with the navigation bar's.
    private func fitColumnsIfNeeded() {
        let insets = collectionView.adjustedContentInset
        let viewport = CGSize(
            width: collectionView.bounds.width - insets.left - insets.right,
            height: collectionView.bounds.height
        )
        guard viewport.width > 0, viewport.width != fittedViewport.width else { return }
        fittedViewport = viewport
        let edge = max(0, systemMinimumLayoutMargins.leading - model.metrics.horizontalCellPadding)
        let edgeChanged = edge != layout.edgeInset
        layout.edgeInset = edge
        layout.geometry = geometry(viewportWidth: viewport.width)
        if edgeChanged, var snapshot = dataSource?.snapshot() {
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            dataSource?.apply(snapshot, animatingDifferences: false)
        }
    }

    private func geometry(viewportWidth: CGFloat) -> TableSheetGeometry {
        TableSheetGeometry(
            columnWidths: TableSheetGeometry.columnWidths(
                natural: model.naturalWidths,
                viewportWidth: viewportWidth,
                edgeInset: layout.edgeInset
            ),
            rowHeights: model.rowHeights(in: order)
        )
    }

    // MARK: - Sorting

    func collectionView(_: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        indexPath.section == 0
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        applySort(TableSort.next(afterTapping: indexPath.item, current: sort))
    }

    /// Sorts by `newSort`, or back to source order for nil, moving each
    /// row to its new place rather than reloading the table.
    func applySort(_ newSort: TableSort?, animated: Bool = true) {
        sort = newSort
        order = model.order(for: newSort)
        if animated {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        var next = snapshot()
        // The header shows the new glyph; the rows only move.
        next.reconfigureItems(next.itemIdentifiers(inSection: TableSheetItem.headerRow))
        let width = fittedViewport.width
        let apply = {
            if width > 0 {
                self.layout.geometry = self.geometry(viewportWidth: width)
            }
            self.dataSource?.apply(next, animatingDifferences: animated)
        }
        if animated {
            apply()
        } else {
            UIView.performWithoutAnimation(apply)
        }
    }
}

extension TableSheetViewController: TextLabelViewDelegate {
    func textLabelView(_: TextLabelView, didChangeSelection _: NSRange?) {}

    func textLabelView(_: TextLabelView, didDragSelectionAt _: CGPoint) {}

    func textLabelView(
        _ label: TextLabelView,
        didTapHighlightRegion highlightRegion: TextLabel.HighlightRegion,
        at location: CGPoint
    ) {
        let link = highlightRegion.attributes[NSAttributedString.Key.link]
        let range = highlightRegion.stringRange
        let point = label.convert(location, to: view)
        if let url = link as? URL {
            content.linkHandler?(.url(url), range, point)
        } else if let string = link as? String {
            content.linkHandler?(.string(string), range, point)
        }
    }
}

/// One cell of the full table: its source row, or the header, and column.
struct TableSheetItem: Hashable {
    static let headerRow = -1

    let row: Int
    let column: Int
}

// MARK: - Layout

/// Places the cells from a ``TableSheetGeometry``, the header row pinned
/// to the top of the viewport. Under the cells it lays the row stripes
/// and the lines between rows, which belong to positions rather than to
/// rows, so a sort slides the text and leaves the stripes in place.
final class TableSheetLayout: UICollectionViewLayout {
    static let stripeKind = "TableSheetStripe"
    static let separatorKind = "TableSheetSeparator"

    var geometry: TableSheetGeometry = .empty {
        didSet {
            guard geometry != oldValue else { return }
            invalidateLayout()
        }
    }

    /// Extra room before the first column and after the last.
    var edgeInset: CGFloat = 0

    private let table: MarkdownTheme.Table

    init(table: MarkdownTheme.Table) {
        self.table = table
        super.init()
        register(TableSheetDecorationView.self, forDecorationViewOfKind: Self.stripeKind)
        register(TableSheetDecorationView.self, forDecorationViewOfKind: Self.separatorKind)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var collectionViewContentSize: CGSize {
        geometry.contentSize
    }

    /// Where the header row sits: the top of the visible area.
    private var viewportTop: CGFloat {
        guard let collectionView else { return 0 }
        return collectionView.contentOffset.y + collectionView.adjustedContentInset.top
    }

    private var hairline: CGFloat {
        1 / max(1, collectionView?.traitCollection.displayScale ?? 2)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard geometry.rowCount > 0 else { return [] }
        let columns = geometry.columns(in: rect)
        var attributes: [UICollectionViewLayoutAttributes] = []
        for row in geometry.bodyRows(in: rect) {
            for column in columns {
                attributes.append(cellAttributes(row: row, column: column))
            }
            if row % 2 == 0 {
                attributes.append(stripeAttributes(row: row))
            }
            attributes.append(separatorAttributes(row: row))
        }
        for column in columns {
            attributes.append(cellAttributes(row: 0, column: column))
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section < geometry.rowCount, indexPath.item < geometry.columnCount else { return nil }
        return cellAttributes(row: indexPath.section, column: indexPath.item)
    }

    override func layoutAttributesForDecorationView(
        ofKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section > 0, indexPath.section < geometry.rowCount else { return nil }
        return kind == Self.stripeKind
            ? stripeAttributes(row: indexPath.section)
            : separatorAttributes(row: indexPath.section)
    }

    /// Scrolling moves the pinned header, so every scroll asks again;
    /// only the header's attributes change unless the size did.
    override func shouldInvalidateLayout(forBoundsChange _: CGRect) -> Bool {
        true
    }

    override func invalidationContext(
        forBoundsChange newBounds: CGRect
    ) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard let collectionView, newBounds.size == collectionView.bounds.size else { return context }
        context.invalidateItems(at: (0 ..< geometry.columnCount).map { IndexPath(item: $0, section: 0) })
        return context
    }

    private func cellAttributes(row: Int, column: Int) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: column, section: row))
        if row == 0 {
            attributes.frame = geometry.headerFrame(column: column, viewportTop: viewportTop)
            attributes.zIndex = 2
        } else {
            attributes.frame = geometry.frame(row: row, column: column)
            attributes.zIndex = 1
        }
        return attributes
    }

    private func stripeAttributes(row: Int) -> UICollectionViewLayoutAttributes {
        let attributes = TableSheetDecorationAttributes(
            forDecorationViewOfKind: Self.stripeKind,
            with: IndexPath(item: 0, section: row)
        )
        attributes.frame = geometry.rowFrame(row)
        attributes.color = table.stripeCellBackgroundColor
        attributes.zIndex = 0
        return attributes
    }

    private func separatorAttributes(row: Int) -> UICollectionViewLayoutAttributes {
        let attributes = TableSheetDecorationAttributes(
            forDecorationViewOfKind: Self.separatorKind,
            with: IndexPath(item: 0, section: row)
        )
        let frame = geometry.rowFrame(row)
        attributes.frame = CGRect(x: frame.minX, y: frame.maxY - hairline, width: frame.width, height: hairline)
        attributes.color = table.borderColor
        attributes.zIndex = 0
        return attributes
    }
}

/// A decoration's attributes carry its colour from the theme.
final class TableSheetDecorationAttributes: UICollectionViewLayoutAttributes {
    /// Read by `isEqual(_:)`, which is not on the main actor; the layout
    /// sets it once, before anything compares it.
    nonisolated(unsafe) var color: UIColor = .clear

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        (copy as? TableSheetDecorationAttributes)?.color = color
        return copy
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableSheetDecorationAttributes, other.color == color else { return false }
        return super.isEqual(object)
    }
}

/// A row stripe or the line under a row.
final class TableSheetDecorationView: UICollectionReusableView {
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        backgroundColor = (layoutAttributes as? TableSheetDecorationAttributes)?.color
    }
}

// MARK: - Cell

/// One cell's text, centred in its row; a header cell adds its sort
/// glyph, an opaque background the rows scroll under, and the line below.
final class TableSheetCell: UICollectionViewCell {
    struct Configuration {
        let text: NSAttributedString
        let textHeight: CGFloat
        let maximumTextWidth: CGFloat
        let isHeader: Bool
        let sortSymbol: String?
        let leadingInset: CGFloat
        let trailingInset: CGFloat
        let theme: MarkdownTheme
    }

    let label = MarkdownTextLabelView()
    private let glyphView = UIImageView()
    private let headerBackground = UIView()
    private let headerSeparator = UIView()
    private var configuration: Configuration?

    override init(frame: CGRect) {
        super.init(frame: frame)
        headerBackground.isHidden = true
        headerSeparator.isHidden = true
        contentView.addSubview(headerBackground)
        label.backgroundColor = .clear
        contentView.addSubview(label)
        glyphView.contentMode = .center
        glyphView.tintColor = .secondaryLabel
        contentView.addSubview(glyphView)
        contentView.addSubview(headerSeparator)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ configuration: Configuration) {
        self.configuration = configuration
        let table = configuration.theme.table
        if label.preferredMaxLayoutWidth != configuration.maximumTextWidth {
            label.preferredMaxLayoutWidth = configuration.maximumTextWidth
        }
        if !label.attributedText.isEqual(to: configuration.text) {
            label.attributedText = configuration.text
        }
        label.isSelectable = !configuration.isHeader
        label.isUserInteractionEnabled = !configuration.isHeader
        label.selectionBackgroundColor = configuration.theme.colors.selectionBackground
        // Opaque, so rows scrolling under the pinned header stay hidden.
        backgroundColor = configuration.isHeader ? .systemBackground : .clear
        headerBackground.isHidden = !configuration.isHeader
        headerBackground.backgroundColor = table.headerBackgroundColor
        headerSeparator.isHidden = !configuration.isHeader
        headerSeparator.backgroundColor = table.borderColor
        glyphView.image = configuration.sortSymbol.flatMap {
            UIImage(
                systemName: $0,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: TableHeaderAccessory.glyphSize - 2, weight: .semibold)
            )
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let configuration else { return }
        let bounds = contentView.bounds
        let accessory = configuration.isHeader ? TableHeaderAccessory.width : 0
        let minX = configuration.leadingInset
        let maxX = max(minX, bounds.width - configuration.trailingInset)
        label.frame = CGRect(
            x: minX,
            y: (bounds.height - configuration.textHeight) / 2,
            width: max(0, maxX - minX - accessory),
            height: configuration.textHeight
        )
        let glyph = TableHeaderAccessory.glyphSize
        glyphView.frame = CGRect(x: maxX - glyph, y: bounds.midY - glyph / 2, width: glyph, height: glyph)
        headerBackground.frame = bounds
        let hairline = 1 / max(1, traitCollection.displayScale)
        headerSeparator.frame = CGRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.delegate = nil
        label.selectionRange = nil
    }
}
