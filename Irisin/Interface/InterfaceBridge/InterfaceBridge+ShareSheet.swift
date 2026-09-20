//
//  InterfaceBridge+ShareSheet.swift
//  Irisin
//

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
extension InterfaceBridge {
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
    /// A bar button says nothing of whether it is on screen: one whose page
    /// was popped while a download ran is neither hidden nor anywhere. So the
    /// anchor's bar button counts only while it is one of the presenter's
    /// own, and no bar button counts while the bar is hidden. The page's
    /// items are its right ones, then its left: the iPad moves some there.
    static func popoverTarget(for anchor: PopoverAnchor?, over presenter: UIViewController) -> PopoverTarget {
        if let view = anchor?.view, view.window != nil {
            return .view(view)
        }
        let barVisible = presenter.navigationController?.isNavigationBarHidden == false
        let item = presenter.navigationItem
        let pageItems = barVisible ? (item.rightBarButtonItems ?? []) + (item.leftBarButtonItems ?? []) : []
        let anchorItems = pageItems.filter { $0 === anchor?.barButtonItem }
        if let item = (anchorItems + pageItems).first(where: { !$0.isHidden }) {
            return .barButtonItem(item)
        }
        return .centre(of: presenter.view)
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
    static func shareSheet(
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

    /// Over a presenter that can take it. A share may come back from a
    /// download or a copy to a page that has left or that shows something
    /// else by then, and says nothing there: UIKit would only log a refusal.
    static func presentShareSheet(_ items: [Any], anchor: PopoverAnchor?, from presenter: UIViewController) {
        guard canPresent(over: presenter) else { return }
        presenter.present(shareSheet(items, anchor: anchor, over: presenter), animated: true)
    }

    static func canPresent(over presenter: UIViewController) -> Bool {
        presenter.viewIfLoaded?.window != nil && presenter.presentedViewController == nil
    }
}
