//
//  Motion.swift
//  Irisin
//
//  How progress moves on screen.
//

import UIKit

extension UIView {
    /// How progress moves to its next value, the refreshing repository's
    /// background first: a short ease-out that picks up from wherever the
    /// last step is on screen, so updates arriving mid-flight never jump.
    /// `changes` sets the new value and lays the view out.
    static func animateProgress(_ changes: @escaping () -> Void) {
        animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
            animations: changes
        )
    }
}

extension UIProgressView {
    /// The bar's own animation is not the one above. Forward it moves like
    /// every other progress; backward, or off screen, it jumps.
    func moveProgress(to value: Float) {
        guard value > progress, window != nil else {
            return setProgress(value, animated: false)
        }
        UIView.animateProgress {
            self.setProgress(value, animated: false)
            self.layoutIfNeeded()
        }
    }
}
