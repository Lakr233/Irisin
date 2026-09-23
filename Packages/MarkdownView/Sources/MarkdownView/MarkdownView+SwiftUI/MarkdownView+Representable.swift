//
//  MarkdownView+Representable.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2026/2/1.
//

import SwiftUI
import UIKit

struct MarkdownViewRepresentable: UIViewRepresentable, MarkdownViewRepresentableBase {
    let contentSource: MarkdownView.ContentSource
    let theme: MarkdownTheme

    func makeUIView(context _: Context) -> MarkdownTextView {
        createMarkdownTextView()
    }

    func updateUIView(_ uiView: MarkdownTextView, context: Context) {
        updateMarkdownTextView(uiView, coordinator: context.coordinator)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MarkdownTextView,
        context: Context
    ) -> CGSize? {
        context.coordinator.sizeThatFits(proposal, for: uiView)
    }

    func makeCoordinator() -> MarkdownViewCoordinator {
        MarkdownViewCoordinator()
    }
}

