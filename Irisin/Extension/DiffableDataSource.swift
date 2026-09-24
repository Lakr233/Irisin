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

/// A list's changes for a table that may be out of the window. A table
/// laid out outside a window lays out against sizes it does not have yet,
/// so a change waits for the page to be in one: the latest change of each
/// kind is kept and applied, unanimated and in the order they came, when
/// the page calls `applyPending()` from `viewIsAppearing`. Every list
/// that changes while another page covers it goes through this.
final class WindowedListUpdates {
    private var pending: [(kind: String, update: (_ animated: Bool) -> Void)] = []

    /// Runs `update` now when `table` is in a window, or keeps it as the
    /// latest change of its `kind` until the page appears. `update` reads
    /// the page's state when it runs, not when it was asked for.
    func apply(
        _ kind: String,
        to table: UIView,
        animated: Bool,
        _ update: @escaping (_ animated: Bool) -> Void
    ) {
        pending.removeAll { $0.kind == kind }
        guard table.window != nil else {
            pending.append((kind, update))
            return
        }
        update(animated)
    }

    func applyPending() {
        let updates = pending
        pending = []
        for entry in updates {
            entry.update(false)
        }
    }
}

extension UIView {
    /// Animate a diff only while the user can see it. A reload behind another
    /// screen, or before the first layout, should just land.
    var shouldAnimateDiff: Bool {
        window != nil && !bounds.isEmpty
    }
}
