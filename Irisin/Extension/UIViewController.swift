//
//  UIViewController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AlertController
import UIKit

extension UIViewController {
    /// The content size of every form sheet, set on the navigator that is
    /// the sheet and never on a page inside it: a page's size reaches the
    /// navigator on push and pop, and the sheet on the iPad jumps with it.
    /// The iPad adds the navigation bar's height to it, so a sheet whose
    /// pages differ in bar height (a large title over plain ones) takes
    /// the system's size instead: see `QueueController.showConsole`.
    var preferredPopOverSize: CGSize {
        CGSize(width: 555, height: 555)
    }

    func hideKeyboardWhenTappedAround() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(UIViewController.dismissKeyboard))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    @objc func dismissKeyboard() {
        view.endEditing(true)
    }

    func setTabBadge(_ value: String?) {
        tabBarItem.badgeValue = value
        if #available(iOS 18.0, *) {
            tab?.badgeValue = value
        }
    }

    func present(next: UIViewController) {
        let neverPushed = next is AlertBaseController
        if let navigator = navigationController, !neverPushed {
            navigator.pushViewController(next, animated: true)
        } else if neverPushed || next is UINavigationController {
            next.modalTransitionStyle = .coverVertical
            next.modalPresentationStyle = .formSheet
            present(next, animated: true, completion: nil)
        } else {
            // a sheet with nothing to push into gets its own bar: a title,
            // the screen's own bar items, and a way out
            let navigator = UINavigationController(rootViewController: next)
            next.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { [weak navigator] _ in navigator?.dismiss(animated: true) }
            )
            navigator.preferredContentSize = preferredPopOverSize
            navigator.modalTransitionStyle = .coverVertical
            navigator.modalPresentationStyle = .formSheet
            present(navigator, animated: true, completion: nil)
        }
    }

    /// The share sheet, which the iPad shows as a popover and refuses with an
    /// exception when the popover has nowhere to point. So it always has
    /// somewhere: `anchor` while what it names is still on screen, then the
    /// page's own bar button, then the middle of the page with no arrow.
    func presentShareSheet(_ items: [Any], anchor: PopoverAnchor?) {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            let barVisible = navigationController?.isNavigationBarHidden == false
            let pageItems = barVisible ? navigationItem.rightBarButtonItems ?? [] : []
            let barItems = [anchor?.barButtonItem].compactMap(\.self) + pageItems
            if let source = anchor?.view, source.window != nil {
                popover.sourceView = source
                popover.sourceRect = source.bounds
            } else if let item = barItems.first(where: { !$0.isHidden }) {
                popover.barButtonItem = item
            } else {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
        }
        present(sheet, animated: true)
    }

    /// Shows a context menu's preview as a page. The preview's size was the
    /// menu's: pushed with it, the page would resize the sheet it lands in.
    func show(preview animator: UIContextMenuInteractionCommitAnimating) {
        guard let page = animator.previewViewController else { return }
        page.preferredContentSize = .zero
        animator.addAnimations { self.show(page, sender: self) }
    }
}

/// What a popover points at on the iPad: the view or the bar button the user
/// touched. Held weakly, since a share may wait on a download and the cell
/// it came from may be gone by then.
struct PopoverAnchor {
    private(set) weak var view: UIView?
    private(set) weak var barButtonItem: UIBarButtonItem?

    init(_ view: UIView) {
        self.view = view
    }

    init(_ barButtonItem: UIBarButtonItem) {
        self.barButtonItem = barButtonItem
    }

    /// From a `UIAction`'s sender: the button or bar button whose menu it
    /// was. A context menu's sender is neither, and the caller names the cell.
    init?(sender: Any?) {
        switch sender {
        case let view as UIView: self.init(view)
        case let item as UIBarButtonItem: self.init(item)
        default: return nil
        }
    }
}

extension UINavigationController {
    /// A form sheet around `root`: half height on the iPhone until the list
    /// needs more, on an opaque ground where iOS 26 would show glass.
    static func halfSheet(root: UIViewController) -> UINavigationController {
        let navigator = UINavigationController(rootViewController: root)
        navigator.modalPresentationStyle = .formSheet
        navigator.preferredContentSize = root.preferredPopOverSize
        // the root's own view: the sheet clears the navigator's ground, and
        // a list left to its default turns to glass at half height
        root.view.backgroundColor = .groupedBackground
        // from iOS 26.1 the sheet itself can be told: a colour, not glass
        if #available(iOS 26.1, *) {
            navigator.presentationController?.backgroundEffect = UIColorEffect(color: .groupedBackground)
        }
        if UIDevice.current.userInterfaceIdiom != .pad, let sheet = navigator.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        return navigator
    }
}
