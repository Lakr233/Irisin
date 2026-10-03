//
//  TableSheetModel.swift
//  MarkdownView
//

import Foundation
import Litext
import MarkdownParser

/// The full table's cells, styled as the table in the document styles them
/// and measured once when the sheet opens; sorting and resizing only move
/// what is measured here.
@MainActor
struct TableSheetModel {
    /// One cell's styled text and the room it needs.
    struct Cell {
        let text: NSAttributedString
        /// The text's own height, which the cell centres in its row.
        let textHeight: CGFloat
    }

    let metrics: TableLayoutMetrics
    let header: [Cell]
    /// The rows under the header, in source order.
    let body: [[Cell]]
    let columnAlignments: [RawTableColumnAlignment]
    /// Each column's width before the columns are stretched to the viewport.
    let naturalWidths: [CGFloat]
    let headerHeight: CGFloat
    /// Each body row's height, in source order.
    let bodyHeights: [CGFloat]
    /// Each body row's cells as plain text, which sorting compares.
    let sortText: [[String]]

    var columnCount: Int {
        header.count
    }

    /// The widest a cell's text is laid out, less a header cell's glyph.
    func maximumTextWidth(isHeader: Bool) -> CGFloat {
        let accessory = isHeader ? TableHeaderAccessory.width : 0
        return max(1, metrics.maximumTextWidth - accessory)
    }

    init(content: TableSheetContent, metrics: TableLayoutMetrics) {
        self.metrics = metrics
        columnAlignments = content.columnAlignments
        let columnCount = content.contents.first?.count ?? 0
        let rows = content.contents.filter { $0.count == columnCount }
        let style = TableCellStyle(theme: content.theme)
        // `content` is not Sendable (its link handler is a plain closure), and
        // Xcode 26.6 rejects a Release build that captures it in `measure`:
        // "sending 'content' risks causing data races". The alignments are.
        let alignments = content.columnAlignments
        let sizer = MarkdownTextLabelView()
        var widths = Array(repeating: metrics.minimumColumnWidth, count: columnCount)

        func measure(_ row: [NSAttributedString], isHeader: Bool) -> (cells: [Cell], height: CGFloat) {
            let accessory = isHeader ? TableHeaderAccessory.width : 0
            sizer.preferredMaxLayoutWidth = max(1, metrics.maximumTextWidth - accessory)
            var height = metrics.minimumRowHeight
            let cells = row.enumerated().map { column, source in
                let text = style.styledText(
                    from: source,
                    isHeader: isHeader,
                    alignment: alignments[safe: column] ?? .none
                )
                sizer.attributedText = text
                let size = sizer.intrinsicContentSize
                let width = ceil(size.width) + accessory + metrics.horizontalCellPadding * 2
                widths[column] = max(widths[column], min(metrics.maximumColumnWidth, width))
                height = max(height, ceil(size.height) + metrics.verticalCellPadding * 2)
                return Cell(text: text, textHeight: ceil(size.height))
            }
            return (cells, height)
        }

        if let first = rows.first {
            let measured = measure(first, isHeader: true)
            header = measured.cells
            headerHeight = measured.height
        } else {
            header = []
            headerHeight = 0
        }
        var body: [[Cell]] = []
        var bodyHeights: [CGFloat] = []
        for row in rows.dropFirst() {
            let measured = measure(row, isHeader: false)
            body.append(measured.cells)
            bodyHeights.append(measured.height)
        }
        self.body = body
        self.bodyHeights = bodyHeights
        naturalWidths = widths
        sortText = rows.dropFirst().map { $0.map(\.string) }
    }

    /// The body rows in the order `sort` puts them, as source indices.
    func order(for sort: TableSort?) -> [Int] {
        sort?.order(of: sortText) ?? Array(body.indices)
    }

    /// The header's height, then each row's in `order`.
    func rowHeights(in order: [Int]) -> [CGFloat] {
        [headerHeight] + order.map { bodyHeights[$0] }
    }
}
