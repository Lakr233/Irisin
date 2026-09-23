//
//  InlineNode+Render.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2025/1/3.
//

import Foundation
import Litext
import MarkdownParser
import UIKit

extension [MarkdownInlineNode] {
    @MainActor
    func render(
        theme: MarkdownTheme,
        context: MarkdownContent,
        viewProvider: ReusableViewProvider,
        decoration: TextBuilder.InlineTextDecoration? = nil
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for node in self {
            result.append(node.render(
                theme: theme,
                context: context,
                viewProvider: viewProvider,
                decoration: decoration
            ))
        }
        return result
    }
}

extension MarkdownInlineNode {
    @MainActor
    func render(
        theme: MarkdownTheme,
        context: MarkdownContent,
        viewProvider: ReusableViewProvider,
        decoration: TextBuilder.InlineTextDecoration? = nil
    ) -> NSAttributedString {
        assert(Thread.isMainThread)
        switch self {
        case let .text(string):
            // Past the cache, never into it: a decoration may carry an
            // attachment, and an attachment holds a view, which belongs to the
            // one text view it was built for rather than to every view that
            // draws the same words.
            let rendered = context.cachedBodyText(string, theme: theme)
            return decoration?(rendered) ?? rendered
        case .softBreak:
            return context.cachedBodyText(" ", theme: theme)
        case .lineBreak:
            return context.cachedBodyText("\n", theme: theme)
        case let .code(string), let .html(string):
            let controlAttributes: [NSAttributedString.Key: Any] = [
                .font: theme.fonts.codeInline,
                .backgroundColor: theme.colors.codeBackground.withAlphaComponent(0.05),
            ]
            let text = NSMutableAttributedString(string: string, attributes: [.foregroundColor: theme.colors.code])
            text.addAttributes(controlAttributes, range: .init(location: 0, length: text.length))
            return text
        case let .emphasis(children):
            let ans = NSMutableAttributedString()
            children
                .map { $0.render(theme: theme, context: context, viewProvider: viewProvider, decoration: decoration) }
                .forEach { ans.append($0) }
            ans.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: theme.colors.emphasis,
                ],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .strong(children):
            let ans = NSMutableAttributedString()
            children
                .map { $0.render(theme: theme, context: context, viewProvider: viewProvider, decoration: decoration) }
                .forEach { ans.append($0) }
            ans.enumerateAttribute(.font, in: NSRange(location: 0, length: ans.length)) { value, range, _ in
                guard let font = value as? UIFont, font != theme.fonts.body else {
                    ans.addAttribute(.font, value: theme.fonts.bold, range: range)
                    return
                }
                let traits = font.fontDescriptor.symbolicTraits.union(.traitBold)
                let boldFont = font.fontDescriptor.withSymbolicTraits(traits)
                    .map { UIFont(descriptor: $0, size: 0) } ?? font
                ans.addAttribute(.font, value: boldFont, range: range)
            }
            return ans
        case let .strikethrough(children):
            let ans = NSMutableAttributedString()
            children
                .map { $0.render(theme: theme, context: context, viewProvider: viewProvider, decoration: decoration) }
                .forEach { ans.append($0) }
            ans.addAttributes(
                [.strikethroughStyle: NSUnderlineStyle.thick.rawValue],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .link(destination, children):
            let ans = NSMutableAttributedString()
            children
                .map { $0.render(theme: theme, context: context, viewProvider: viewProvider, decoration: decoration) }
                .forEach { ans.append($0) }
            ans.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: theme.colors.highlight,
                ],
                range: NSRange(location: 0, length: ans.length)
            )
            return ans
        case let .image(source, _): // children => alternative text can be ignored?
            return NSAttributedString(
                string: source,
                attributes: [
                    .link: source,
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ]
            )
        }
    }
}
