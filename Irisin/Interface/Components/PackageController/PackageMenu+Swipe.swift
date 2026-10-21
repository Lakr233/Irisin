//
//  PackageMenu+Swipe.swift
//  Irisin
//

import AptRepository
import UIKit

/// A swipe on any package row: the package menu's own actions, decided by
/// the same eligibility and run by the same blocks, with one difference.
/// A request that changes the queue by the swiped package alone joins it
/// without the change sheet (`QueueChangeController.takesPlainChanges`);
/// one that brings anything else along still shows the sheet.
extension PackageMenu {
    /// What a swipe on a repository's row offers, from the trailing edge
    /// in: what the user came to the list for comes first, Install or
    /// Update, and Remove last. The Installed page has its own order
    /// (`swipeDescriptors`), Remove first.
    static let catalogueSwipeDescriptors: [Action] = [.dequeue, .install, .update, .reinstall, .remove]

    /// The swipe actions of a repository's row, in `catalogueSwipeDescriptors`'s order.
    static func swipeActions(forCatalogue package: Package) -> [Item] {
        let eligible = eligibleActions(for: package)
        return catalogueSwipeDescriptors.compactMap { descriptor in
            eligible.first { $0.descriptor == descriptor }
        }
    }

    /// The swipe of a repository's row.
    static func swipeConfiguration(
        for package: Package,
        from host: UIViewController,
        anchor: @escaping () -> PopoverAnchor?
    ) -> UISwipeActionsConfiguration? {
        swipeConfiguration(for: package, actions: swipeActions(forCatalogue: package), from: host, anchor: anchor)
    }

    /// `actions` as a swipe, each made with `package`. `anchor` is the row,
    /// for an action that ends in a popover, asked once the action runs.
    static func swipeConfiguration(
        for package: Package,
        actions: [Item],
        from host: UIViewController,
        anchor: @escaping () -> PopoverAnchor?
    ) -> UISwipeActionsConfiguration? {
        guard !actions.isEmpty else { return nil }
        let configuration = UISwipeActionsConfiguration(actions: actions.map { action in
            let removes = action.descriptor == .remove || action.descriptor == .dequeue
            let item = UIContextualAction(style: .normal, title: nil) { [weak host] _, _, completion in
                completion(true)
                guard let host else { return }
                let anchor = anchor()
                Task {
                    await QueueChangeController.$takesPlainChanges.withValue(true) {
                        await action.block(package, host, anchor)
                    }
                }
            }
            // the menu's own symbol without its outline, which the system
            // draws as a circle of its own, and its name for VoiceOver
            item.image = action.descriptor.swipeIcon()
            item.accessibilityLabel = action.descriptor.describe()
            item.backgroundColor = removes ? .swipeDelete : .swipeRefresh
            return item
        })
        // a request is never made by a swipe that went too far
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

extension PackageMenu.Action {
    /// A swipe's symbol: the menu's, without the circle or square around
    /// it, since the action's own fill is the shape.
    func swipeIcon() -> UIImage? {
        switch self {
        case .dequeue:
            UIImage(systemName: "minus")
        case .install:
            UIImage(systemName: "arrow.down")
        case .reinstall:
            UIImage(systemName: "arrow.clockwise")
        case .downgrade:
            UIImage(systemName: "arrow.down")
        case .update:
            UIImage(systemName: "arrow.up")
        case .remove:
            UIImage(systemName: "xmark")
        default:
            icon()
        }
    }
}
