//
//  SettlingRefreshControl.swift
//  Irisin
//

import UIKit

/// A refresh control that closes over a list shorter than the screen
/// without a jump. UIKit eases the list home when the control closes, but
/// over such a list the first step is the last: an offset outside the
/// content is pulled back within a frame, and the list jumps. When it
/// arrives home in one stride, it is put back where it was and animated as
/// a view, which leaves the offset itself at rest where nothing corrects it.
/// The list's delegate hands its `scrollViewDidScroll` to `listDidScroll`.
final class SettlingRefreshControl: UIRefreshControl {
    /// Where the list hung when the control was told to close, until the
    /// scroll that follows has been seen.
    private var offsetBeforeEnd: CGPoint?

    override func endRefreshing() {
        if isRefreshing, let list = superview as? UIScrollView {
            offsetBeforeEnd = list.contentOffset
        }
        super.endRefreshing()
    }

    func listDidScroll(_ scrollView: UIScrollView) {
        guard let last = offsetBeforeEnd else { return }
        let now = scrollView.contentOffset
        guard abs(now.y + scrollView.adjustedContentInset.top) < 1 else {
            offsetBeforeEnd = now
            return
        }
        offsetBeforeEnd = nil
        // a list that eased home arrives in small steps
        guard now.y - last.y > 8, !scrollView.isTracking else { return }
        scrollView.contentOffset = last
        UIView.animate(withDuration: 0.3) { scrollView.contentOffset = now }
    }
}
