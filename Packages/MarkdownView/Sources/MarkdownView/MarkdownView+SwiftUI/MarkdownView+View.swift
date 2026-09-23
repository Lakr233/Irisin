//
//  MarkdownView+View.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2026/2/1.
//

import MarkdownParser
import SwiftUI

public struct MarkdownView: View {
    @available(*, deprecated, renamed: "MarkdownContent")
    public typealias PreprocessedContent = MarkdownContent

    enum ContentSource {
        case text(String)
        case content(MarkdownContent)
    }

    let contentSource: ContentSource
    public var theme: MarkdownTheme

    public init(_ text: String, theme: MarkdownTheme = .default) {
        contentSource = .text(text)
        self.theme = theme
    }

    public init(_ content: MarkdownContent, theme: MarkdownTheme = .default) {
        contentSource = .content(content)
        self.theme = theme
    }

    public var body: some View {
        // Single-phase layout: the representable reports its height
        // synchronously through sizeThatFits(_:), so no measured-height
        // state (and no second layout pass) is needed here.
        MarkdownViewRepresentable(
            contentSource: contentSource,
            theme: theme
        )
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
