//
//  MarkdownContent.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/5/25.
//

import Foundation
import LRUCache
import MarkdownParser

/// Parsed markdown, ready for display in ``MarkdownTextView``.
///
/// Build one off the main thread for streaming scenarios, or use
/// ``init(markdown:theme:locale:)`` for one-shot rendering.
public final class MarkdownContent: @unchecked Sendable {
    /// What a rendered piece of body text depends on.
    ///
    /// The font and colour are held as themselves rather than as a formatted
    /// description of them. Describing them cost more than every other part of
    /// rendering the text put together, and it also made two colours that
    /// happen to resolve alike today share one entry — which hands a caller
    /// asking for a dynamic colour a copy frozen in the current appearance.
    /// Fonts and colours are immutable once handed to a theme, so a key holding
    /// them can cross the actor boundary the cache requires.
    private struct InlineRenderCacheKey: Hashable, @unchecked Sendable {
        let text: String
        let localeIdentifier: String
        let font: UIFont
        let color: UIColor
    }

    /// Rendered body text, shared by every content rather than owned by one.
    ///
    /// Streaming builds a fresh ``MarkdownContent`` for each token, so a cache
    /// living on the instance never saw a second lookup in the one situation it
    /// exists for. Shared, a stream re-renders only the paragraph that grew.
    /// Bounded by entry count, and cleared under memory pressure by `LRUCache`.
    @MainActor private static let inlineRenderCache =
        LRUCache<InlineRenderCacheKey, NSAttributedString>(countLimit: 4096)

    public let blocks: [MarkdownBlockNode]
    public let locale: Locale

    public init(
        blocks: [MarkdownBlockNode],
        locale: Locale = .autoupdatingCurrent
    ) {
        self.blocks = blocks
        self.locale = locale
    }

    public init(
        parserResult: MarkdownParser.ParseResult,
        theme _: MarkdownTheme,
        locale: Locale = .autoupdatingCurrent
    ) {
        blocks = parserResult.document
        self.locale = locale
    }

    /// Parses markdown text and pre-renders it in one step.
    @MainActor
    public convenience init(
        markdown: String,
        theme: MarkdownTheme = .default,
        locale: Locale = .autoupdatingCurrent
    ) {
        self.init(
            parserResult: MarkdownParser().parse(markdown),
            theme: theme,
            locale: locale
        )
    }

    public init() {
        blocks = .init()
        locale = .autoupdatingCurrent
    }

    @MainActor
    func cachedBodyText(_ text: String, theme: MarkdownTheme) -> NSAttributedString {
        let key = InlineRenderCacheKey(
            text: text,
            localeIdentifier: locale.identifier,
            font: theme.fonts.body,
            color: theme.colors.body
        )
        if let cached = Self.inlineRenderCache.value(forKey: key) {
            return cached
        }

        let rendered = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: theme.fonts.body,
                .foregroundColor: theme.colors.body,
            ]
        )
        MarkdownContentLocale.applyLanguageAttributes(
            to: rendered,
            fallbackLocale: locale
        )
        // Resolve the fallback font here, once per distinct piece of text,
        // rather than leaving it to the pass over the finished document.
        // The body font covers no CJK and no emoji, so that pass was asking
        // CoreText for a substitute for the same runs on every rebuild — a
        // third of the cost of a streaming update.
        rendered.fixAttributes(in: NSRange(location: 0, length: rendered.length))
        // With the font resolved, the language attribute has done its job for
        // most scripts — and carrying it into the document triples the cost of
        // building a framesetter, which is paid again on every rebuild. It stays
        // only where it still changes what the reader sees.
        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.coreTextLanguage, in: fullRange, options: []) { value, range, _ in
            guard let language = value as? String,
                  !MarkdownContentLocale.affectsShaping(language)
            else { return }
            rendered.removeAttribute(.coreTextLanguage, range: range)
        }
        let cached = rendered.copy() as! NSAttributedString
        Self.inlineRenderCache.setValue(cached, forKey: key)
        return cached
    }
}

public extension MarkdownTextView {
    @available(*, deprecated, renamed: "MarkdownContent")
    typealias PreprocessedContent = MarkdownContent
}
