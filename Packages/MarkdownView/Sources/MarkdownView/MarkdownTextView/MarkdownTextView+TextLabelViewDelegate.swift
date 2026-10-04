//
//  MarkdownTextView+TextLabelViewDelegate.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import Litext

// The delegate methods live in the class body, so a subclass can override
// them; see `MarkdownTextView`.
extension MarkdownTextView: TextLabelViewDelegate {}

extension MarkdownTextView {
    func autoScroll(_ scrollView: UIScrollView, toFollowDragAt location: CGPoint, in label: TextLabelView) {
        guard scrollView.contentSize.height > scrollView.bounds.height else { return }

        let edgeDetection = CGFloat(16)
        let scrollViewVisibleRect = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
            .insetBy(dx: -10000, dy: edgeDetection)
        let locationInScrollView = label.convert(location, to: scrollView)
        guard !scrollViewVisibleRect.contains(locationInScrollView) else {
            return
        }

        var currentOffset = scrollView.contentOffset
        if locationInScrollView.y < scrollViewVisibleRect.minY {
            currentOffset.y -= abs(scrollViewVisibleRect.minY - locationInScrollView.y)
        } else {
            currentOffset.y += abs(locationInScrollView.y - scrollViewVisibleRect.maxY)
        }
        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        )
        currentOffset.y = min(max(currentOffset.y, minOffsetY), maxOffsetY)
        scrollView.setContentOffset(currentOffset, animated: false)
    }
}
