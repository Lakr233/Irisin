//
//  TableRowLimit.swift
//  MarkdownView
//

import Foundation

/// How many of a table's rows are drawn inline.
///
/// A very long table in a chat answer pushes everything after it off screen,
/// and every one of its cells costs a layout on every streamed token. Past
/// `truncationThreshold` content rows, the inline table keeps its header and
/// the first rows in source order and leaves the rest out; copying the table
/// still yields every row.
struct TableRowLimit: Equatable {
    /// Content rows a table may have and still be drawn whole.
    static let truncationThreshold = 100
    /// Content rows drawn inline once a table passes the threshold.
    static let maximumVisibleRows = 20

    /// Content rows drawn inline: the first ones, in source order.
    let visibleRowCount: Int
    /// Content rows left out, all of them after the visible ones.
    let hiddenRowCount: Int

    /// `rowCount` counts every row, header included.
    init(
        rowCount: Int,
        truncationThreshold: Int = Self.truncationThreshold,
        maximumVisibleRows: Int = Self.maximumVisibleRows
    ) {
        let contentRows = max(0, rowCount - 1)
        visibleRowCount = contentRows > truncationThreshold
            ? min(contentRows, max(0, maximumVisibleRows))
            : contentRows
        hiddenRowCount = contentRows - visibleRowCount
    }

    var isTruncated: Bool {
        hiddenRowCount > 0
    }

    /// The rows drawn inline: the header and the first visible rows.
    func visibleRows<Row>(of rows: [Row]) -> [Row] {
        Array(rows.prefix(rows.isEmpty ? 0 : 1 + visibleRowCount))
    }
}

/// The SF Symbols the table's controls draw.
enum TableSymbol {
    static let copy = "doc.on.doc"
    static let copied = "checkmark"
    static let download = "arrow.down"
    /// Outward arrows to the bottom left and top right: open in full. The
    /// symbol is newer than the oldest systems this ships on, which get the
    /// other diagonal.
    static var expand: String {
        if #available(iOS 17, macCatalyst 17, macOS 14, visionOS 1, *) {
            "arrow.down.left.and.arrow.up.right"
        } else {
            "arrow.up.left.and.arrow.down.right"
        }
    }

    static let sortAscending = "chevron.up"
    static let sortDescending = "chevron.down"
}

/// Space a header cell gives up at its trailing edge for a control drawn there.
///
/// The column is measured with it, so the control never sits on header text.
enum TableHeaderAccessory {
    /// The glyph's box.
    static let glyphSize: CGFloat = 14
    /// Between the header text and the glyph.
    static let spacing: CGFloat = 6

    static var width: CGFloat {
        glyphSize + spacing
    }
}
