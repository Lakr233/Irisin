//
//  ShareSheet.swift
//  Irisin
//

import SPIndicator
import UIKit

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

/// The share sheet, in the one place the app makes one. The iPad shows it as
/// a popover and answers one with nowhere to point with an exception
/// (`presentationTransitionWillBegin`), so nothing else constructs a
/// `UIActivityViewController` or touches a `popoverPresentationController`;
/// `make check` greps for both.
enum ShareSheet {
    /// Where a popover ends up pointing.
    enum PopoverTarget {
        /// A view still on screen, and its bounds.
        case view(UIView)
        /// A bar button that is showing.
        case barButtonItem(UIBarButtonItem)
        /// The middle of the presenter's own view, with no arrow.
        case centre(of: UIView)
    }

    /// The decision alone: `anchor` while what it names is still on screen,
    /// then the page's own bar button, then the middle of the page. There is
    /// always an answer.
    ///
    /// Being in a window is not being on screen. A view counts while it is
    /// in the presenter's window (there may be several scenes), has a size
    /// and is not hidden by itself or by anything above it: the custom view
    /// of a hidden navigation bar is still in the window. A bar button says
    /// nothing at all: one whose page was popped while a download ran is
    /// neither hidden nor anywhere. So the anchor's bar button counts only
    /// while it is one of the presenter's own, and no bar button counts
    /// unless the presenter is the page its bar is showing. The page's items
    /// are its right ones, then its left: the iPad moves some there.
    static func popoverTarget(for anchor: PopoverAnchor?, over presenter: UIViewController) -> PopoverTarget {
        if let view = anchor?.view, isOnScreen(view, in: presenter.viewIfLoaded?.window) {
            return .view(view)
        }
        let item = presenter.navigationItem
        let pageItems = showsBarButtons(of: presenter)
            ? (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? [])
            : []
        let anchorItems = pageItems.filter { $0 === anchor?.barButtonItem }
        if let item = (anchorItems + pageItems).first(where: { !$0.isHidden }) {
            return .barButtonItem(item)
        }
        // A presenter with no view yet is never presented over
        // (`canPresent`); the answer is still one a popover can take.
        let ground = sequence(first: presenter, next: \.parent).lazy.compactMap(\.viewIfLoaded).first
        return .centre(of: ground ?? presenter.view)
    }

    static func isOnScreen(_ view: UIView, in window: UIWindow?) -> Bool {
        guard let window, view.window === window, !view.bounds.isEmpty else { return false }
        return sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden && $0.alpha > 0 }
    }

    /// Whether the navigation bar on screen is showing this page's items.
    static func showsBarButtons(of presenter: UIViewController) -> Bool {
        guard let navigator = presenter.navigationController,
              navigator.topViewController === presenter,
              !navigator.isNavigationBarHidden
        else { return false }
        return isOnScreen(navigator.navigationBar, in: presenter.viewIfLoaded?.window)
    }

    static func point(_ popover: UIPopoverPresentationController, at target: PopoverTarget) {
        switch target {
        case let .view(view):
            popover.sourceView = view
            popover.sourceRect = view.bounds
        case let .barButtonItem(item):
            popover.barButtonItem = item
        case let .centre(view):
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
    }

    /// The sheet as it is presented. On the iPhone it is no popover and
    /// there is nothing to point.
    static func controller(
        _ items: [Any],
        anchor: PopoverAnchor?,
        over presenter: UIViewController
    ) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            point(popover, at: popoverTarget(for: anchor, over: presenter))
        }
        return sheet
    }

    /// Over `presenter` while it can take it. A share may come back from a
    /// download or a copy to a page that has left or that shows something
    /// else by then; the sheet then goes over whatever is on top in the same
    /// window, pointing at that page and not at `anchor`. A cancelled task
    /// shares nothing, and with nowhere at all to go the user is told.
    static func present(_ items: [Any], anchor: PopoverAnchor?, from presenter: UIViewController) {
        guard !Task.isCancelled else { return }
        guard let host = presentableController(for: presenter, anchor: anchor) else {
            SPIndicator.present(title: String(localized: "Unable to Export"), preset: .error)
            return
        }
        let anchor = host === presenter ? anchor : nil
        host.present(controller(items, anchor: anchor, over: host), animated: true)
    }

    /// `presenter`, or the page on top of its window when it cannot present:
    /// the last of the root's presented controllers, and the page that one
    /// shows. The window of a presenter that left is the anchor's, and then
    /// the one the user is looking at.
    static func presentableController(
        for presenter: UIViewController,
        anchor: PopoverAnchor? = nil
    ) -> UIViewController? {
        if canPresent(over: presenter) { return presenter }
        let window = presenter.viewIfLoaded?.window ?? anchor?.view?.window ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
        guard var top = window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        while let page = (top as? UINavigationController)?.topViewController
            ?? (top as? UITabBarController)?.selectedViewController
        {
            top = page
        }
        return canPresent(over: top) ? top : nil
    }

    /// In a window, and nothing presented by it or by anything it is in.
    static func canPresent(over presenter: UIViewController) -> Bool {
        guard presenter.viewIfLoaded?.window != nil else { return false }
        return sequence(first: presenter, next: \.parent).allSatisfy { $0.presentedViewController == nil }
    }
}
