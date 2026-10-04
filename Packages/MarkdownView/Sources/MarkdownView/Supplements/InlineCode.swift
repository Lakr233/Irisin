//
//  InlineCode.swift
//  MarkdownView
//

import CoreText
import Foundation
import Litext
import UIKit

extension NSAttributedString.Key {
    /// Carries the `InlineCodeBackground` an inline code span is drawn on.
    static let inlineCodeBackground = NSAttributedString.Key("MarkdownView.inlineCodeBackground")
}

/// Inline code as a rounded pill: monospaced text at the body's size, on a
/// background inset a few points past the text on either side.
@MainActor
enum InlineCode {
    /// Space between the pill's edge and the text, on each side.
    static let horizontalInset: CGFloat = 4
    /// Space past the text where a wrapped span breaks, and so has no spacer
    /// on that side of the line.
    static let wrappedEndInset: CGFloat = 2
    /// How far the pill reaches above and below the code font's glyph box.
    static let verticalInset: CGFloat = 1
    static let cornerRadius: CGFloat = 5

    /// `<br>`, `<br/>` or `<br />`, which a table cell uses for a line break
    /// and which reads as one, not as code.
    nonisolated static func isLineBreak(_ html: String) -> Bool {
        let tag = html.lowercased().filter { !$0.isWhitespace }
        return tag == "<br>" || tag == "<br/>"
    }

    /// Where `run` starts and ends on its line. A run's glyphs sit side by
    /// side, so whichever end is leftmost, in either direction, starts it and
    /// its typographic width spans the rest; this costs no lookup of the
    /// line's character clusters, which offsets by string index do.
    nonisolated static func horizontalExtent(of run: CTRun) -> (CGFloat, CGFloat)? {
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return nil }
        var first = CGPoint.zero
        var last = CGPoint.zero
        CTRunGetPositions(run, CFRange(location: 0, length: 1), &first)
        CTRunGetPositions(run, CFRange(location: count - 1, length: 1), &last)
        let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
        let start = min(first.x, last.x)
        return (start, start + width)
    }

    static func attributedString(_ string: String, theme: MarkdownTheme) -> NSAttributedString {
        let font = theme.fonts.codeInline
        let background = InlineCodeBackground(
            color: theme.colors.codeBackground,
            ascent: font.ascender,
            descent: abs(font.descender)
        )
        let result = NSMutableAttributedString()
        result.append(spacer(background: background, font: font))
        result.append(NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: theme.colors.code,
            .inlineCodeBackground: background,
        ]))
        result.append(spacer(background: background, font: font))
        return result
    }

    /// A blank attachment as wide as the inset. It copies as nothing, so the
    /// copied text is the code alone.
    private static func spacer(background: InlineCodeBackground, font: UIFont) -> NSAttributedString {
        let attachment = TextLabel.Attachment.hold(attrString: NSAttributedString())
        attachment.size = CGSize(width: horizontalInset, height: 0)
        return attachment.attributedString(attributes: [
            .font: font,
            .inlineCodeBackground: background,
        ])
    }
}

/// The pill behind one inline code span. Spans that look the same compare
/// equal, so a rebuilt document compares equal to the one it replaces.
final class InlineCodeBackground: NSObject {
    let color: UIColor
    let ascent: CGFloat
    let descent: CGFloat

    init(color: UIColor, ascent: CGFloat, descent: CGFloat) {
        self.color = color
        self.ascent = ascent
        self.descent = descent
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? InlineCodeBackground else { return false }
        return color.isEqual(other.color) && ascent == other.ascent && descent == other.descent
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(color)
        hasher.combine(ascent)
        hasher.combine(descent)
        return hasher.finalize()
    }
}

/// A text label that draws inline code on its pill.
///
/// It draws through an ``InlineCodeLineRenderer``, which `MarkdownTextView`
/// also gives any label it is handed without a renderer of its own, so a
/// subclass is free to return a layout of its own from `makeTextLayout(_:)`.
open class MarkdownTextLabelView: TextLabelView {
    override public init(frame: CGRect) {
        super.init(frame: frame)
        lineRenderer = InlineCodeLineRenderer()
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Draws each inline code span on its pill, behind the line's glyphs.
///
/// The pill has to be drawn before the line's text: drawn afterwards it
/// either covers the glyphs or, composited beneath them, stacks up again on
/// every partial redraw. As a renderer it is drawn by any layout a label
/// builds, an animatable label's included, and an animator that draws a
/// line through `LTXAnimatedLine.draw(in:)` fades the pill with the text.
///
/// Give each label its own instance: it keeps what it measured for the
/// layout it last drew.
open class InlineCodeLineRenderer: TextLabel.LineRenderer {
    /// The layout the state below belongs to. Weak, because the layout holds
    /// this renderer.
    private weak var measuredLayout: TextLabel.Layout?
    private var hasInlineCode = false

    /// The pills of each line drawn so far, kept with the line they were
    /// measured on. A resize redraws every line, and finding the spans means
    /// walking each run's attributes; a new layout makes new lines, so a
    /// stored line that is not the one being drawn is measured again.
    private var pillCache: [Int: (line: CTLine, pills: [Pill])] = [:]

    /// One span's pill on a line, relative to the line's baseline origin.
    private struct Pill {
        let background: InlineCodeBackground
        let minX: CGFloat
        let maxX: CGFloat
    }

    /// Fills the pill behind every inline code span on `line`, relative to
    /// the context's text position.
    ///
    /// - Important: Performance-sensitive: runs for every visible line on
    ///   every display pass. A document without inline code returns after
    ///   one comparison.
    override open func drawBackground(of line: CTLine, at index: Int, in context: CGContext, layout: TextLabel.Layout) {
        if measuredLayout !== layout {
            measure(layout)
        }
        guard hasInlineCode else { return }
        let pills: [Pill]
        if let cached = pillCache[index], cached.line === line {
            pills = cached.pills
        } else {
            pills = Self.pills(of: line)
            pillCache[index] = (line, pills)
        }
        guard !pills.isEmpty else { return }

        // CoreText space: the text position is the line's baseline origin.
        let origin = context.textPosition
        context.saveGState()
        defer { context.restoreGState() }
        for pill in pills {
            let background = pill.background
            let rect = CGRect(
                x: origin.x + pill.minX,
                y: origin.y - background.descent - InlineCode.verticalInset,
                width: pill.maxX - pill.minX,
                height: background.ascent + background.descent + InlineCode.verticalInset * 2
            )
            let radius = min(InlineCode.cornerRadius, rect.height / 2, rect.width / 2)
            context.setFillColor(background.color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        }
        context.textPosition = origin
    }

    /// Starts over for a layout this renderer has not drawn: whether it holds
    /// any inline code, and no pills yet.
    private func measure(_ layout: TextLabel.Layout) {
        measuredLayout = layout
        pillCache.removeAll(keepingCapacity: true)
        let string = layout.attributedString
        var found = false
        string.enumerateAttribute(
            .inlineCodeBackground,
            in: NSRange(location: 0, length: string.length)
        ) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        hasInlineCode = found
    }

    private static let backgroundKey = NSAttributedString.Key.inlineCodeBackground.rawValue as CFString
    private static let attachmentKey = NSAttributedString.Key.litextAttachment.rawValue as CFString

    /// One attribute of a run, read without bridging the run's whole
    /// attribute dictionary, which a resize would do for every run it draws.
    private static func runValue(_ attributes: CFDictionary, _ key: CFString) -> AnyObject? {
        guard let value = CFDictionaryGetValue(attributes, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
    }

    /// One pill per code span on `line`, spanning its text and the spacers
    /// beside it. A spacer the line break left on a line by itself gets
    /// none, and a side the span wraps on, with its spacer on another line,
    /// reaches `wrappedEndInset` past the text instead.
    private static func pills(of line: CTLine) -> [Pill] {
        struct Span {
            let background: InlineCodeBackground
            var minX: CGFloat
            var maxX: CGFloat
            /// String ranges of the code text and of the spacers on this line.
            var code: NSRange?
            var spacers: [NSRange] = []
        }
        var spans: [Span] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run)
            guard let background = runValue(attributes, backgroundKey) as? InlineCodeBackground,
                  let (start, end) = InlineCode.horizontalExtent(of: run)
            else { continue }
            let cfRange = CTRunGetStringRange(run)
            let range = NSRange(location: cfRange.location, length: cfRange.length)
            let index = spans.firstIndex { $0.background === background } ?? {
                spans.append(Span(background: background, minX: start, maxX: end))
                return spans.count - 1
            }()
            spans[index].minX = min(spans[index].minX, start)
            spans[index].maxX = max(spans[index].maxX, end)
            if runValue(attributes, attachmentKey) == nil {
                spans[index].code = spans[index].code.map { NSUnionRange($0, range) } ?? range
            } else {
                spans[index].spacers.append(range)
            }
        }
        return spans.compactMap { span in
            guard let code = span.code, span.minX < span.maxX else { return nil }
            let hasLeadingSpacer = span.spacers.contains { $0.location < code.location }
            let hasTrailingSpacer = span.spacers.contains { $0.location >= NSMaxRange(code) }
            return Pill(
                background: span.background,
                minX: span.minX - (hasLeadingSpacer ? 0 : InlineCode.wrappedEndInset),
                maxX: span.maxX + (hasTrailingSpacer ? 0 : InlineCode.wrappedEndInset)
            )
        }
    }
}

/// The layout ``MarkdownTextLabelView`` used to return, which draws the
/// pills itself.
@available(*, deprecated, message: "Set an InlineCodeLineRenderer as the label's lineRenderer instead; it works with any layout.")
open class MarkdownTextLayout: TextLabel.Layout {
    private let pills = InlineCodeLineRenderer()

    override open func draw(line: CTLine, at index: Int, in context: CGContext) {
        drawInlineCodeBackgrounds(of: line, at: index, in: context)
        super.draw(line: line, at: index, in: context)
    }

    /// Fills the pill behind every inline code span on `line`, unless the
    /// label's renderer draws them already.
    open func drawInlineCodeBackgrounds(of line: CTLine, at index: Int, in context: CGContext) {
        guard !(lineRenderer is InlineCodeLineRenderer) else { return }
        pills.drawBackground(of: line, at: index, in: context, layout: self)
    }
}
