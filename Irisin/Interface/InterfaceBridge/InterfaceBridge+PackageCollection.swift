//
//  InterfaceBridge+PackageCollection.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/9/12.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import UIKit

extension InterfaceBridge {
    static func calculatesPackageCellSize(availableWidth available: CGFloat) -> (size: CGSize, itemsPerRow: Int) {
        var itemsPerRow = 1
        let padding: CGFloat = 8
        var result = CGSize(width: available, height: 0)

        let maximumWidth: CGFloat = 280 // soft limit
        // | padding [minimalWidth] padding [minimalWidth] padding |
        if available > maximumWidth * 2 + padding * 3 {
            // just in case, dont loop forever
            while result.width > maximumWidth, itemsPerRow <= 10 {
                itemsPerRow += 1
                // [minimalWidth] padding |
                var recalculate = (available - padding) / CGFloat(itemsPerRow)
                // [minimalWidth]
                recalculate -= padding
                result.width = recalculate
            }
        }

        let height = PackageCell.rowHeight
        if itemsPerRow < 2 {
            // no padding for single element
            return (CGSize(width: available, height: height), itemsPerRow)
        }

        // the loop left result.width at the final itemsPerRow
        result.height = height
        return (result, itemsPerRow)
    }

    static func packageContextMenuConfiguration(
        for package: Package,
        from host: UIViewController
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil) {
            let target = PackageController(package: package)
            // the preview's own size; `show(preview:)` drops it on commit
            target.preferredContentSize = CGSize(width: 780, height: 1000)
            return target
        } actionProvider: { [weak host] _ in
            guard let host else { return nil }
            return UIMenu(title: "", children: PackageMenuAction.menuElements(for: package, from: host))
        }
    }
}
