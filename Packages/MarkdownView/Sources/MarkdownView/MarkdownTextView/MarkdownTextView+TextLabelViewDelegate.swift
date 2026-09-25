//
//  MarkdownTextView+TextLabelViewDelegate.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import Litext
import UIKit

extension MarkdownTextView: TextLabelViewDelegate {
    public func textLabelView(_: TextLabelView, didChangeSelection _: NSRange?) {
        // reserved for future use
    }

    public func textLabelView(_ label: TextLabelView, didDragSelectionAt location: CGPoint) {
        guard let scrollView = trackedScrollView else { return }
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

    public func textLabelView(_: TextLabelView, didTapHighlightRegion highlightRegion: TextLabel.HighlightRegion, at location: CGPoint) {
        let link = highlightRegion.attributes[NSAttributedString.Key.link]
        let range = highlightRegion.stringRange
        if let url = link as? URL {
            linkHandler?(.url(url), range, location)
        } else if let string = link as? String {
            linkHandler?(.string(string), range, location)
        }
    }
}
