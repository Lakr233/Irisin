//
//  MarkdownView+RepresentableBase.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2026/2/1.
//

import MarkdownParser
import SwiftUI

@MainActor
protocol MarkdownViewRepresentableBase {
    var contentSource: MarkdownView.ContentSource { get }
    var theme: MarkdownTheme { get }
}

extension MarkdownViewRepresentableBase {
    func createMarkdownTextView() -> MarkdownTextView {
        let view = MarkdownTextView()
        view.theme = theme
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateMarkdownTextView(_ view: MarkdownTextView, coordinator: MarkdownViewCoordinator) {
        switch contentSource {
        case let .text(text):
            let needsUpdate = coordinator.targetText != text
                || coordinator.targetTheme != theme
            if needsUpdate {
                coordinator.setTextThrottled(text, theme: theme, on: view)
            }

        case let .content(markdownContent):
            let needsUpdate = coordinator.lastContent !== markdownContent
                || coordinator.lastTheme != theme
            if needsUpdate {
                coordinator.cancelScheduledApply()
                coordinator.lastText = ""
                coordinator.lastParseResult = nil
                coordinator.lastContent = markdownContent
                view.setContentImmediately(markdownContent, theme: theme)
                view.invalidateIntrinsicContentSize()
                coordinator.lastTheme = theme
            }
        }
    }
}
