//
//  TableSheet.swift
//  MarkdownView
//

import Foundation
import Litext
import MarkdownParser

/// What the full-table sheet is built from: the rows of the table it was
/// opened from at that moment, every one of them.
struct TableSheetContent {
    let contents: [[NSAttributedString]]
    let columnAlignments: [RawTableColumnAlignment]
    let theme: MarkdownTheme
    let linkHandler: ((LinkPayload, NSRange, CGPoint) -> Void)?
    /// Every row as Markdown, as Copy puts it on the pasteboard.
    let markdown: String
    /// Every row as CSV, as Download saves it.
    let csv: Data

    @MainActor
    init(_ tableView: TableView) {
        contents = tableView.contents
        columnAlignments = tableView.columnAlignments
        theme = tableView.currentTheme
        linkHandler = tableView.linkHandler
        markdown = tableView.markdown()
        csv = TableExport.csvData(rows: tableView.plainTextRows)
    }

    /// Copy, Download and Close for the sheet showing this table from `view`.
    @MainActor
    func menuActions(from view: @escaping () -> UIView?, close: @escaping () -> Void) -> SheetMenuActions {
        let markdown = markdown
        let csv = csv
        return SheetMenuActions(
            copy: {
                FileExporter.copy(markdown)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            },
            download: {
                guard let view = view() else { return }
                FileExporter.export(csv, fileName: "table.csv", from: view)
            },
            close: close
        )
    }

    /// A table in sheet mode showing every row.
    @MainActor
    func makeTableView() -> TableView {
        let tableView = TableView(mode: .sheet)
        tableView.setTheme(theme)
        tableView.setContents(contents, columnAlignments: columnAlignments)
        tableView.linkHandler = linkHandler
        return tableView
    }
}

// UIKit shows the sheet in TableSheetViewController.
