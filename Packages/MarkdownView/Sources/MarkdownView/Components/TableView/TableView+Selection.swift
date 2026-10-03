//
//  TableView+Selection.swift
//  MarkdownView
//

import Litext
import UIKit

/// A cell's place among the rows a table draws, header first.
struct TableCellPosition: Equatable {
    let row: Int
    let column: Int
}

extension TableView {
    /// Joins the cells of a row with a tab and rows with a line break, so
    /// copied cells paste into a spreadsheet in place.
    func configureSelectionGroup() {
        selectionGroup.delegate = self
        selectionGroup.separator = { [weak self] previous, next in
            let positions = self?.cellPositions
            let previousRow = positions?[ObjectIdentifier(previous)]?.row
            let nextRow = positions?[ObjectIdentifier(next)]?.row
            return previousRow != nil && previousRow == nextRow ? "\t" : "\n"
        }
    }

    /// Puts the cells drawn into the group, in reading order.
    ///
    /// The group is only given a new list when the cells themselves change,
    /// since that clears its selection. A stream that edits a cell's text
    /// keeps the cells, so a selection elsewhere in the table survives it.
    func updateSelectionGroup() {
        let cells = cellViews
        let columns = max(1, display.rows.first?.count ?? 1)
        cellPositions = Dictionary(
            uniqueKeysWithValues: cells.enumerated().map { index, cell in
                (ObjectIdentifier(cell), TableCellPosition(row: index / columns, column: index % columns))
            }
        )
        guard !selectionGroup.labels.elementsEqual(cells, by: ===) else { return }
        selectionGroup.labels = cells
    }

    /// The selected cells as a Markdown table.
    ///
    /// It spans the columns the selection touches. A selection that starts
    /// below the header still gets the header of those columns, so what is
    /// pasted is a table; a cell the selection skips is left empty.
    func selectedMarkdown() -> String? {
        var selected: [Int: [Int: String]] = [:]
        for segment in selectionGroup.selectedSegments {
            guard let position = cellPositions[ObjectIdentifier(segment.label)] else { continue }
            // A whole cell is written back from its source, keeping links and
            // code; part of one can only be the text it shows.
            let wholeCell = segment.range.location == 0 && segment.range.length == segment.label.attributedText.length
            let text = (wholeCell ? sourceMarkdown(atDisplayRow: position.row, column: position.column) : nil)
                ?? segment.label.selectedAttributedText().map(TableExport.plainText)
                ?? ""
            selected[position.row, default: [:]][position.column] = text
        }
        let columns = selected.values.flatMap(\.keys)
        guard let firstColumn = columns.min(), let lastColumn = columns.max() else { return nil }
        let columnRange = firstColumn ... lastColumn

        var rows = selected.keys.sorted().map { row in
            columnRange.map { selected[row]?[$0] ?? "" }
        }
        if selected[0] == nil, let header = display.rows.first {
            rows.insert(columnRange.map { column in
                sourceMarkdown(atDisplayRow: 0, column: column)
                    ?? header[safe: column].map(TableExport.plainText)
                    ?? ""
            }, at: 0)
        }

        let alignments = columnRange.map { columnAlignments[safe: $0] ?? .none }
        return TableExport.markdown(rows: rows, alignments: alignments)
    }

    /// The Markdown a drawn cell was parsed from, or nil for a table given
    /// only its rendered cells.
    func sourceMarkdown(atDisplayRow row: Int, column: Int) -> String? {
        let sourceRow = row == 0 ? 0 : display.sourceRowIndices[safe: row - 1].map { $0 + 1 }
        guard let sourceRow, let cell = sourceRows?[safe: sourceRow]?.cells[safe: column] else { return nil }
        return TableExport.markdownSource(cell.content)
    }

    fileprivate static var copyAsMarkdownTitle: String {
        String(
            localized: "Copy as Markdown",
            comment: "Menu command that copies the selected table cells as a Markdown table."
        )
    }
}

// MARK: - TextSelectionGroupDelegate

extension TableView: TextSelectionGroupDelegate {
    func textSelectionGroup(
        _: TextSelectionGroup,
        didDragSelectionIn label: TextLabelView,
        at location: CGPoint
    ) {
        scrollHorizontally(toFollowDragAt: location, in: label)
        textSelectionDelegate?.textLabelView(label, didDragSelectionAt: location)
    }

    @available(iOS 16.0, macCatalyst 16.0, visionOS 1.0, *)
    func textSelectionGroup(
        _: TextSelectionGroup,
        editMenuForSuggestedActions suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let copyAsMarkdown = UIAction(
            title: Self.copyAsMarkdownTitle,
            image: UIImage(systemName: "tablecells")
        ) { [weak self] _ in
            guard let markdown = self?.selectedMarkdown() else { return }
            UIPasteboard.general.string = markdown
        }
        return UIMenu(children: suggestedActions + [copyAsMarkdown])
    }
}

// MARK: - Horizontal Autoscroll

private let dragEdgeWidth: CGFloat = 16

private extension TableView {
    /// Scrolls the columns sideways while a drag runs past either edge.
    func scrollHorizontally(toFollowDragAt location: CGPoint, in label: TextLabelView) {
        guard let scrollView = sequence(first: label, next: \.superview)
            .lazy.compactMap({ $0 as? UIScrollView }).first,
            scrollView.contentSize.width > scrollView.bounds.width
        else { return }
        let point = label.convert(location, to: scrollView)
        let visible = scrollView.bounds.insetBy(dx: dragEdgeWidth, dy: 0)
        var offset = scrollView.contentOffset
        if point.x < visible.minX {
            offset.x -= visible.minX - point.x
        } else if point.x > visible.maxX {
            offset.x += point.x - visible.maxX
        } else {
            return
        }
        offset.x = min(max(0, offset.x), scrollView.contentSize.width - scrollView.bounds.width)
        scrollView.setContentOffset(offset, animated: false)
    }
}
