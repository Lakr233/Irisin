//
//  PackageMenuAction+Installed.swift
//  Irisin
//

import AptRepository
import AptResolver
import UIKit

/// What the Installed page asks for without opening a package: a swipe on a
/// row and the bar of a selection. Both are the package menu's own actions,
/// decided by the same eligibility and run by the same blocks.
extension PackageMenuAction {
    /// What a swipe offers, from the trailing edge in: a queued package
    /// leaves the queue, an installed one is removed, and updated or
    /// reinstalled when a repository has the version for it.
    static let swipeDescriptors: [ActionDescriptor] = [.dequeue, .remove, .update, .reinstall]

    /// `eligible` narrowed to what a swipe offers, in the swipe's order.
    static func swipeOrder(of eligible: [ActionDescriptor]) -> [ActionDescriptor] {
        swipeDescriptors.filter(eligible.contains)
    }

    /// The swipe actions of a dpkg row, with the package each one is made
    /// with: the one the package page's button would use.
    static func swipeActions(forInstalled row: Package) -> (package: Package, actions: [MenuAction]) {
        let package = requestPackage(for: row)
        let eligible = eligibleActions(for: package)
        let actions = swipeOrder(of: eligible.map(\.descriptor)).compactMap { descriptor in
            eligible.first { $0.descriptor == descriptor }
        }
        return (package, actions)
    }

    /// The update of a dpkg row as a request, nil when the menu would not
    /// offer Update. A commercial package is left out: its download link
    /// is the vendor's answer to one purchase check, made on its own page.
    static func updateRequest(forInstalled row: Package) -> ResolutionAction? {
        let package = requestPackage(for: row)
        guard package.isSupportedOnDevice, !package.isCommercial,
              let update = allMenuActions.first(where: { $0.descriptor == .update }),
              update.eligibleForPerform(package),
              let version = package.latestVersion,
              let selected = PackageCenter.default.trim(package: package, toVersion: version)
        else { return nil }
        return .install(selected)
    }
}
