//
//  DiffableDataSource.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import OrderedCollections
import UIKit

extension NSDiffableDataSourceSnapshot {
    /// Items that survive from `previous` keep their identifier and their
    /// cell, so the cell provider never runs again for them. Mark them, and
    /// the search highlight, the queue indicator and the download listener
    /// follow the new content.
    mutating func reconfigureItems(survivingFrom previous: NSDiffableDataSourceSnapshot) {
        let before = Set(previous.itemIdentifiers)
        let survivors = itemIdentifiers.filter { before.contains($0) }
        if !survivors.isEmpty {
            reconfigureItems(survivors)
        }
    }
}

/// `UITableViewDiffableDataSource` answers `canEditRowAt` with false, which
/// silently disables swipe actions.
final class EditableTableDiffableDataSource<Section: Hashable & Sendable, Item: Hashable & Sendable>:
    UITableViewDiffableDataSource<Section, Item>
{
    override func tableView(_: UITableView, canEditRowAt _: IndexPath) -> Bool {
        true
    }

    /// Grouped header and footer text per section, when the list has any.
    var headerTitle: ((Section) -> String?)?
    var footerTitle: ((Section) -> String?)?

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        headerTitle?(snapshot().sectionIdentifiers[section])
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        footerTitle?(snapshot().sectionIdentifiers[section])
    }

    /// Nothing to release. Spelled out because the implicit deinit is
    /// main-actor isolated under the default isolation, and Swift 6.3's
    /// optimizer (Xcode 26.6) crashes inlining that for a generic subclass
    /// of an Objective-C generic class.
    nonisolated deinit {}
}

nonisolated extension Array where Element: Hashable {
    /// A snapshot aborts on a duplicated identifier; keep the first one.
    func uniqued() -> [Element] {
        OrderedSet(self).elements
    }
}

extension UIView {
    /// Animate a diff only while the user can see it. A reload behind another
    /// screen, or before the first layout, should just land.
    var shouldAnimateDiff: Bool {
        window != nil && !bounds.isEmpty
    }
}
