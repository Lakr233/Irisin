//
//  Created by ktiays on 2025/1/27.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext
import MarkdownParser

/// `naturalWidths` stretched evenly to fill `availableWidth` less
/// `outerPadding` on each side, or as they are when they already fill it.
func fittedTableColumnWidths(
    _ naturalWidths: [CGFloat],
    to availableWidth: CGFloat,
    outerPadding: CGFloat
) -> [CGFloat] {
    guard !naturalWidths.isEmpty, availableWidth.isFinite, availableWidth > 0 else {
        return naturalWidths
    }

    let naturalWidth = naturalWidths.reduce(0, +)
    let minimumColumnsWidth = max(0, availableWidth - outerPadding * 2)
    let extraWidth = minimumColumnsWidth - naturalWidth
    guard extraWidth > 0 else { return naturalWidths }

    let extraWidthPerColumn = extraWidth / CGFloat(naturalWidths.count)
    var fittedWidths = naturalWidths.map { $0 + extraWidthPerColumn }
    if let lastIndex = fittedWidths.indices.last {
        fittedWidths[lastIndex] += minimumColumnsWidth - fittedWidths.reduce(0, +)
    }
    return fittedWidths
}

final class TableView: UIView {
    typealias Rows = [NSAttributedString]

    // MARK: - Constants

    let tableViewPadding: CGFloat = 2
    let layoutMetrics = TableLayoutMetrics.compact

    // MARK: - UI Components

    private lazy var scrollView: HorizontalClippingScrollView = .init()

    /// The border, title bar, row backgrounds and lines, which stay put
    /// while the columns scroll beneath them.
    private lazy var gridView: GridView = .init()

    /// The bar above the rows naming the table, with its buttons.
    lazy var titleLabel: TableTitleLabel = .init()
    lazy var copyControl: TableTapControl = makeTitleControl(
        symbol: TableSymbol.copy,
        title: TableTitleText.copy
    ) { [weak self] in self?.copyTable() }
    lazy var expandControl: TableTapControl = makeTitleControl(
        symbol: TableSymbol.expand,
        title: TableTitleText.expand
    ) { [weak self] in self?.openFullTable() }

    // MARK: - Properties

    /// Every row, header first, as given: what copying the table yields
    /// and what the full-table sheet shows.
    private(set) var contents: [Rows] = []
    private(set) var columnAlignments: [RawTableColumnAlignment] = []
    let mode: TableViewMode
    /// The rows drawn, picked from `contents`.
    private(set) var display = TableDisplay(contents: [], mode: .inline, sort: nil)
    /// The column the sheet is sorted by; always nil inline.
    private(set) var sort: TableSort?

    private var cellManager = TableViewCellManager()
    /// One view per column, holding that column's cells. A resize moves
    /// these rather than every cell: a cell keeps its place in its column's
    /// view however wide the column grows.
    private var columnViews: [UIView] = []
    private var widths: [CGFloat] = []
    private var heights: [CGFloat] = []
    private(set) var theme: MarkdownTheme = .default
    weak var textSelectionDelegate: TextLabelViewDelegate?
    var linkHandler: ((LinkPayload, NSRange, CGPoint) -> Void)?
    /// Opens the full table. Unset, the table presents it in a sheet.
    var expandHandler: ((TableView) -> Void)?
    /// Told after a sort changed what the table draws.
    var sortHandler: ((TableView) -> Void)?

    /// One per column in the sheet, over the header cell.
    private(set) var sortControls: [TableTapControl] = []
    /// The cells as one selection, row by row, so a drag can run from one
    /// cell into the next.
    let selectionGroup = TextSelectionGroup()
    /// Where each cell sits among the rows drawn.
    var cellPositions: [ObjectIdentifier: TableCellPosition] = [:]

    // MARK: - Computed Properties

    private var numberOfRows: Int {
        display.rows.count
    }

    /// Cells the last content change styled and measured again.
    var lastRestyledCellCount: Int {
        cellManager.lastRestyledCellCount
    }

    /// The cells drawn, row by row.
    var cellViews: [TextLabelView] {
        cellManager.cells
    }

    private var numberOfColumns: Int {
        contents.first?.count ?? 0
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        mode = .inline
        super.init(frame: frame)
        configureSubviews()
    }

    init(mode: TableViewMode) {
        self.mode = mode
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func configureSubviews() {
        configureSelectionGroup()
        addSubview(gridView)
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        addSubview(scrollView)
        if mode == .inline {
            for view in [titleLabel, copyControl, expandControl] as [UIView] {
                addSubview(view)
            }
        }
    }

    /// The view the cells and sort controls are added to: the scroll view
    /// itself on UIKit, its document view on AppKit.
    private var cellContainer: UIView {
        scrollView
    }

    /// How far the columns are scrolled from their start.
    private var scrollOffset: CGFloat {
        scrollView.contentOffset.x
    }

    /// Where the columns start: inside the border.
    private var columnsInset: CGFloat {
        tableViewPadding + theme.table.borderWidth
    }

    /// The title bar's height; a table in the sheet has none.
    var titleHeight: CGFloat {
        mode == .inline ? titleLabel.barHeight : 0
    }

    private var rowsHeight: CGFloat {
        heights.reduce(0, +)
    }

    func setContents(
        _ contents: [Rows],
        columnAlignments: [RawTableColumnAlignment] = []
    ) {
        // A `<br>` in a cell is already a line break here: the inline
        // renderer turns the tag into one, and leaves `<br>` written inside
        // code or escaped as text.
        guard !contentsEqual(self.contents, contents)
            || self.columnAlignments != columnAlignments
        else { return }
        self.contents = contents
        self.columnAlignments = columnAlignments
        configureCells()
        markNeedsLayout()
    }

    func setTheme(_ theme: MarkdownTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        updateThemeAppearance()
        guard !contents.isEmpty else { return }
        configureCells()
        markNeedsLayout()
    }

    private func updateThemeAppearance() {
        gridView.setTheme(theme)
        cellManager.setTheme(theme)
        titleLabel.setTheme(theme)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContent()
    }

    private func layoutContent() {
        let inset = columnsInset
        scrollView.frame = CGRect(
            x: inset,
            y: tableViewPadding + titleHeight,
            width: max(0, bounds.width - inset * 2),
            height: rowsHeight
        )
        let layoutWidths = fittedTableColumnWidths(
            widths,
            to: scrollView.frame.width,
            outerPadding: 0
        )
        let contentSize = CGSize(width: layoutWidths.reduce(0, +), height: rowsHeight)
        scrollView.contentSize = contentSize

        gridView.frame = bounds
        gridView.padding = tableViewPadding
        gridView.titleHeight = titleHeight
        gridView.columnsOrigin = inset
        gridView.update(widths: layoutWidths, heights: heights)
        gridView.setScrollOffset(scrollOffset)

        layoutCells(using: layoutWidths)
        layoutControls(using: layoutWidths)
        layoutTitleBar()
    }

    func interactionTarget(at point: CGPoint, event: UIEvent? = nil) -> UIView? {
        if let control = control(at: point) {
            return control
        }
        for cell in cellManager.cells.reversed() {
            let cellPoint = cell.convert(point, from: self)
            guard cell.bounds.contains(cellPoint) else { continue }
            if let target = cell.hitTest(cellPoint, with: event) {
                return target
            }
        }

        let scrollPoint = scrollView.convert(point, from: self)
        if scrollView.bounds.contains(scrollPoint),
           scrollView.contentSize.width > scrollView.bounds.width + 1
        {
            return scrollView
        }

        return nil
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled,
              !isHidden,
              alpha > 0.01,
              bounds.contains(point)
        else { return nil }

        return interactionTarget(at: point, event: event)
    }

    /// Keeps one view per column in the cell container, below the sort
    /// controls.
    private func configureColumnViews(count: Int) {
        while columnViews.count < count {
            let view = TableColumnView()
            if let control = sortControls.first {
                cellContainer.insertSubview(view, belowSubview: control)
            } else {
                cellContainer.addSubview(view)
            }
            columnViews.append(view)
        }
        while columnViews.count > count {
            columnViews.removeLast().removeFromSuperview()
        }
    }

    private func layoutCells(using layoutWidths: [CGFloat]) {
        guard !cellManager.cellSizes.isEmpty, !cellManager.cells.isEmpty else {
            return
        }
        guard layoutWidths.count == numberOfColumns, columnViews.count == numberOfColumns else {
            assertionFailure("Table layout width count must match its column count.")
            return
        }

        var rowOffsets: [CGFloat] = []
        var y: CGFloat = 0
        for height in heights {
            rowOffsets.append(y)
            y += height
        }

        var x: CGFloat = 0
        for column in 0 ..< numberOfColumns {
            let columnWidth = layoutWidths[column]
            let alignment = columnAlignments[safe: column] ?? .none
            let textWidth = max(0, columnWidth - layoutMetrics.horizontalCellPadding * 2)

            // A cell keeps the width its text was measured at rather than
            // the column's: a column stretched to fill the viewport then
            // never re-wraps a cell away from its row's height.
            let cells = (0 ..< numberOfRows).map { row in
                let cell = cellManager.cells[row * numberOfColumns + column]
                let accessoryWidth = row == 0
                    ? display.headerAccessoryWidths[safe: column] ?? 0
                    : 0
                let size = cell.intrinsicContentSize
                let width = min(ceil(size.width), max(0, textWidth - accessoryWidth))
                return (cell: cell, size: CGSize(width: width, height: ceil(size.height)), accessoryWidth: accessoryWidth)
            }

            // The column's view is as wide as its widest cell and takes the
            // column's alignment; each cell takes it again inside the view.
            // A resize then moves one view per column and none of the cells,
            // which AppKit would otherwise resize, re-constrain and redraw.
            let contentWidth = cells.map { $0.size.width + $0.accessoryWidth }.max() ?? 0
            columnViews[column].applyFrame(CGRect(
                x: x + layoutMetrics.horizontalCellPadding + Self.offset(of: alignment, in: textWidth - contentWidth),
                y: 0,
                width: contentWidth,
                height: y
            ))
            for (row, placement) in cells.enumerated() {
                let space = contentWidth - placement.accessoryWidth - placement.size.width
                placement.cell.applyFrame(CGRect(
                    origin: CGPoint(
                        x: Self.offset(of: alignment, in: space),
                        y: rowOffsets[row] + max(0, (heights[row] - placement.size.height) / 2)
                    ),
                    size: placement.size
                ))
            }
            x += columnWidth
        }
    }

    /// Where content aligned to `alignment` starts in `space` left over.
    private static func offset(of alignment: RawTableColumnAlignment, in space: CGFloat) -> CGFloat {
        switch alignment {
        case .center: space / 2
        case .right: space
        case .left, .none: 0
        }
    }

    // MARK: - Content Size

    var intrinsicContentHeight: CGFloat {
        ceil(titleHeight + rowsHeight) + tableViewPadding * 2
    }

    /// The width the columns need before any is stretched to fill the viewport.
    var naturalContentWidth: CGFloat {
        widths.reduce(0, +) + columnsInset * 2
    }

    override var intrinsicContentSize: CGSize {
        .init(
            width: Self.noIntrinsicMetric,
            height: intrinsicContentHeight
        )
    }

    // MARK: - Cell Configuration

    private func configureCells() {
        display = TableDisplay(contents: contents, mode: mode, sort: sort)
        cellManager.setTheme(theme)
        cellManager.setDelegate(self)
        configureColumnViews(count: display.rows.first?.count ?? 0)
        cellManager.configureCells(
            for: display.rows,
            columnAlignments: columnAlignments,
            headerAccessoryWidths: display.headerAccessoryWidths,
            in: columnViews,
            metrics: layoutMetrics
        )
        updateSelectionGroup()

        widths = cellManager.widths
        heights = cellManager.heights

        gridView.padding = tableViewPadding
        gridView.update(widths: widths, heights: heights)

        gridView.setHeaderRow(numberOfRows > 0)
        titleLabel.setHiddenRowCount(display.rowLimit.hiddenRowCount)
        configureControls(in: cellContainer)
    }

    /// Sorts the sheet by `sort`, or puts it back in source order for nil.
    func applySort(_ sort: TableSort?) {
        guard mode == .sheet, self.sort != sort else { return }
        self.sort = sort
        guard !contents.isEmpty else { return }
        configureCells()
        markNeedsLayout()
        sortHandler?(self)
    }

    /// What produced the cells this view is currently showing.
    ///
    /// Rendering a table means turning every cell's inline nodes into an
    /// attributed string, and a stream asks for that on every token even
    /// when the table itself has not changed since the last one. Comparing
    /// the source the cells came from lets the builder skip that work
    /// instead of doing it and then discovering it was not needed.
    private struct RenderedSource {
        let rows: [RawTableRow]
        let columnAlignments: [RawTableColumnAlignment]
        let theme: MarkdownTheme
        let localeIdentifier: String
        let representedText: NSAttributedString
    }

    private var renderedSource: RenderedSource?
    /// The parsed rows the cells were rendered from, which Copy writes back
    /// as Markdown. Nil for a table given only its rendered cells.
    private(set) var sourceRows: [RawTableRow]?

    /// The text standing in for this table, if it already shows `rows`.
    ///
    /// Cells also depend on the content's locale, which picks their
    /// fallback fonts.
    func representedText(
        reusingRows rows: [RawTableRow],
        columnAlignments: [RawTableColumnAlignment],
        theme: MarkdownTheme,
        content: MarkdownContent
    ) -> NSAttributedString? {
        guard let renderedSource,
              renderedSource.theme == theme,
              renderedSource.localeIdentifier == content.locale.identifier,
              renderedSource.columnAlignments == columnAlignments,
              renderedSource.rows == rows
        else { return nil }
        return renderedSource.representedText
    }

    func rememberRenderedSource(
        rows: [RawTableRow],
        columnAlignments: [RawTableColumnAlignment],
        theme: MarkdownTheme,
        content: MarkdownContent,
        representedText: NSAttributedString
    ) {
        sourceRows = rows
        renderedSource = .init(
            rows: rows,
            columnAlignments: columnAlignments,
            theme: theme,
            localeIdentifier: content.locale.identifier,
            representedText: representedText
        )
    }

    /// Drops the reuse record, so the next build renders the cells again
    /// even though the rows and the theme are the ones it already drew.
    /// What the cells rendered *to* can change without either of them
    /// moving — an inline decoration reading state this table cannot see.
    func forgetRenderedSource() {
        renderedSource = nil
    }

    private func contentsEqual(_ lhs: [Rows], _ rhs: [Rows]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for rowIndex in lhs.indices {
            guard lhs[rowIndex].count == rhs[rowIndex].count else { return false }
            for columnIndex in lhs[rowIndex].indices {
                guard lhs[rowIndex][columnIndex].isEqual(to: rhs[rowIndex][columnIndex]) else {
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - TextLabelViewDelegate

extension TableView: TextLabelViewDelegate {
    func textLabelView(_ label: TextLabelView, didChangeSelection selection: NSRange?) {
        textSelectionDelegate?.textLabelView(label, didChangeSelection: selection)
    }

    func textLabelView(_ label: TextLabelView, didDragSelectionAt location: CGPoint) {
        textSelectionDelegate?.textLabelView(label, didDragSelectionAt: location)
    }

    func textLabelView(_ label: TextLabelView, didTapHighlightRegion highlightRegion: TextLabel.HighlightRegion, at location: CGPoint) {
        let link = highlightRegion.attributes[NSAttributedString.Key.link]
        let range = highlightRegion.stringRange

        // Convert location from cell to MarkdownTextView coordinate system
        let locationInMarkdownView = superview.flatMap { label.convert(location, to: $0) } ?? location

        if let url = link as? URL {
            linkHandler?(.url(url), range, locationInMarkdownView)
        } else if let string = link as? String {
            linkHandler?(.string(string), range, locationInMarkdownView)
        }
    }
}

// MARK: - Scrolling

typealias TableColumnView = UIView

extension TableView: UIScrollViewDelegate {
    func scrollViewDidScroll(_: UIScrollView) {
        gridView.setScrollOffset(scrollOffset)
    }
}

// MARK: - Controls

extension TableView {
    /// The control under `point`, in the table's coordinates.
    private func control(at point: CGPoint) -> TableTapControl? {
        let titleControls = mode == .inline ? [copyControl, expandControl] : []
        return (titleControls + sortControls).first { control in
            guard !control.isHidden, control.superview != nil else { return false }
            return control.bounds.contains(control.convert(point, from: self))
        }
    }

    /// The theme the cells were last styled with.
    var currentTheme: MarkdownTheme {
        theme
    }

    /// Opens every row, through `expandHandler` when one is set.
    func openFullTable() {
        if let expandHandler {
            expandHandler(self)
        } else {
            TableSheetPresenter.present(self)
        }
    }

    /// Adds the controls this mode draws, sized to the current columns.
    private func configureControls(in container: UIView) {
        guard mode == .sheet else { return }
        while sortControls.count < numberOfColumns {
            let column = sortControls.count
            let control = TableTapControl()
            control.handler = { [weak self] in
                guard let self else { return }
                applySort(TableSort.next(afterTapping: column, current: sort))
            }
            container.addSubview(control)
            sortControls.append(control)
        }
        while sortControls.count > numberOfColumns {
            sortControls.removeLast().removeFromSuperview()
        }
        for (column, control) in sortControls.enumerated() {
            let direction = sort?.column == column ? sort?.direction : nil
            switch direction {
            case .ascending:
                control.setSymbol(TableSymbol.sortAscending)
            case .descending:
                control.setSymbol(TableSymbol.sortDescending)
            case nil:
                control.setSymbol(nil)
            }
            control.setAccessibleTitle(display.rows.first?[safe: column]?.string)
        }
    }

    /// Places the controls over the columns as laid out at `layoutWidths`.
    private func layoutControls(using layoutWidths: [CGFloat]) {
        guard mode == .sheet, let headerHeight = heights.first, layoutWidths.count == numberOfColumns else {
            return
        }
        var x: CGFloat = 0
        let headerFrames = layoutWidths.map { width -> CGRect in
            defer { x += width }
            return CGRect(x: x, y: 0, width: width, height: headerHeight)
        }
        for (column, control) in sortControls.enumerated() {
            guard let columnFrame = headerFrames[safe: column] else { continue }
            let slot = TableHeaderSlot(
                columnFrame: columnFrame,
                horizontalPadding: layoutMetrics.horizontalCellPadding,
                accessoryWidth: TableHeaderAccessory.width
            )
            control.applyFrame(columnFrame)
            control.glyphFrame = slot.glyphFrame.offsetBy(
                dx: -columnFrame.minX,
                dy: -columnFrame.minY
            )
        }
    }
}
