//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import CoreText
import Litext
import MarkdownParser
import UIKit

// MARK: - ListProcessor

@MainActor
final class ListProcessor {
    private let theme: MarkdownTheme
    private let context: MarkdownContent
    private let viewProvider: ReusableViewProvider
    private let bulletDrawing: TextBuilder.BulletDrawingCallback?
    private let numberedDrawing: TextBuilder.NumberedDrawingCallback?
    private let checkboxDrawing: TextBuilder.CheckboxDrawingCallback?
    private let inlineTextDecoration: TextBuilder.InlineTextDecoration?

    init(
        theme: MarkdownTheme,
        viewProvider: ReusableViewProvider,
        context: MarkdownContent,
        bulletDrawing: TextBuilder.BulletDrawingCallback?,
        numberedDrawing: TextBuilder.NumberedDrawingCallback?,
        checkboxDrawing: TextBuilder.CheckboxDrawingCallback?,
        inlineTextDecoration: TextBuilder.InlineTextDecoration?
    ) {
        self.theme = theme
        self.viewProvider = viewProvider
        self.context = context
        self.bulletDrawing = bulletDrawing
        self.numberedDrawing = numberedDrawing
        self.checkboxDrawing = checkboxDrawing
        self.inlineTextDecoration = inlineTextDecoration
    }

    func processBulletedList(items: [RawListItem]) -> NSAttributedString {
        let items = flatList(.bulleted(items), currentDepth: 0)
        return renderListItems(items)
    }

    func processNumberedList(startAt index: Int, items: [RawListItem]) -> NSAttributedString {
        let items = flatList(.numbered(index, items), currentDepth: 0)
        return renderListItems(items)
    }

    func processTaskList(items: [RawTaskListItem]) -> NSAttributedString {
        let items = flatList(.task(items), currentDepth: 0)
        return renderListItems(items)
    }

    private func renderListItem(_ item: ListItem, reduceLineSpacing: Bool = false) -> NSAttributedString {
        let paragraphStyle: NSMutableParagraphStyle = .init()
        paragraphStyle.paragraphSpacing = reduceLineSpacing ? theme.spacings.list : theme.spacings.paragraph
        paragraphStyle.lineSpacing = 4
        let indent = CGFloat(item.depth + 1) * ListMarkerLayout.indent
        paragraphStyle.firstLineHeadIndent = indent
        paragraphStyle.headIndent = indent

        let bulletDrawing = bulletDrawing!
        let numberedDrawing = numberedDrawing!
        let checkboxDrawing = checkboxDrawing!
        let string = NSMutableAttributedString()
        let theme = theme
        if item.showsMarker {
            string.append(.init(string: TextLabel.Attachment.replacementText, attributes: [
                .font: theme.fonts.body,
                // A marker is drawn rather than typeset, so the only thing copying it
                // would pick up is the replacement character itself — which pastes as
                // an `[obj]` box. The attachment hands the pasteboard the markdown the
                // drawing stands for instead.
                .litextAttachment: TextLabel.Attachment.hold(
                    attrString: .init(string: Self.markerText(for: item))
                ),
                .litextLineDrawingAction: TextLabel.LineDrawingAction(action: { context, line, lineOrigin in
                    if item.ordered {
                        numberedDrawing(context, line, lineOrigin, item.index)
                    } else if item.isTask {
                        checkboxDrawing(context, line, lineOrigin, item.isDone)
                    } else {
                        bulletDrawing(context, line, lineOrigin, item.depth)
                    }
                }),
            ]))
        }
        string.append(item.paragraph.render(theme: theme, context: context, viewProvider: viewProvider, decoration: inlineTextDecoration))

        string.addAttributes(
            [.paragraphStyle: paragraphStyle],
            range: .init(location: 0, length: string.length)
        )
        string.append(.init(string: "\n"))
        return string
    }

    /// The markdown a drawn list marker stands for, used when the item is copied.
    ///
    /// Depth is expressed with two spaces per level so a copied bullet list nests
    /// the way it looks. An ordered marker is wider than that indent, so a numbered
    /// list nested inside another numbered list pastes back as a flat one.
    private static func markerText(for item: ListItem) -> String {
        let indent = String(repeating: "  ", count: item.depth)
        if item.isTask {
            return indent + (item.isDone ? "- [x] " : "- [ ] ")
        }
        if item.ordered {
            return indent + "\(item.index). "
        }
        return indent + "- "
    }

    private func renderListItems(_ items: [ListItem]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            let rendered = renderListItem(item, reduceLineSpacing: index != items.count - 1)
            result.append(rendered)
        }
        return result
    }
}

// MARK: - List Processing Types and Logic

extension ListProcessor {
    private enum List {
        case bulleted([RawListItem])
        case numbered(Int, [RawListItem])
        case task([RawTaskListItem])
    }

    private struct ListItem {
        let depth: Int
        let ordered: Bool
        let index: Int
        let isTask: Bool
        let isDone: Bool
        let showsMarker: Bool
        let paragraph: [MarkdownInlineNode]

        init(depth: Int, ordered: Bool, index: Int = 0, isTask: Bool = false, isDone: Bool = false, showsMarker: Bool = true, paragraph: [MarkdownInlineNode]) {
            self.depth = depth
            self.ordered = ordered
            self.index = index
            self.isTask = isTask
            self.isDone = isDone
            self.showsMarker = showsMarker
            self.paragraph = paragraph
        }
    }

    private func flatList(_ list: List, currentDepth: Int) -> [ListItem] {
        var result: [ListItem] = []
        var index = 0
        var isOrdered = false

        struct MappedItem {
            let isDone: Bool?
            let nodes: [MarkdownBlockNode]
        }

        func handle(_ items: [MappedItem]) {
            for item in items {
                var isFirstParagraph = true
                for child in item.nodes {
                    switch child {
                    case let .paragraph(contents):
                        let isTask = item.isDone != nil
                        let isDone = item.isDone ?? false
                        result.append(.init(depth: currentDepth, ordered: isOrdered, index: index, isTask: isTask, isDone: isDone, showsMarker: isFirstParagraph, paragraph: contents))
                        if isFirstParagraph { index += 1 }
                        isFirstParagraph = false
                    case let .bulletedList(_, sublist):
                        result.append(contentsOf: flatList(.bulleted(sublist), currentDepth: currentDepth + 1))
                    case let .numberedList(_, start, sublist):
                        result.append(contentsOf: flatList(.numbered(start, sublist), currentDepth: currentDepth + 1))
                    case let .taskList(_, sublist):
                        result.append(contentsOf: flatList(.task(sublist), currentDepth: currentDepth + 1))
                    default:
                        print("WARNING: Unhandled list item: \(child)")
                    }
                }
            }
        }

        switch list {
        case let .bulleted(items):
            let mapped: [MappedItem] = items.map {
                .init(isDone: nil, nodes: $0.children)
            }
            isOrdered = false
            handle(mapped)
        case let .numbered(startAt, items):
            let mapped: [MappedItem] = items.map {
                .init(isDone: nil, nodes: $0.children)
            }
            isOrdered = true
            index = startAt
            handle(mapped)
        case let .task(items):
            let mapped: [MappedItem] = items.map {
                .init(isDone: $0.isCompleted, nodes: $0.children)
            }
            isOrdered = false
            handle(mapped)
        }

        return result
    }
}
