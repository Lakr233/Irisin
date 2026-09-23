//
//  BlockFragmentCache.swift
//  MarkdownView
//
//  Created by Claude on 8/8/26.
//

import Foundation
import MarkdownParser

/// The attributed string each block produced, kept across rebuilds.
///
/// A streamed answer arrives one token at a time and every token rebuilds the
/// whole document, so all but the last block is built again to the same bytes.
///
/// Entries are matched on **position and node together**, never on the node
/// alone. Two identical blockquotes in one document must still get two
/// ``BlockquoteGroup`` instances — sharing one would union their spans and
/// paint a single quoting bar straight through the paragraph between them —
/// and the same goes for anything else a block carries by identity. Matching
/// by position also happens to be exactly what a stream needs: positions are
/// stable and only the tail changes.
///
/// Everything that is not per-block is decided once, in ``isUsable(with:)``.
/// A rebuild that cannot reuse anything — a theme change, a different document
/// — should cost a single comparison, not one per block.
struct BlockFragmentCache {
    private struct Entry {
        let node: MarkdownBlockNode
        let fragment: NSAttributedString
    }

    /// One slot per block, in document order. `nil` marks a block that is not
    /// eligible for reuse, so later positions still line up.
    private var entries: [Entry?] = []
    /// The theme these fragments were built against.
    private let theme: MarkdownTheme?

    init() {
        theme = nil
    }

    init(theme: MarkdownTheme, content: MarkdownContent) {
        self.theme = theme
        entries.reserveCapacity(content.blocks.count)
    }

    /// Whether anything in this cache may be reused for the coming build.
    func isUsable(with theme: MarkdownTheme) -> Bool {
        self.theme == theme
    }

    /// The fragment built for this block last time.
    ///
    /// Only call this after ``isUsable(with:)`` has said yes.
    func fragment(at index: Int, matching node: MarkdownBlockNode) -> NSAttributedString? {
        guard entries.indices.contains(index),
              let entry = entries[index],
              entry.node == node
        else { return nil }
        return entry.fragment
    }

    mutating func record(_ fragment: NSAttributedString, for node: MarkdownBlockNode) {
        entries.append(node.isFragmentCacheable ? Entry(node: node, fragment: fragment) : nil)
    }
}

private extension MarkdownBlockNode {
    /// Whether this block's rendering depends on nothing but the block itself.
    ///
    /// Code blocks and tables take a view from ``ReusableViewProvider`` in
    /// document order; serving one from the cache would skip its turn and hand
    /// the next block someone else's view.
    var isFragmentCacheable: Bool {
        switch self {
        case .codeBlock, .table: false
        default: true
        }
    }
}
