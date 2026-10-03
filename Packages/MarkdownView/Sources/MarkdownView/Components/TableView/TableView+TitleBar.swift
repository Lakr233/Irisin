//
//  TableView+TitleBar.swift
//  MarkdownView
//

import Foundation
import UIKit

/// The text of a table's title bar and of its buttons.
enum TableTitleText {
    static var table: String {
        String(localized: "Table", comment: "Title of a table's bar.")
    }

    /// The title of a table that leaves `hiddenRowCount` rows out.
    static func table(hiddenRowCount: Int) -> String {
        String(
            localized: "Table (\(hiddenRowCount) more rows not shown)",
            comment: "Title of a long table's bar, counting the rows it does not draw."
        )
    }

    static var copy: String {
        String(localized: "Copy", comment: "Button that copies a table or a code block.")
    }

    static var download: String {
        String(
            localized: "Download",
            comment: "Button that saves a table or a code block as a file."
        )
    }

    static var expand: String {
        String(
            localized: "Expand",
            comment: "Button that opens a table or a code block in a sheet."
        )
    }
}

/// The name at the leading end of a table's title bar.
final class TableTitleLabel: BarTextLabel {
    private var theme: MarkdownTheme = .default

    override init(frame: CGRect) {
        super.init(frame: frame)
        textColor = .secondaryLabel
        setTheme(.default)
        text = TableTitleText.table
    }

    func setTheme(_ theme: MarkdownTheme) {
        self.theme = theme
        font = theme.fonts.footnote
    }

    /// The bar's height: one line of the title and the bar's padding.
    var barHeight: CGFloat {
        lineHeight + TableTitleBar.verticalPadding * 2
    }

    func setHiddenRowCount(_ count: Int) {
        text = count > 0 ? TableTitleText.table(hiddenRowCount: count) : TableTitleText.table
    }
}

enum TableTitleBar {
    static let verticalPadding: CGFloat = 8
    /// Each button's width, shared by tables and code blocks. Narrow enough
    /// that the glyphs read as one group; the button stays full height.
    static let buttonWidth: CGFloat = 32
    /// How long Copy shows a checkmark after it is tapped.
    static let copyFeedbackDuration: TimeInterval = 1.5
}

extension TableView {
    func makeTitleControl(symbol: String, title: String, handler: @escaping () -> Void) -> TableTapControl {
        let control = TableTapControl()
        control.setSymbol(symbol)
        control.setAccessibleTitle(title)
        control.handler = handler
        return control
    }

    /// The title at the leading end and Copy and Expand at the trailing end,
    /// inside the bar above the rows. A button the bar has no room for is
    /// hidden — Copy first — rather than drawn past the table's edge, where
    /// no tap could reach it. Download is in the sheet Expand opens.
    func layoutTitleBar() {
        guard mode == .inline else { return }
        let height = titleHeight
        let glyph = TableHeaderAccessory.glyphSize
        let leading = tableViewPadding + layoutMetrics.horizontalCellPadding
        var trailing = bounds.width - tableViewPadding - 4
        for control in [expandControl, copyControl] {
            control.isHidden = trailing - TableTitleBar.buttonWidth < leading
            guard !control.isHidden else { continue }
            trailing -= TableTitleBar.buttonWidth
            control.applyFrame(CGRect(x: trailing, y: tableViewPadding, width: TableTitleBar.buttonWidth, height: height))
            control.glyphFrame = CGRect(
                x: (TableTitleBar.buttonWidth - glyph) / 2,
                y: (height - glyph) / 2,
                width: glyph,
                height: glyph
            )
        }
        // As wide as the title and no wider, so a resize that leaves room
        // for it keeps its width and does not set the text again.
        let labelSize = titleLabel.intrinsicContentSize
        titleLabel.applyFrame(CGRect(
            x: leading,
            y: tableViewPadding + (height - labelSize.height) / 2,
            width: min(labelSize.width, max(0, trailing - leading)),
            height: labelSize.height
        ))
    }

    /// Every row as plain text, header first.
    var plainTextRows: [[String]] {
        contents.map { $0.map(TableExport.plainText) }
    }

    /// Every row, drawn or not, as a Markdown table: written back from the
    /// parsed rows, so links, code, emphasis and math survive, or from the
    /// cells' text for a table given only those.
    func markdown() -> String {
        let rows: [[String]] = if let sourceRows,
                                  sourceRows.count == contents.count,
                                  zip(sourceRows, contents).allSatisfy({ $0.cells.count == $1.count })
        {
            sourceRows.map { $0.cells.map { TableExport.markdownSource($0.content) } }
        } else {
            plainTextRows
        }
        return TableExport.markdown(rows: rows, alignments: columnAlignments)
    }

    func copyTable() {
        FileExporter.copy(markdown())
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copyControl.setSymbol(TableSymbol.copied)
        schedule(#selector(resetTableCopyFeedback), after: TableTitleBar.copyFeedbackDuration)
    }

    @objc func resetTableCopyFeedback() {
        cancelScheduled(#selector(resetTableCopyFeedback))
        copyControl.setSymbol(TableSymbol.copy)
    }
}
