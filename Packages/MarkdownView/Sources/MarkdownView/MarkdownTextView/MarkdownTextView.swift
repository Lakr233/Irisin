//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import Combine
import CoreText
import Litext
import MarkdownParser
import UIKit

open class MarkdownTextView: UIView {
    public var linkHandler: ((LinkPayload, NSRange, CGPoint) -> Void)?
    public var codePreviewHandler: ((String?, NSAttributedString) -> Void)?

    public internal(set) var content: MarkdownContent = .init()

    @available(*, deprecated, renamed: "content")
    public var document: MarkdownContent { content }
    public let textLabelView: TextLabelView

    @available(*, deprecated, renamed: "textLabelView")
    public var textView: TextLabelView { textLabelView }
    var themeStorage: MarkdownTheme = .default
    public var theme: MarkdownTheme {
        get { themeStorage }
        set {
            guard themeStorage != newValue else { return }
            applyWithoutRebuilding(theme: newValue)
            use(content)
        }
    }

    /// Scroll view used for auto-scrolling while the user drags a text selection.
    public weak var trackedScrollView: UIScrollView?

    var contextViews: [UIView] = []
    var blockquoteBars: [BlockquoteBarView] = []
    /// What each block rendered to last time, so an unchanged block is not
    /// built again. Held per view because a fragment's drawing callbacks
    /// read from the view they were built for.
    var blockFragmentCache: BlockFragmentCache = .init()
    var cancellables = Set<AnyCancellable>()
    let contentSubject = CurrentValueSubject<MarkdownContent, Never>(.init())
    public var throttleInterval: TimeInterval? = 1 / 20 { // x fps
        didSet { setupCombine() }
    }

    let viewProvider: ReusableViewProvider

    /// - Parameter textLabelView: the label that draws the document body.
    ///   Pass a `TextLabelView` subclass to change how body text is drawn
    ///   while code blocks, tables and selection keep working as before.
    public init(textLabelView: TextLabelView = .init(), viewProvider: ReusableViewProvider = .init()) {
        self.textLabelView = textLabelView
        self.viewProvider = viewProvider
        super.init(frame: .zero)
        textLabelView.isSelectable = true
        textLabelView.backgroundColor = .clear
        textLabelView.selectionBackgroundColor = theme.colors.selectionBackground
        textLabelView.delegate = self
        // The label is sized in `layoutSubviews()` rather than by constraints:
        // its height decides how much text CoreText lays out, and a frame that
        // trails the view by one pass drops the tail of the document.
        addSubview(textLabelView)
        setupCombine()
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override open func layoutSubviews() {
        super.layoutSubviews()
        textLabelView.frame = bounds
        textLabelView.preferredMaxLayoutWidth = bounds.width
        textLabelView.layoutIfNeeded()
        syncContextViewLayout()
    }

    override open var intrinsicContentSize: CGSize {
        textLabelView.intrinsicContentSize
    }

    open func boundingSize(for width: CGFloat) -> CGSize {
        textLabelView.preferredMaxLayoutWidth = width
        return textLabelView.intrinsicContentSize
    }

    /// Decorates one run of rendered body text on its way into the document
    /// — the seam a subclass reaches for to turn plain words into something
    /// richer, an `@mention` chip being the case this exists for.
    ///
    /// Offered for every text run, including those nested inside emphasis,
    /// strong or a link, and never for inline code, math, HTML, or an
    /// image's source: each of those is its own inline node, so a pattern
    /// that appears inside a code span is not mistaken for prose. What the
    /// enclosing node does afterwards still applies — `strong` sweeps its
    /// whole range for fonts, `link` for colour — so a decoration inside
    /// one is styled by it.
    ///
    /// The default returns `text` unchanged. An override may return a
    /// string of a different length, and may carry a Litext attachment: the
    /// result deliberately sits outside the shared inline render cache, so
    /// an attachment view built here belongs to this view alone rather than
    /// to every view that happens to draw the same words. What is handed
    /// *in*, on the other hand, comes straight from that cache and is read
    /// by every other view showing the same words — copy it before
    /// mutating.
    ///
    /// Decorated runs do live in this view's fragment cache across
    /// rebuilds. Call ``invalidateInlineDecoration()`` when whatever an
    /// override reads from has changed.
    open func decorate(inlineText text: NSAttributedString, theme _: MarkdownTheme) -> NSAttributedString {
        text
    }

    /// Rebuilds the document, dropping text decorated against state that
    /// has since moved on.
    public func invalidateInlineDecoration() {
        assert(Thread.isMainThread)
        blockFragmentCache = .init()
        for case let tableView as TableView in contextViews {
            tableView.forgetRenderedSource()
        }
        use(content)
    }

    /// Replaces the displayed content immediately, bypassing the update throttle.
    open func setContentImmediately(_ content: MarkdownContent) {
        assert(Thread.isMainThread)
        resetCombine()
        contentSubject.send(content)
        use(content)
        setupCombine()
    }

    /// Replaces the displayed content and the theme in one build.
    ///
    /// Assigning ``theme`` alone rebuilds the document the view already
    /// holds — right when the theme is all that changed, wasted when new
    /// content lands in the same breath. A view fed themed content from
    /// the outside (a sizing pass serving differently-inked bubbles, a
    /// row being reconfigured) should use this instead of setting the
    /// two properties in sequence.
    open func setContentImmediately(_ content: MarkdownContent, theme: MarkdownTheme) {
        applyWithoutRebuilding(theme: theme)
        setContentImmediately(content)
    }

    /// Stores the theme and restyles the label without rebuilding the
    /// current document — for callers about to replace it anyway.
    func applyWithoutRebuilding(theme: MarkdownTheme) {
        guard themeStorage != theme else { return }
        themeStorage = theme
        textLabelView.selectionBackgroundColor = theme.colors.selectionBackground
    }

    /// Replaces the displayed content, coalesced by ``throttleInterval``.
    /// Safe to call at high frequency (e.g. while streaming).
    open func setContent(_ content: MarkdownContent) {
        contentSubject.send(content)
    }

    /// Parses and displays markdown text in one step.
    /// For streaming or off-main-thread parsing, build a ``MarkdownContent``
    /// yourself and use ``setContent(_:)``.
    public func setMarkdown(_ markdown: String) {
        setContentImmediately(.init(markdown: markdown, theme: theme))
    }

    @available(*, deprecated, renamed: "setContentImmediately(_:)")
    public func setMarkdownManually(_ content: MarkdownContent) {
        setContentImmediately(content)
    }

    @available(*, deprecated, renamed: "setContent(_:)")
    public func setMarkdown(_ content: MarkdownContent) {
        setContent(content)
    }

    open func reset() {
        assert(Thread.isMainThread)
        resetCombine()
        contentSubject.send(.init())
        use(.init())
        setupCombine()
    }

    @available(*, deprecated, renamed: "trackedScrollView")
    public func bindContentOffset(from scrollView: UIScrollView?) {
        trackedScrollView = scrollView
    }
}

