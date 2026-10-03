//
//  TableSheetGeometry.swift
//  MarkdownView
//

import CoreGraphics

/// Where every cell of the full table sits.
///
/// Columns run left to right and rows top to bottom in the order shown, the
/// header first. The header row stays pinned to the top of the viewport
/// while the rows scroll under it. Lookups by rect are binary searches, so a
/// table of thousands of rows costs only the rows on screen.
struct TableSheetGeometry: Equatable {
    let columnWidths: [CGFloat]
    /// The header's height, then each row's in the order shown.
    let rowHeights: [CGFloat]
    private let columnOffsets: [CGFloat]
    private let rowOffsets: [CGFloat]

    init(columnWidths: [CGFloat], rowHeights: [CGFloat]) {
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
        columnOffsets = Self.offsets(of: columnWidths)
        rowOffsets = Self.offsets(of: rowHeights)
    }

    static let empty = TableSheetGeometry(columnWidths: [], rowHeights: [])

    /// Natural column widths fitted to `viewportWidth`, with `edgeInset`
    /// added before the first column and after the last, so the outer
    /// columns' text lines up with the sheet's margins while their
    /// backgrounds reach its edges.
    static func columnWidths(
        natural: [CGFloat],
        viewportWidth: CGFloat,
        edgeInset: CGFloat
    ) -> [CGFloat] {
        guard !natural.isEmpty else { return [] }
        var widths = fittedTableColumnWidths(
            natural,
            to: max(0, viewportWidth - edgeInset * 2),
            outerPadding: 0
        )
        widths[0] += edgeInset
        widths[widths.count - 1] += edgeInset
        return widths
    }

    var contentSize: CGSize {
        CGSize(width: columnOffsets.last ?? 0, height: rowOffsets.last ?? 0)
    }

    var columnCount: Int {
        columnWidths.count
    }

    var rowCount: Int {
        rowHeights.count
    }

    /// The cell at `row` and `column` where it sits in the content.
    func frame(row: Int, column: Int) -> CGRect {
        CGRect(
            x: columnOffsets[column],
            y: rowOffsets[row],
            width: columnWidths[column],
            height: rowHeights[row]
        )
    }

    /// The whole of `row`, every column.
    func rowFrame(_ row: Int) -> CGRect {
        CGRect(x: 0, y: rowOffsets[row], width: contentSize.width, height: rowHeights[row])
    }

    /// The header cell of `column`, held at `viewportTop` once the content
    /// has scrolled past it; pulled down past the top, it moves with the rows.
    func headerFrame(column: Int, viewportTop: CGFloat) -> CGRect {
        var frame = frame(row: 0, column: column)
        frame.origin.y = max(0, viewportTop)
        return frame
    }

    /// The rows after the header that reach into `rect`.
    func bodyRows(in rect: CGRect) -> Range<Int> {
        guard rowCount > 1, !rect.isEmpty else { return 1 ..< 1 }
        let first = max(1, Self.index(in: rowOffsets, at: rect.minY))
        let last = Self.index(in: rowOffsets, at: rect.maxY)
        return first ..< max(first, last + 1)
    }

    /// The columns that reach into `rect`.
    func columns(in rect: CGRect) -> Range<Int> {
        guard columnCount > 0, !rect.isEmpty else { return 0 ..< 0 }
        let first = Self.index(in: columnOffsets, at: rect.minX)
        let last = Self.index(in: columnOffsets, at: rect.maxX)
        return first ..< last + 1
    }

    /// The span holding `value`: the last `i` whose start `offsets[i]` is at
    /// or before it, clamped to the spans there are.
    private static func index(in offsets: [CGFloat], at value: CGFloat) -> Int {
        var low = 0
        var high = offsets.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= value {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Each span's start, then the end of the last.
    private static func offsets(of sizes: [CGFloat]) -> [CGFloat] {
        var offsets: [CGFloat] = [0]
        offsets.reserveCapacity(sizes.count + 1)
        for size in sizes {
            offsets.append(offsets[offsets.count - 1] + size)
        }
        return offsets
    }
}
