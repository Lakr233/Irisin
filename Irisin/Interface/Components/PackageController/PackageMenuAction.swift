//
//  PackageMenuAction.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/24.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import AptResolver
import Dog
import UIKit

@MainActor
class PackageMenuAction {
    enum ActionDescriptor: String, CaseIterable {
        case dequeue
        /// The queue installs a different package record: this one takes its place.
        case replace
        case directInstall
        case install
        case reinstall
        case downgrade
        case update
        case remove
        case versionControl
        case blockUpdate
        case unblockUpdate
        case download
        case viewMeta
        case revealFiles

        func describe() -> String {
            switch self {
            case .dequeue:
                String(localized: "Remove from Queue")
            case .replace:
                String(localized: "Replace")
            case .directInstall:
                String(localized: "Direct Install")
            case .install:
                String(localized: "Install")
            case .reinstall:
                String(localized: "Reinstall")
            case .downgrade:
                String(localized: "Downgrade")
            case .update:
                String(localized: "Update")
            case .remove:
                String(localized: "Remove")
            case .versionControl:
                String(localized: "Choose Version")
            case .blockUpdate:
                String(localized: "Block Update")
            case .unblockUpdate:
                String(localized: "Unblock Update")
            case .download:
                String(localized: "Download Archive")
            case .viewMeta:
                String(localized: "View Package Info")
            case .revealFiles:
                String(localized: "Reveal Files")
            }
        }

        func icon() -> UIImage? {
            switch self {
            case .dequeue:
                UIImage(systemName: "minus.circle")
            case .replace:
                UIImage(systemName: "arrow.left.arrow.right.circle")
            case .directInstall:
                UIImage(systemName: "paperplane")
            case .install:
                UIImage(systemName: "arrow.down.square")
            case .reinstall:
                UIImage(systemName: "arrow.clockwise.circle")
            case .downgrade:
                UIImage(systemName: "arrow.down.circle")
            case .update:
                UIImage(systemName: "arrow.up.circle")
            case .remove:
                UIImage(systemName: "xmark.circle")
            case .versionControl:
                UIImage(systemName: "list.triangle")
            case .blockUpdate:
                UIImage(systemName: "hand.raised")
            case .unblockUpdate:
                UIImage(systemName: "face.dashed")
            case .download:
                UIImage(systemName: "icloud.and.arrow.down")
            case .viewMeta:
                UIImage(systemName: "doc.text")
            case .revealFiles:
                UIImage(systemName: "doc.text.magnifyingglass")
            }
        }
    }

    struct MenuAction {
        let descriptor: ActionDescriptor
        /// Runs with the page the menu belongs to, which presents what the
        /// action shows, and what the user touched to get here, for an
        /// action that ends in a popover on the iPad.
        typealias Block = @MainActor (Package, UIViewController, PopoverAnchor?) async -> Void

        let block: Block
        let eligibleForPerform: (Package) -> (Bool)
    }

    /// The menu's inline sections, in order: the transaction, then another
    /// version.
    static let menuSections: [[ActionDescriptor]] = [
        [.dequeue, .replace, .directInstall, .install, .update, .downgrade, .remove],
        [.versionControl],
    ]

    /// The requests a queued package no longer offers: it leaves the queue
    /// first.
    static let requestActions: Set<ActionDescriptor> = [
        .directInstall, .install, .reinstall, .downgrade, .update, .remove,
    ]

    /// What the package offers now, in menu order.
    static func eligibleActions(for package: Package) -> [MenuAction] {
        let queued = TaskManager.shared.isQueued(package.identity)
        return allMenuActions.filter { action in
            !(queued && requestActions.contains(action.descriptor)) && action.eligibleForPerform(package)
        }
    }

    /// What goes under Advanced, a submenu at the end.
    static let advancedSection: [ActionDescriptor] = [
        .reinstall, .blockUpdate, .unblockUpdate, .download, .viewMeta, .revealFiles,
    ]

    /// The actions that take the package down: red.
    static let destructiveActions: Set<ActionDescriptor> = [.downgrade, .remove]

    /// Every package menu in the app — the install button, the navigation
    /// bar, a long press on a cell — is this one.
    /// `anchor` is the cell of a long press, and wins: a context menu's
    /// sender may be the whole list. A button's or a bar button's menu
    /// passes none and names itself as the action's sender.
    static func menuElements(
        for package: Package,
        from host: UIViewController,
        anchor: PopoverAnchor? = nil
    ) -> [UIMenuElement] {
        let actions = eligibleActions(for: package)
        func children(of section: [ActionDescriptor]) -> [UIAction] {
            actions
                .filter { section.contains($0.descriptor) }
                .map { action in
                    UIAction(
                        title: action.descriptor.describe(),
                        image: action.descriptor.icon(),
                        attributes: destructiveActions.contains(action.descriptor) ? .destructive : []
                    ) { [weak host] chosen in
                        guard let host else { return }
                        let anchor = anchor ?? PopoverAnchor(sender: chosen.sender)
                        Task { await action.block(package, host, anchor) }
                    }
                }
        }
        var elements: [UIMenuElement] = menuSections.compactMap { section in
            let children = children(of: section)
            return children.isEmpty ? nil : UIMenu(options: .displayInline, children: children)
        }
        // the package page reads in another language; a cell has no page
        if let translate = (host as? PackageController)?.translateMenu {
            elements.append(translate)
        }
        let advanced = children(of: advancedSection)
        if !advanced.isEmpty {
            elements.append(UIMenu(
                title: String(localized: "Advanced"),
                image: UIImage(systemName: "ellipsis.circle"),
                children: advanced
            ))
        }
        return elements
    }

    /// The package a request is made with. Only a dpkg row needs a
    /// repository candidate: the newest update on offer, or with none the
    /// install origin, so a reinstall takes the same package. An explicit
    /// file or repository version stays the package the user opened.
    static func requestPackage(for package: Package) -> Package {
        guard !package.identity.isEmpty, package.repoRef == nil, package.localFileURL == nil,
              let installInfo = PackageCenter.default.obtainPackageInstallationInfo(with: package.identity)
        else { return package }
        let origin = PackageCenter.default.obtainInstallOrigin(of: installInfo.identity)
        return PackageCenter.default.newestPackage(
            of: PackageCenter.default.obtainUpdateForPackage(
                with: installInfo.identity,
                version: installInfo.version
            ),
            preferring: origin?.repoRef
        ) ?? origin ?? package
    }

    /// Every request in the app goes here: the change sheet shows what it
    /// does to the queue and adds it. Returns once the sheet is on its way in.
    static func enqueue(_ actions: [ResolutionAction], from host: UIViewController) async {
        await QueueChangeController.show(.actions(actions), from: host)
    }
}
