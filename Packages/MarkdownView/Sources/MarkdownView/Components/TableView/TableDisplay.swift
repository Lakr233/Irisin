//
//  TableDisplay.swift
//  MarkdownView
//

import Foundation

/// Where a table is drawn, which decides what of it is drawn.
enum TableViewMode: Equatable {
    /// In the document: every row, or the first rows of a very long table.
    case inline
    /// In the full-table sheet: every row, sortable by column.
    case sheet
}

/// The rows a table draws, picked from all of its rows.
///
/// A table keeps every row it was given — copying it yields all of them — and
/// draws this selection: the first rows inline, every row in the sheet, in
/// the sort order picked there.
struct TableDisplay {
    /// The header, then the content rows drawn.
    let rows: [[NSAttributedString]]
    let rowLimit: TableRowLimit
    /// Trailing space each header cell leaves for a control.
    let headerAccessoryWidths: [CGFloat]
    /// For each drawn content row, its index among all content rows.
    let sourceRowIndices: [Int]

    @MainActor
    init(contents: [[NSAttributedString]], mode: TableViewMode, sort: TableSort?) {
        let columnCount = contents.first?.count ?? 0
        switch mode {
        case .inline:
            rowLimit = TableRowLimit(rowCount: contents.count)
            rows = rowLimit.visibleRows(of: contents)
            sourceRowIndices = Array(0 ..< rowLimit.visibleRowCount)
            headerAccessoryWidths = Array(repeating: 0, count: columnCount)
        case .sheet:
            rowLimit = TableRowLimit(rowCount: contents.count, truncationThreshold: .max)
            let body = Array(contents.dropFirst())
            let order = sort?.order(of: body.map { $0.map(\.string) }) ?? Array(body.indices)
            sourceRowIndices = order
            rows = contents.isEmpty ? [] : [contents[0]] + order.map { body[$0] }
            headerAccessoryWidths = Array(repeating: TableHeaderAccessory.width, count: columnCount)
        }
    }
}

/// Where a header cell's text and its trailing control go within its column.
struct TableHeaderSlot: Equatable {
    /// The header text, inside the cell padding and clear of the glyph.
    let textFrame: CGRect
    /// The glyph, at the trailing edge inside the cell padding.
    let glyphFrame: CGRect

    init(columnFrame: CGRect, horizontalPadding: CGFloat, accessoryWidth: CGFloat) {
        let contentMinX = columnFrame.minX + horizontalPadding
        let contentMaxX = max(contentMinX, columnFrame.maxX - horizontalPadding)
        let textMaxX = max(contentMinX, contentMaxX - accessoryWidth)
        textFrame = CGRect(
            x: contentMinX,
            y: columnFrame.minY,
            width: textMaxX - contentMinX,
            height: columnFrame.height
        )
        let glyph = TableHeaderAccessory.glyphSize
        glyphFrame = CGRect(
            x: contentMaxX - glyph,
            y: columnFrame.midY - glyph / 2,
            width: glyph,
            height: glyph
        )
    }
}
