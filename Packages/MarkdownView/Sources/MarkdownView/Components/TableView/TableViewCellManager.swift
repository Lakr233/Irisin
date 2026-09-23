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
    // MARK: - Properties

    private(set) var cells: [TextLabelView] = []
    private var rawTexts: [NSAttributedString] = []
    private(set) var cellSizes: [CGSize] = []
    private(set) var widths: [CGFloat] = []
    private(set) var heights: [CGFloat] = []
    private var theme: MarkdownTheme = .default
    private weak var delegate: TextLabelViewDelegate?
    private var columnAlignments: [RawTableColumnAlignment] = []
    private var numberOfColumns = 0

    // MARK: - Cell Configuration

    func configureCells(
        for contents: [[NSAttributedString]],
        columnAlignments: [RawTableColumnAlignment] = [],
        in containerView: UIView,
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

        self.columnAlignments = columnAlignments
        self.numberOfColumns = numberOfColumns

        let (requiredCellCount, countOverflow) = numberOfRows.multipliedReportingOverflow(
            by: numberOfColumns
        )
        guard !countOverflow else {
            assertionFailure("Markdown table cell count overflowed Int.")
            resetLayout()
            return
        }
        cellSizes = Array(repeating: .zero, count: requiredCellCount)
        widths = Array(repeating: 0, count: numberOfColumns)
        heights = Array(repeating: 0, count: numberOfRows)
        trimSurplusCells(keeping: requiredCellCount)

        for (row, rowContent) in contents.enumerated() {
            var rowHeight = metrics.minimumRowHeight

            for (column, cellString) in rowContent.enumerated() {
                let index = row * numberOfColumns + column
                let cell = createOrUpdateCell(
                    at: index,
                    with: cellString,
                    maximumTextWidth: metrics.maximumTextWidth,
                    isHeader: row == 0,
                    alignment: columnAlignments[safe: column] ?? .none,
                    in: containerView
                )

                let cellSize = calculateCellSize(for: cell, metrics: metrics)
                cellSizes[index] = cellSize
                rowHeight = max(rowHeight, cellSize.height)
                widths[column] = max(widths[column], cellSize.width)
            }

            heights[row] = rowHeight
        }
    }

    // MARK: - Public Methods

    func setTheme(_ theme: MarkdownTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        updateCellsAppearance()
    }

    func setDelegate(_ delegate: TextLabelViewDelegate?) {
        self.delegate = delegate
        cells.forEach { $0.delegate = delegate }
    }

    // MARK: - Private Methods

    private func createOrUpdateCell(
        at index: Int,
        with attributedText: NSAttributedString,
        maximumTextWidth: CGFloat,
        isHeader: Bool,
        alignment: RawTableColumnAlignment,
        in containerView: UIView
    ) -> TextLabelView {
        let cell: TextLabelView

        if index >= cells.count {
            cell = TextLabelView()
            cell.backgroundColor = .clear
            cell.selectionBackgroundColor = theme.colors.selectionBackground
            cell.delegate = delegate
            containerView.addSubview(cell)
            cells.append(cell)
        } else {
            cell = cells[index]
        }

        cell.isSelectable = true

        let styledText = styledText(
            from: attributedText,
            isHeader: isHeader,
            alignment: alignment
        )
        let sourceChanged = index >= rawTexts.count
            || !rawTexts[index].isEqual(to: attributedText)
        let needsTextUpdate = sourceChanged
            || !cell.attributedText.isEqual(to: styledText)
            || cell.preferredMaxLayoutWidth != maximumTextWidth

        guard needsTextUpdate else { return cell }

        if index < rawTexts.count {
            rawTexts[index] = attributedText
        } else {
            rawTexts.append(attributedText)
        }
        cell.preferredMaxLayoutWidth = maximumTextWidth
        cell.attributedText = styledText
        return cell
    }

    private func trimSurplusCells(keeping requiredCellCount: Int) {
        guard cells.count > requiredCellCount else { return }
        for index in stride(from: cells.count - 1, through: requiredCellCount, by: -1) {
            cells[index].removeFromSuperview()
            cells.remove(at: index)
            if index < rawTexts.count {
                rawTexts.remove(at: index)
            }
        }
    }

    private func resetLayout() {
        trimSurplusCells(keeping: 0)
        rawTexts.removeAll()
        cellSizes.removeAll()
        widths.removeAll()
        heights.removeAll()
        columnAlignments.removeAll()
        numberOfColumns = 0
    }

    private func calculateCellSize(
        for cell: TextLabelView,
        metrics: TableLayoutMetrics
    ) -> CGSize {
        let contentSize = cell.intrinsicContentSize
        let paddedWidth = ceil(contentSize.width) + metrics.horizontalCellPadding * 2
        let paddedHeight = ceil(contentSize.height) + metrics.verticalCellPadding * 2
        return CGSize(
            width: min(
                metrics.maximumColumnWidth,
                max(metrics.minimumColumnWidth, paddedWidth)
            ),
            height: max(metrics.minimumRowHeight, paddedHeight)
        )
    }

    private func styledText(
        from source: NSAttributedString,
        isHeader: Bool,
        alignment: RawTableColumnAlignment
    ) -> NSAttributedString {
        guard let attributedText = source.mutableCopy() as? NSMutableAttributedString else {
            return source
        }
        let range = NSRange(location: 0, length: attributedText.length)

        if isHeader {
            attributedText.enumerateAttribute(.font, in: range, options: []) {
                value, subRange, _ in
                if let existingFont = value as? UIFont {
                    let boldFont = UIFont.boldSystemFont(ofSize: existingFont.pointSize)
                    attributedText.addAttribute(.font, value: boldFont, range: subRange)
                } else {
                    attributedText.addAttribute(.font, value: theme.fonts.bold, range: subRange)
                }
            }
        }

        attributedText.enumerateAttribute(.foregroundColor, in: range, options: []) {
            value, subRange, _ in
            guard value == nil else { return }
            attributedText.addAttribute(
                .foregroundColor,
                value: theme.colors.body,
                range: subRange
            )
        }

        applyParagraphStyle(to: attributedText, alignment: alignment)
        return attributedText
    }

    private func applyParagraphStyle(
        to attributedText: NSMutableAttributedString,
        alignment: RawTableColumnAlignment
    ) {
        let range = NSRange(location: 0, length: attributedText.length)
        let textAlignment: NSTextAlignment = switch alignment {
        case .center:
            .center
        case .right:
            .right
        case .left, .none:
            .left
        }

        var updates: [(NSRange, NSMutableParagraphStyle)] = []
        attributedText.enumerateAttribute(.paragraphStyle, in: range, options: []) {
            value, subRange, _ in
            let paragraphStyle = (value as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle ?? .init()
            paragraphStyle.alignment = textAlignment
            paragraphStyle.lineBreakMode = .byWordWrapping
            updates.append((subRange, paragraphStyle))
        }
        for (subRange, paragraphStyle) in updates {
            attributedText.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: subRange
            )
        }
    }

    private func updateCellsAppearance() {
        guard numberOfColumns > 0 else { return }

        for (index, cell) in cells.enumerated() {
            cell.selectionBackgroundColor = theme.colors.selectionBackground
            let source = index < rawTexts.count ? rawTexts[index] : cell.attributedText
            let styled = styledText(
                from: source,
                isHeader: index / numberOfColumns == 0,
                alignment: columnAlignments[safe: index % numberOfColumns] ?? .none
            )
            if !styled.isEqual(to: cell.attributedText) {
                cell.attributedText = styled
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
