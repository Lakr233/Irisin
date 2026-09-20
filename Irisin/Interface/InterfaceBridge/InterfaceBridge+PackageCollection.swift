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
    /// The smallest cell a package list lays out, whatever width it is given.
    static let minimumPackageCellSize = CGSize(width: 32, height: 32)

    /// A page asks while its view has no width yet, or less than its own
    /// insets: the layout the root container swapped out stays alive and
    /// keeps applying snapshots. The flow layout asserts on a negative size,
    /// so a cell is never smaller than `minimumPackageCellSize`.
    static func calculatesPackageCellSize(availableWidth: CGFloat) -> (size: CGSize, itemsPerRow: Int) {
        let minimum = minimumPackageCellSize
        let available = max(availableWidth, minimum.width)
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

        let height = max(PackageCell.rowHeight, minimum.height)
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
        from host: UIViewController,
        anchor cell: UIView?
    ) -> UIContextMenuConfiguration {
        // the pressed cell, for an action that ends in a popover on the iPad
        let anchor = cell.map { PopoverAnchor($0) }
        return UIContextMenuConfiguration(identifier: nil) {
            let target = PackageController(package: package)
            // the preview's own size; `show(preview:)` drops it on commit
            target.preferredContentSize = CGSize(width: 780, height: 1000)
            return target
        } actionProvider: { [weak host] _ in
            guard let host else { return nil }
            return UIMenu(
                title: "",
                children: PackageMenuAction.menuElements(for: package, from: host, anchor: anchor)
            )
        }
    }
}
