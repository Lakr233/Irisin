//
//  TableViewCellManager.swift
//  MarkdownView
//
//  Created by ktiays on 2025/1/27.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Litext
import MarkdownParser
import UIKit

struct TableLayoutMetrics: Equatable {
    let minimumColumnWidth: CGFloat
    let maximumColumnWidth: CGFloat
    let horizontalCellPadding: CGFloat
    let verticalCellPadding: CGFloat
    let minimumRowHeight: CGFloat

    static let compact = TableLayoutMetrics(
        minimumColumnWidth: 88,
        maximumColumnWidth: 280,
        horizontalCellPadding: 9,
        verticalCellPadding: 7,
        minimumRowHeight: 38
    )

    static let regular = TableLayoutMetrics(
        minimumColumnWidth: 96,
        maximumColumnWidth: 320,
        horizontalCellPadding: 10,
        verticalCellPadding: 8,
        minimumRowHeight: 38
    )

    var maximumTextWidth: CGFloat {
        maximumColumnWidth - horizontalCellPadding * 2
    }

    func validate() {
        precondition(minimumColumnWidth >= 0)
        precondition(maximumColumnWidth >= minimumColumnWidth)
        precondition(horizontalCellPadding >= 0)
        precondition(verticalCellPadding >= 0)
        precondition(minimumRowHeight >= 0)
        precondition(maximumTextWidth > 0)
    }
}

@MainActor
final class TableViewCellManager {
    /// What a cell was last styled and measured from.
    ///
    /// A streamed table is configured again on every token, and all but
    /// the cell being typed come back unchanged. A cell whose record
    /// matches keeps its text and its measured size; only the others are
    /// styled and laid out again.
    private struct CellRecord {
        let source: NSAttributedString
        let isHeader: Bool
        let alignment: RawTableColumnAlignment
        let maximumTextWidth: CGFloat
        let accessoryWidth: CGFloat
        let size: CGSize

        func matches(
            _ source: NSAttributedString,
            isHeader: Bool,
            alignment: RawTableColumnAlignment,
            maximumTextWidth: CGFloat,
            accessoryWidth: CGFloat
        ) -> Bool {
            self.isHeader == isHeader
                && self.alignment == alignment
                && self.maximumTextWidth == maximumTextWidth
                && self.accessoryWidth == accessoryWidth
                && (self.source === source || self.source.isEqual(to: source))
        }
    }

    // MARK: - Properties

    private(set) var cells: [TextLabelView] = []
    private var records: [CellRecord?] = []
    private(set) var cellSizes: [CGSize] = []
    private(set) var widths: [CGFloat] = []
    private(set) var heights: [CGFloat] = []
    private var theme: MarkdownTheme = .default
    private weak var delegate: TextLabelViewDelegate?
    private var numberOfColumns = 0
    /// Cells the last configuration styled and measured again; the rest
    /// were already showing their content.
    private(set) var lastRestyledCellCount = 0

    // MARK: - Cell Configuration

    /// Lays `contents` out one cell per entry, row by row.
    ///
    /// `headerAccessoryWidths[column]` is space the header cell of
    /// `column` leaves free at its trailing edge, counted into the
    /// column's width. Each cell is added to its column's view in
    /// `columnViews`.
    func configureCells(
        for contents: [[NSAttributedString]],
        columnAlignments: [RawTableColumnAlignment] = [],
        headerAccessoryWidths: [CGFloat] = [],
        in columnViews: [UIView],
        metrics: TableLayoutMetrics
    ) {
        metrics.validate()

        let numberOfRows = contents.count
        let numberOfColumns = contents.first?.count ?? 0
        guard contents.allSatisfy({ $0.count == numberOfColumns }) else {
            assertionFailure("Markdown table rows must have a consistent column count.")
            resetLayout()
            return
        }
        guard columnViews.count >= numberOfColumns else {
            assertionFailure("Every Markdown table column needs a view for its cells.")
            resetLayout()
            return
        }

        let (requiredCellCount, countOverflow) = numberOfRows.multipliedReportingOverflow(
            by: numberOfColumns
        )
        guard !countOverflow else {
            assertionFailure("Markdown table cell count overflowed Int.")
            resetLayout()
            return
        }
        // A cell's index is its row times the column count, so a new
        // column count moves every cell; nothing recorded still applies.
        if numberOfColumns != self.numberOfColumns {
            records = Array(repeating: nil, count: records.count)
            self.numberOfColumns = numberOfColumns
        }
        cellSizes = Array(repeating: .zero, count: requiredCellCount)
        widths = Array(repeating: 0, count: numberOfColumns)
        heights = Array(repeating: 0, count: numberOfRows)
        trimSurplusCells(keeping: requiredCellCount)
        lastRestyledCellCount = 0

        for (row, rowContent) in contents.enumerated() {
            var rowHeight = metrics.minimumRowHeight

            for (column, cellString) in rowContent.enumerated() {
                let index = row * numberOfColumns + column
                let isHeader = row == 0
                let accessoryWidth = isHeader
                    ? max(0, headerAccessoryWidths[safe: column] ?? 0)
                    : 0
                let cellSize = createOrUpdateCell(
                    at: index,
                    with: cellString,
                    isHeader: isHeader,
                    alignment: columnAlignments[safe: column] ?? .none,
                    accessoryWidth: accessoryWidth,
                    metrics: metrics,
                    in: columnViews[column]
                )
                cellSizes[index] = cellSize
                rowHeight = max(rowHeight, cellSize.height)
                widths[column] = max(widths[column], cellSize.width)
            }

            heights[row] = rowHeight
        }
    }

    // MARK: - Public Methods

    /// Takes `theme` for the cells configured next. Every cell is styled
    /// and measured again then, since fonts and colours come from it.
    func setTheme(_ theme: MarkdownTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        records = Array(repeating: nil, count: records.count)
        cells.forEach { $0.selectionBackgroundColor = theme.colors.selectionBackground }
    }

    func setDelegate(_ delegate: TextLabelViewDelegate?) {
        self.delegate = delegate
        cells.forEach { $0.delegate = delegate }
    }

    // MARK: - Private Methods

    /// Brings the cell at `index` up to `attributedText` and returns its
    /// padded size, styling and measuring it only when what it was last
    /// built from differs.
    private func createOrUpdateCell(
        at index: Int,
        with attributedText: NSAttributedString,
        isHeader: Bool,
        alignment: RawTableColumnAlignment,
        accessoryWidth: CGFloat,
        metrics: TableLayoutMetrics,
        in containerView: UIView
    ) -> CGSize {
        let cell: TextLabelView

        if index >= cells.count {
            cell = MarkdownTextLabelView()
            cell.backgroundColor = .clear
            cell.selectionBackgroundColor = theme.colors.selectionBackground
            cell.delegate = delegate
            cell.isSelectable = true
            cells.append(cell)
            records.append(nil)
        } else {
            cell = cells[index]
        }
        // A new column count moves a kept cell into another column.
        if cell.superview !== containerView {
            containerView.addSubview(cell)
        }

        // The header cell gives up its accessory's width, and the column
        // still stays within the maximum.
        let maximumTextWidth = max(1, metrics.maximumTextWidth - accessoryWidth)
        if let record = records[index], record.matches(
            attributedText,
            isHeader: isHeader,
            alignment: alignment,
            maximumTextWidth: maximumTextWidth,
            accessoryWidth: accessoryWidth
        ) {
            return record.size
        }

        lastRestyledCellCount += 1
        let styledText = TableCellStyle(theme: theme).styledText(
            from: attributedText,
            isHeader: isHeader,
            alignment: alignment
        )
        cell.isSelectable = true
        if cell.preferredMaxLayoutWidth != maximumTextWidth {
            cell.preferredMaxLayoutWidth = maximumTextWidth
        }
        if !cell.attributedText.isEqual(to: styledText) {
            cell.attributedText = styledText
        }
        let size = calculateCellSize(for: cell, accessoryWidth: accessoryWidth, metrics: metrics)
        records[index] = CellRecord(
            source: attributedText.copy() as? NSAttributedString ?? attributedText,
            isHeader: isHeader,
            alignment: alignment,
            maximumTextWidth: maximumTextWidth,
            accessoryWidth: accessoryWidth,
            size: size
        )
        return size
    }

    private func trimSurplusCells(keeping requiredCellCount: Int) {
        guard cells.count > requiredCellCount else { return }
        for index in stride(from: cells.count - 1, through: requiredCellCount, by: -1) {
            cells[index].removeFromSuperview()
            cells.remove(at: index)
            if index < records.count {
                records.remove(at: index)
            }
        }
    }

    private func resetLayout() {
        trimSurplusCells(keeping: 0)
        records.removeAll()
        cellSizes.removeAll()
        widths.removeAll()
        heights.removeAll()
        numberOfColumns = 0
    }

    private func calculateCellSize(
        for cell: TextLabelView,
        accessoryWidth: CGFloat,
        metrics: TableLayoutMetrics
    ) -> CGSize {
        let contentSize = cell.intrinsicContentSize
        let paddedWidth = ceil(contentSize.width) + accessoryWidth + metrics.horizontalCellPadding * 2
        let paddedHeight = ceil(contentSize.height) + metrics.verticalCellPadding * 2
        return CGSize(
            width: min(
                metrics.maximumColumnWidth,
                max(metrics.minimumColumnWidth, paddedWidth)
            ),
            height: max(metrics.minimumRowHeight, paddedHeight)
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
