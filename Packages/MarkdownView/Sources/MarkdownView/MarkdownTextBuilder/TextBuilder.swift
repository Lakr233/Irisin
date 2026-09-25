//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import CoreText
import Litext
import MarkdownParser
import UIKit

@MainActor
final class TextBuilder {
    private let nodes: [MarkdownBlockNode]
    private let viewProvider: ReusableViewProvider
    private var theme: MarkdownTheme = .default
    private let text: NSMutableAttributedString = .init()
    private let context: MarkdownContent

    private var bulletDrawing: BulletDrawingCallback?
    private var numberedDrawing: NumberedDrawingCallback?
    private var checkboxDrawing: CheckboxDrawingCallback?
    private var thematicBreakDrawing: DrawingCallback?
    private var inlineTextDecoration: InlineTextDecoration?

    init(
        nodes: [MarkdownBlockNode],
        context: MarkdownContent,
        viewProvider: ReusableViewProvider
    ) {
        self.nodes = nodes
        self.context = context
        self.viewProvider = viewProvider
    }

    func withTheme(_ theme: MarkdownTheme) -> TextBuilder {
        self.theme = theme
        return self
    }

    func withBulletDrawing(_ drawing: @escaping BulletDrawingCallback) -> TextBuilder {
        bulletDrawing = drawing
        return self
    }

    func withNumberedDrawing(_ drawing: @escaping NumberedDrawingCallback) -> TextBuilder {
        numberedDrawing = drawing
        return self
    }

    func withCheckboxDrawing(_ drawing: @escaping CheckboxDrawingCallback) -> TextBuilder {
        checkboxDrawing = drawing
        return self
    }

    func withThematicBreakDrawing(_ drawing: @escaping DrawingCallback) -> TextBuilder {
        thematicBreakDrawing = drawing
        return self
    }

    func withInlineTextDecoration(_ decoration: @escaping InlineTextDecoration) -> TextBuilder {
        inlineTextDecoration = decoration
        return self
    }

    func withFragmentCache(_ cache: BlockFragmentCache) -> TextBuilder {
        fragmentCache = cache
        return self
    }

    struct BuildResult {
        let document: NSAttributedString
        let subviews: [UIView]
        /// What this build produced, to hand back to the next one.
        let fragmentCache: BlockFragmentCache
    }

    private var fragmentCache: BlockFragmentCache = .init()

    private var previouslyBuilt = false
    func build() -> BuildResult {
        assert(!previouslyBuilt, "TextBuilder can only be built once.")
        previouslyBuilt = true
        var subviewCollector = [UIView]()
        var nextFragmentCache = BlockFragmentCache(theme: theme, content: context)
        let reusesFragments = fragmentCache.isUsable(with: theme)
        var fragments = [NSAttributedString]()
        fragments.reserveCapacity(nodes.count)
        // Where each newly built block landed, so its fonts can be resolved
        // after the fact and the resolved copy kept for the next build.
        var builtRanges = [(slot: Int, range: NSRange)]()

        for (index, node) in nodes.enumerated() {
            if reusesFragments, let cached = fragmentCache.fragment(at: index, matching: node) {
                text.append(cached)
                fragments.append(cached)
                continue
            }
            let start = text.length
            let built = processBlock(node, context: context, subviews: &subviewCollector)
            text.append(built)
            builtRanges.append((fragments.count, NSRange(location: start, length: built.length)))
            fragments.append(built)
        }

        for run in Self.coalesced(builtRanges.map(\.range)) {
            text.fixAttributes(in: run)
        }
        for (slot, range) in builtRanges {
            fragments[slot] = text.attributedSubstring(from: range)
        }

        for (index, node) in nodes.enumerated() {
            nextFragmentCache.record(fragments[index], for: node)
        }
        return .init(
            document: text,
            subviews: subviewCollector,
            fragmentCache: nextFragmentCache
        )
    }
}

// MARK: - Block Processing

extension TextBuilder {
    /// Neighbouring ranges merged into one, so a stretch of freshly built
    /// blocks is resolved in a single pass rather than one pass per block.
    ///
    /// A first render builds every block, and merging turns that back into the
    /// one sweep it has always been; a streamed update builds only the tail,
    /// and pays for the tail alone.
    private static func coalesced(_ ranges: [NSRange]) -> [NSRange] {
        var merged = [NSRange]()
        for range in ranges where range.length > 0 {
            if let last = merged.last, last.upperBound == range.location {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: last.length + range.length
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func processBlock(
        _ node: MarkdownBlockNode,
        context: MarkdownContent,
        subviews: inout [UIView]
    ) -> NSAttributedString {
        let blockProcessor = BlockProcessor(
            theme: theme,
            viewProvider: viewProvider,
            context: context,
            thematicBreakDrawing: thematicBreakDrawing,
            inlineTextDecoration: inlineTextDecoration
        )

        let listProcessor = ListProcessor(
            theme: theme,
            viewProvider: viewProvider,
            context: context,
            bulletDrawing: bulletDrawing,
            numberedDrawing: numberedDrawing,
            checkboxDrawing: checkboxDrawing,
            inlineTextDecoration: inlineTextDecoration
        )

        switch node {
        case let .heading(level, contents):
            return blockProcessor.processHeading(level: level, contents: contents)
        case let .paragraph(contents):
            return blockProcessor.processParagraph(contents: contents)
        case let .bulletedList(_, items):
            return listProcessor.processBulletedList(items: items)
        case let .numberedList(_, index, items):
            return listProcessor.processNumberedList(startAt: index, items: items)
        case let .taskList(_, items):
            return listProcessor.processTaskList(items: items)
        case .thematicBreak:
            return blockProcessor.processThematicBreak()
        case let .codeBlock(language, content):
            let result = blockProcessor.processCodeBlock(language: language, content: content)
            subviews.append(result.1)
            return result.0
        case let .blockquote(children):
            return blockProcessor.processBlockquote(children)
        case let .table(columnAlignments, rows):
            let result = blockProcessor.processTable(
                columnAlignments: columnAlignments,
                rows: rows
            )
            subviews.append(result.1)
            return result.0
        }
    }
}
