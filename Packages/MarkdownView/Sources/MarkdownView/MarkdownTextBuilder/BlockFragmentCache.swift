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
/// Code blocks and tables are kept together with the view each one placed, so
/// an unchanged one hands back the very attachment and view the label already
/// laid out. The position rule matters most here: two identical code blocks
/// are two entries holding two views, never one view shown twice.
///
/// Everything that is not per-block is decided once, in ``isUsable(with:for:)``.
/// A rebuild that cannot reuse anything — a theme change, a different document
/// — should cost a single comparison, not one per block.
struct BlockFragmentCache {
    private struct Entry {
        let node: MarkdownBlockNode
        let fragment: NSAttributedString
        /// The code or table view the fragment places, which is reused with it.
        let contextView: UIView?
    }

    /// A block served from the cache, with the view it brings along.
    struct Hit {
        let fragment: NSAttributedString
        let contextView: UIView?
    }

    /// One slot per block, in document order. `nil` marks a block that is not
    /// eligible for reuse, so later positions still line up.
    private var entries: [Entry?] = []
    /// The theme these fragments were built against.
    private let theme: MarkdownTheme?
    /// The locale these fragments chose their languages and fallback fonts in.
    ///
    /// Held as the identifier, the same key the shared body-text cache uses.
    private let localeIdentifier: String?

    init() {
        theme = nil
        localeIdentifier = nil
    }

    init(theme: MarkdownTheme, content: MarkdownContent) {
        self.theme = theme
        localeIdentifier = content.locale.identifier
        entries.reserveCapacity(content.blocks.count)
    }

    /// Whether anything in this cache may be reused for the coming build.
    func isUsable(with theme: MarkdownTheme, for content: MarkdownContent) -> Bool {
        self.theme == theme
            && localeIdentifier == content.locale.identifier
    }

    /// The fragment built for this block last time.
    ///
    /// Only call this after ``isUsable(with:)`` has said yes.
    func fragment(at index: Int, matching node: MarkdownBlockNode) -> NSAttributedString? {
        hit(at: index, matching: node)?.fragment
    }

    /// The fragment built for this block last time, and its view.
    ///
    /// A code block or a table comes back with the view it was built around.
    /// That view still belongs to the block only if nothing has handed it to
    /// another one or changed it since; ``TextBuilder`` checks both before
    /// using the hit, because the cache cannot see the view's provider.
    ///
    /// Only call this after ``isUsable(with:for:)`` has said yes.
    func hit(at index: Int, matching node: MarkdownBlockNode) -> Hit? {
        guard entries.indices.contains(index),
              let entry = entries[index],
              entry.node == node
        else { return nil }
        return Hit(fragment: entry.fragment, contextView: entry.contextView)
    }

    /// Records the fragment for the next build.
    ///
    /// A code block or a table is recorded only with the view it placed:
    /// without it the fragment would point at a view the next build cannot
    /// claim back.
    mutating func record(_ fragment: NSAttributedString, contextView: UIView?, for node: MarkdownBlockNode) {
        if node.placesContextView, contextView == nil {
            entries.append(nil)
            return
        }
        entries.append(Entry(node: node, fragment: fragment, contextView: contextView))
    }
}

extension MarkdownBlockNode {
    /// Whether this block draws through a pooled view rather than as text.
    var placesContextView: Bool {
        switch self {
        case .codeBlock, .table: true
        default: false
        }
    }
}
