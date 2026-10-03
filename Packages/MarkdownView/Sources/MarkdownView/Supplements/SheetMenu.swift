//
//  SheetMenu.swift
//  MarkdownView
//

import Foundation
import UIKit

/// What the menu at the top trailing corner of a code or table sheet does.
///
/// The block in the document keeps only Copy and Expand; saving a file and
/// closing the sheet happen from here.
struct SheetMenuActions {
    let copy: () -> Void
    let download: () -> Void
    let close: () -> Void
}

enum SheetMenuText {
    static var more: String {
        String(localized: "More", comment: "Button that opens a sheet's menu of actions.")
    }

    static var close: String {
        String(localized: "Close", comment: "Menu item that closes a code or table sheet.")
    }
}

enum SheetMenuSymbol {
    static let menu = "ellipsis"
    static let close = "chevron.down"
}

extension UIBarButtonItem {
    /// A bar button that opens Copy, Download and Close.
    @MainActor
    static func sheetMenu(_ actions: SheetMenuActions) -> UIBarButtonItem {
        let menu = UIMenu(children: [
            UIAction(title: TableTitleText.copy, image: UIImage(systemName: TableSymbol.copy)) { _ in
                actions.copy()
            },
            UIAction(title: TableTitleText.download, image: UIImage(systemName: TableSymbol.download)) { _ in
                actions.download()
            },
            UIAction(title: SheetMenuText.close, image: UIImage(systemName: SheetMenuSymbol.close)) { _ in
                actions.close()
            },
        ])
        let item = UIBarButtonItem(image: UIImage(systemName: SheetMenuSymbol.menu), menu: menu)
        item.accessibilityLabel = SheetMenuText.more
        return item
    }
}
