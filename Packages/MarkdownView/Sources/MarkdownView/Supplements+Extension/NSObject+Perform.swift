//
//  NSObject+Perform.swift
//  MarkdownView
//

import Foundation

extension NSObject {
    /// Runs `selector` on this object after `delay`, replacing a run of it
    /// already pending, so calling this again restarts the wait.
    func schedule(_ selector: Selector, after delay: TimeInterval) {
        cancelScheduled(selector)
        perform(selector, with: nil, afterDelay: delay)
    }

    /// Cancels a pending `schedule(_:after:)` of `selector`.
    func cancelScheduled(_ selector: Selector) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: selector, object: nil)
    }
}
