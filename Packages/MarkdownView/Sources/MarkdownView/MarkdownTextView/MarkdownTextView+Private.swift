//
//  MarkdownTextView+Private.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import Combine
import Foundation
import Litext

extension MarkdownTextView {
    func resetCombine() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    func setupCombine() {
        resetCombine()
        if let throttleInterval {
            contentSubject
                .dropFirst()
                .throttle(for: .seconds(throttleInterval), scheduler: DispatchQueue.main, latest: true)
                .sink { [weak self] content in self?.use(content) }
                .store(in: &cancellables)
        } else {
            contentSubject
                .dropFirst()
                .sink { [weak self] content in self?.use(content) }
                .store(in: &cancellables)
        }
    }

    /// Rebuilds the throttle for a new interval.
    ///
    /// The old throttle may be holding content it has not delivered yet, and
    /// the new subscription drops the subject's current value, so that
    /// content is shown now rather than lost.
    func resubscribeKeepingPendingContent() {
        setupCombine()
        let pending = contentSubject.value
        guard pending !== content else { return }
        use(pending)
    }

    /// Hands the current handlers to the code and table views already on
    /// screen; layout does the same for views placed later.
    func syncContextViewHandlers() {
        for view in contextViews {
            if let codeView = view as? CodeView {
                codeView.previewAction = codePreviewHandler
                codeView.actionProvider = codeBlockActionProvider
            } else if let tableView = view as? TableView {
                tableView.linkHandler = linkHandler
            }
        }
    }

    /// Rebuilds the document for `content`.
    ///
    /// `resizes` is false for a rebuild that only recolours what is on
    /// screen, which leaves the height alone and so need not send SwiftUI back
    /// through `sizeThatFits(_:)`.
    func use(_ content: MarkdownContent, resizes: Bool = true) {
        assert(Thread.isMainThread)
        self.content = content
        // due to a bug in model gemini-flash
        // there might be a large of unknown empty whitespace inside the table
        // thus we hereby call the autoreleasepool to avoid large memory consumption
        autoreleasepool { updateTextExecute() }
        // The height changes with the document. Auto Layout hosts and the
        // SwiftUI representable both learn of it only through this.
        if resizes {
            invalidateIntrinsicContentSize()
        }

        layoutIfNeeded()
    }
}
