//
//  PlatformView+Placement.swift
//  MarkdownView
//

import UIKit

/// Runs `changes` with animations off, explicit and implicit alike.
///
/// A host often updates the document inside an animation block, and a view
/// placed for the first time there would grow out of a zero frame — and its
/// subviews with it — instead of appearing where it belongs.
@MainActor
func withoutAnimation(_ changes: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    UIView.performWithoutAnimation(changes)
    CATransaction.commit()
}

extension UIView {
    /// Whether the view has never been given a frame.
    var isUnplaced: Bool {
        frame == .zero
    }

    /// Gives the view `frame` and lays its subviews out at that size, without
    /// animation, then adds it to `parent` when it is not there yet.
    ///
    /// The frame comes first, so the view is never inside `parent` at a size
    /// it does not have.
    func place(at frame: CGRect, in parent: UIView) {
        withoutAnimation {
            self.frame = frame
            if superview !== parent {
                parent.addSubview(self)
            }
            layoutNow()
        }
    }

    /// Sets `frame`, without animation when it is the view's first.
    func applyFrame(_ frame: CGRect) {
        guard self.frame != frame else { return }
        guard isUnplaced else {
            self.frame = frame
            return
        }
        withoutAnimation {
            self.frame = frame
            layoutNow()
        }
    }

    /// Runs any pending layout now: `layoutIfNeeded()` on UIKit,
    /// `layoutSubtreeIfNeeded()` on AppKit.
    func layoutNow() {
        layoutIfNeeded()
    }
}
