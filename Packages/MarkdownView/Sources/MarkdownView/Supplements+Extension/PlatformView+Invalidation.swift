//
//  PlatformView+Invalidation.swift
//  MarkdownView
//

import UIKit

extension UIView {
    /// Schedules a layout pass: `setNeedsLayout()` on UIKit, `needsLayout`
    /// on AppKit.
    func markNeedsLayout() {
        setNeedsLayout()
    }

    /// Schedules a redraw: `setNeedsDisplay()` on UIKit, `needsDisplay` on
    /// AppKit.
    func markNeedsDisplay() {
        setNeedsDisplay()
    }
}
