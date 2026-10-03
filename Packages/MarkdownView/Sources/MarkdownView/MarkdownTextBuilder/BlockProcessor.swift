//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import CoreText
import Litext
import MarkdownParser
import UIKit

// MARK: - BlockProcessor

@MainActor
final class BlockProcessor {
    private let theme: MarkdownTheme
    private let viewProvider: ReusableViewProvider
    private let context: MarkdownContent
    private let thematicBreakDrawing: TextBuilder.DrawingCallback?
    private let inlineTextDecoration: TextBuilder.InlineTextDecoration?

    init(
        theme: MarkdownTheme,
        viewProvider: ReusableViewProvider,
        context: MarkdownContent,
        thematicBreakDrawing: TextBuilder.DrawingCallback?,
        inlineTextDecoration: TextBuilder.InlineTextDecoration?
    ) {
        self.theme = theme
        self.viewProvider = viewProvider
        self.context = context
        self.thematicBreakDrawing = thematicBreakDrawing
        self.inlineTextDecoration = inlineTextDecoration
    }

    func processHeading(level _: Int, contents: [MarkdownInlineNode]) -> NSAttributedString {
        let font: UIFont = theme.fonts.title

        return buildWithParagraphSync { paragraph in
            paragraph.paragraphSpacing = theme.spacings.paragraph
            paragraph.paragraphSpacingBefore = theme.spacings.headingBefore
        } content: {
            let string = contents.render(theme: theme, context: context, decoration: inlineTextDecoration)
            let fullRange = NSRange(location: 0, length: string.length)
            string.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
                // Inline code keeps its monospaced face inside a heading.
                guard (value as? UIFont) != theme.fonts.codeInline else { return }
                string.addAttribute(.font, value: font, range: range)
            }
            // Replacing the font discarded the fallback the body text resolved
            // for its language, so resolve it again for the title font.
            MarkdownContentLocale.resolveFonts(in: string, fallbackLocale: context.locale)
            return string
        }
    }

    func processParagraph(contents: [MarkdownInlineNode]) -> NSAttributedString {
        buildWithParagraphSync { paragraph in
            paragraph.paragraphSpacing = theme.spacings.paragraph
            paragraph.lineSpacing = 4
        } content: {
            let rendered = contents.render(theme: theme, context: context, decoration: inlineTextDecoration)
            if rendered.length == 0 {
                return NSMutableAttributedString(string: " ", attributes: [.font: theme.fonts.body])
            }
            return rendered
        }
    }

    func processThematicBreak() -> NSAttributedString {
        buildWithParagraphSync {
            let drawingCallback = self.thematicBreakDrawing
            return .init(string: TextLabel.Attachment.replacementText, attributes: [
                .font: theme.fonts.body,
                .litextAttachment: TextLabel.Attachment.hold(attrString: .init(string: "\n\n")),
                .litextLineDrawingAction: TextLabel.LineDrawingAction(action: { context, line, lineOrigin in
                    drawingCallback?(context, line, lineOrigin)
                }),
            ])
        }
    }

    func processCodeBlock(
        language: String?,
        content: String
    ) -> (NSAttributedString, CodeView) {
        let content = content.deletingSuffix(of: .whitespacesAndNewlines)
        let codeView = viewProvider.acquireCodeView()
        codeView.theme = theme
        codeView.language = language ?? ""
        codeView.content = content
        let appearance = ContextViewAttachment.Appearance.of(codeView)
        let text = buildWithParagraphSync { paragraph in
            // Reserve exactly what the view will occupy. Estimating the height from
            // the source text instead lets the two numbers drift apart, and the view
            // then paints over whatever follows it.
            paragraph.minimumLineHeight = appearance.size.height
        } content: {
            .init(string: TextLabel.Attachment.replacementText, attributes: [
                .font: theme.fonts.body,
                .litextAttachment: ContextViewAttachment(
                    representation: .init(string: content + "\n"),
                    appearance: appearance
                ),
                .contextView: codeView,
            ])
        }
        return (text, codeView)
    }

    func processBlockquote(_ children: [MarkdownBlockNode]) -> NSAttributedString {
        guard !children.isEmpty else { return NSAttributedString() }

        let result = NSMutableAttributedString()

        let baseParagraphStyle = NSMutableParagraphStyle()
        baseParagraphStyle.firstLineHeadIndent = 16
        baseParagraphStyle.headIndent = 16
        // No tail indent: a negative one hides from line origins and widths, so
        // the text layout gives up measuring from the laid-out frame and
        // typesets every document holding a quote twice per update.
        baseParagraphStyle.paragraphSpacing = 8
        baseParagraphStyle.lineSpacing = 4

        for child in children {
            guard case let .paragraph(content) = child else {
                assertionFailure("Blockquote should only contain paragraphs after flattening")
                continue
            }
            let paragraphContent = content.render(theme: theme, context: context, decoration: inlineTextDecoration)
            result.append(paragraphContent)
            if !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: [.font: theme.fonts.body]))
            }
        }

        while result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        guard result.length > 0 else { return result }
//        result.append(.init(string: "\n"))

        // The quoting bar is positioned from these runs after layout rather than
        // stroked while drawing: a line drawing action only runs for the lines a
        // redraw happens to touch, so a bar painted from one line's action comes
        // out clipped to whatever band was dirty.
        result.addAttributes(
            [
                .paragraphStyle: baseParagraphStyle,
                .blockquoteGroup: BlockquoteGroup(),
            ],
            range: NSRange(location: 0, length: result.length)
        )
        result.append(.init(string: "\n", attributes: [
            .font: theme.fonts.body,
            .paragraphStyle: baseParagraphStyle,
        ]))

        return result
    }

    func processTable(
        columnAlignments: [RawTableColumnAlignment],
        rows: [RawTableRow]
    ) -> (NSAttributedString, TableView) {
        let tableView = viewProvider.acquireTableView()
        let representedText: NSAttributedString
        if let reused = tableView.representedText(
            reusingRows: rows,
            columnAlignments: columnAlignments,
            theme: theme,
            content: context
        ) {
            representedText = reused
        } else {
            let contents = rows.map {
                $0.cells.map { rawCell in
                    rawCell.content.render(theme: theme, context: context, decoration: inlineTextDecoration)
                }
            }
            let allContent = contents
                .map { $0.map(\.string).joined(separator: "\t") }
                .joined(separator: "\n")
            representedText = NSAttributedString(string: allContent + "\n")
            tableView.setTheme(theme)
            tableView.setContents(contents, columnAlignments: columnAlignments)
            tableView.rememberRenderedSource(
                rows: rows,
                columnAlignments: columnAlignments,
                theme: theme,
                content: context,
                representedText: representedText
            )
        }

        let appearance = ContextViewAttachment.Appearance.of(tableView)
        let text = buildWithParagraphSync { paragraph in
            paragraph.minimumLineHeight = appearance.size.height
        } content: {
            .init(string: TextLabel.Attachment.replacementText, attributes: [
                .font: theme.fonts.body,
                .litextAttachment: ContextViewAttachment(
                    representation: representedText,
                    appearance: appearance
                ),
                .contextView: tableView,
            ])
        }
        return (text, tableView)
    }
}

// MARK: - Paragraph Helper

extension BlockProcessor {
    private func buildWithParagraphSync(
        withNewLine: Bool = true,
        modifier: (inout NSMutableParagraphStyle) -> Void = { _ in },
        content: () -> NSMutableAttributedString
    ) -> NSMutableAttributedString {
        var paragraphStyle: NSMutableParagraphStyle = .init()
        paragraphStyle.paragraphSpacing = theme.spacings.paragraph
        paragraphStyle.lineSpacing = 4
        modifier(&paragraphStyle)

        let string = content()
        string.addAttributes(
            [.paragraphStyle: paragraphStyle],
            range: .init(location: 0, length: string.length)
        )
        if withNewLine, !string.string.hasSuffix("\n") {
            string.append(.init(string: "\n"))
        }
        return string
    }
}
