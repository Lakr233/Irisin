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

    /// The code and table views the view showed until this build, the only
    /// ones a cached block may bring back.
    func withOwnedContextViews(_ views: [UIView]) -> TextBuilder {
        ownedContextViews = Set(views.map(ObjectIdentifier.init))
        return self
    }

    struct BuildResult {
        let document: NSAttributedString
        let subviews: [UIView]
        /// What this build produced, to hand back to the next one.
        let fragmentCache: BlockFragmentCache
    }

    private var fragmentCache: BlockFragmentCache = .init()
    private var ownedContextViews: Set<ObjectIdentifier> = []

    private var previouslyBuilt = false
    func build() -> BuildResult {
        assert(!previouslyBuilt, "TextBuilder can only be built once.")
        previouslyBuilt = true
        var subviewCollector = [UIView]()
        var nextFragmentCache = BlockFragmentCache(theme: theme, content: context)
        let hits = reusableHits()
        var fragments = [NSAttributedString]()
        fragments.reserveCapacity(nodes.count)
        var contextViews = [UIView?]()
        contextViews.reserveCapacity(nodes.count)
        // Where each newly built block landed, so its fonts can be resolved
        // after the fact and the resolved copy kept for the next build.
        var builtRanges = [(slot: Int, range: NSRange)]()

        for (index, node) in nodes.enumerated() {
            if let hit = hits[index] {
                text.append(hit.fragment)
                fragments.append(hit.fragment)
                contextViews.append(hit.contextView)
                if let contextView = hit.contextView {
                    subviewCollector.append(contextView)
                }
                continue
            }
            let start = text.length
            let subviewCount = subviewCollector.count
            let built = processBlock(node, context: context, subviews: &subviewCollector)
            text.append(built)
            builtRanges.append((fragments.count, NSRange(location: start, length: built.length)))
            fragments.append(built)
            contextViews.append(subviewCollector.count > subviewCount ? subviewCollector.last : nil)
        }

        for run in Self.coalesced(builtRanges.map(\.range)) {
            text.fixAttributes(in: run)
        }
        for (slot, range) in builtRanges {
            fragments[slot] = text.attributedSubstring(from: range)
        }

        for (index, node) in nodes.enumerated() {
            nextFragmentCache.record(fragments[index], contextView: contextViews[index], for: node)
        }
        return .init(
            document: text,
            subviews: subviewCollector,
            fragmentCache: nextFragmentCache
        )
    }
}

// MARK: - Block Reuse

extension TextBuilder {
    /// The blocks this build takes from the cache, by position.
    ///
    /// Decided before anything is built: a code block or a table brings its
    /// view back, and that view has to leave the pool before a block built
    /// earlier in the document can acquire it. A view comes back only when
    /// the view showed it until now, nobody else holds it, and it still looks
    /// exactly as the fragment reserved room for. On any doubt the block is
    /// built again, which is what every code block and table did before they
    /// were cached.
    private func reusableHits() -> [BlockFragmentCache.Hit?] {
        var hits = [BlockFragmentCache.Hit?](repeating: nil, count: nodes.count)
        guard fragmentCache.isUsable(with: theme, for: context) else { return hits }
        for (index, node) in nodes.enumerated() {
            guard let hit = fragmentCache.hit(at: index, matching: node) else { continue }
            if let contextView = hit.contextView {
                guard ownedContextViews.contains(ObjectIdentifier(contextView)),
                      Self.stillMatches(contextView, fragment: hit.fragment),
                      viewProvider.withdraw(contextView)
                else { continue }
            }
            hits[index] = hit
        }
        return hits
    }

    /// Whether `view` still shows what `fragment` was built around, at the
    /// size the fragment reserved for it.
    private static func stillMatches(_ view: UIView, fragment: NSAttributedString) -> Bool {
        var attachment: ContextViewAttachment?
        var placed: UIView?
        fragment.enumerateAttributes(
            in: NSRange(location: 0, length: fragment.length),
            options: []
        ) { attributes, _, stop in
            guard let found = attributes[.litextAttachment] as? ContextViewAttachment else { return }
            attachment = found
            placed = attributes[.contextView] as? UIView
            stop.pointee = true
        }
        guard let attachment, placed === view else { return false }
        if let codeView = view as? CodeView {
            return attachment.appearance == .of(codeView)
        }
        if let tableView = view as? TableView {
            return attachment.appearance == .of(tableView)
        }
        return false
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
