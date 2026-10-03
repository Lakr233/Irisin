//
//  TableCellStyle.swift
//  MarkdownView
//

import Foundation
import MarkdownParser
import UIKit

/// How a table cell's text is styled from the theme: the header bold, text
/// without a colour in the body colour, and the column's alignment. The
/// table in the document and the full table in the sheet style alike.
@MainActor
struct TableCellStyle {
    let theme: MarkdownTheme

    func styledText(
        from source: NSAttributedString,
        isHeader: Bool,
        alignment: RawTableColumnAlignment
    ) -> NSAttributedString {
        guard let attributedText = source.mutableCopy() as? NSMutableAttributedString else {
            return source
        }
        let range = NSRange(location: 0, length: attributedText.length)

        if isHeader {
            attributedText.enumerateAttribute(.font, in: range, options: []) {
                value, subRange, _ in
                if let existingFont = value as? UIFont {
                    attributedText.addAttribute(.font, value: headerFont(from: existingFont), range: subRange)
                } else {
                    attributedText.addAttribute(.font, value: theme.fonts.bold, range: subRange)
                }
            }
        }

        attributedText.enumerateAttribute(.foregroundColor, in: range, options: []) {
            value, subRange, _ in
            guard value == nil else { return }
            attributedText.addAttribute(
                .foregroundColor,
                value: theme.colors.body,
                range: subRange
            )
        }

        applyParagraphStyle(to: attributedText, alignment: alignment)
        return attributedText
    }

    /// The header weight of `font`, the way `**strong**` text gets it:
    /// body text takes the theme's bold font, and anything else, such as
    /// inline code or a fallback font, keeps its face and gains the bold trait.
    private func headerFont(from font: UIFont) -> UIFont {
        guard font != theme.fonts.body else { return theme.fonts.bold }
        let traits = font.fontDescriptor.symbolicTraits.union(.traitBold)
        return font.fontDescriptor.withSymbolicTraits(traits)
            .map { UIFont(descriptor: $0, size: 0) } ?? font
    }

    private func applyParagraphStyle(
        to attributedText: NSMutableAttributedString,
        alignment: RawTableColumnAlignment
    ) {
        let range = NSRange(location: 0, length: attributedText.length)
        let textAlignment: NSTextAlignment = switch alignment {
        case .center:
            .center
        case .right:
            .right
        case .left, .none:
            .left
        }

        var updates: [(NSRange, NSMutableParagraphStyle)] = []
        attributedText.enumerateAttribute(.paragraphStyle, in: range, options: []) {
            value, subRange, _ in
            let paragraphStyle = (value as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle ?? .init()
            paragraphStyle.alignment = textAlignment
            paragraphStyle.lineBreakMode = .byWordWrapping
            updates.append((subRange, paragraphStyle))
        }
        for (subRange, paragraphStyle) in updates {
            attributedText.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: subRange
            )
        }
    }
}
