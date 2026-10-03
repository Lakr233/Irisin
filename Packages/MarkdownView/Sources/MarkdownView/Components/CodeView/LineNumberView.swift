//
//  Created by Lakr233 on 2025/1/22.
//  Copyright (c) 2025 MarkdownView. All rights reserved.
//

import Litext

final class LineNumberView: UIView {
    typealias EdgeInsets = UIEdgeInsets
    private static var defaultTextColor: UIColor {
        .secondaryLabel
    }

    var lineCount: Int = 1 {
        didSet {
            guard oldValue != lineCount else { return }
            markNeedsDisplay()
            invalidateSize()
        }
    }

    var font: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            guard oldValue != font else { return }
            markNeedsDisplay()
            invalidateSize()
        }
    }

    var textColor: UIColor = defaultTextColor {
        didSet {
            guard oldValue != textColor else { return }
            markNeedsDisplay()
        }
    }

    var padding: EdgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8) {
        didSet {
            guard oldValue != padding else { return }
            markNeedsDisplay()
            invalidateSize()
        }
    }

    /// The space between two lines of the code, which the text engine adds
    /// after every line but the last.
    var lineSpacing: CGFloat = 0 {
        didSet {
            guard oldValue != lineSpacing else { return }
            markNeedsDisplay()
        }
    }

    var contentHeight: CGFloat = 0 {
        didSet {
            guard oldValue != contentHeight else { return }
            markNeedsDisplay()
            invalidateSize()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        drawLineNumbers(in: rect)
    }

    /// Measured once per change: layout asks for it several times a pass,
    /// and every pass while a window resizes.
    private var cachedIntrinsicSize: CGSize?

    private func invalidateSize() {
        cachedIntrinsicSize = nil
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        if let cachedIntrinsicSize {
            return cachedIntrinsicSize
        }
        let maxLineNumber = max(lineCount, 1)
        let numberString = "\(maxLineNumber)"
        let textSize = numberString.size(withAttributes: [.font: font])

        let size = CGSize(
            width: textSize.width + padding.left + padding.right,
            height: max(contentHeight + padding.top + padding.bottom, textSize.height + padding.top + padding.bottom)
        )
        cachedIntrinsicSize = size
        return size
    }

    /// How far apart the code's lines sit. Every line but the last is
    /// followed by `lineSpacing`, so it is not the content height shared out
    /// evenly, which would spread the spacing over every line and let the
    /// numbers drift off their lines down the block.
    private var linePitch: CGFloat {
        guard lineCount > 0 else { return 0 }
        return (contentHeight + lineSpacing) / CGFloat(lineCount)
    }

    /// The vertical centre of the code line `lineNumber` (from 1), which its
    /// number is centred on.
    func lineMidY(_ lineNumber: Int) -> CGFloat {
        let pitch = linePitch
        return padding.top + CGFloat(lineNumber - 1) * pitch + (pitch - lineSpacing) / 2
    }

    /// Draws the numbers of the lines that cross `rect`, and nothing else.
    ///
    /// The view is transparent and the system clears its own backing before
    /// drawing, so it must not clear the context itself: drawn into a shared
    /// context, as a snapshot, PDF or print is, a clear punches through the
    /// code block's background and leaves the gutter black.
    private func drawLineNumbers(in rect: CGRect) {
        guard lineCount > 0, contentHeight > 0 else { return }

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        let pitch = linePitch
        guard pitch > 0 else { return }

        let firstLine = max(1, Int(floor((rect.minY - padding.top) / pitch)))
        let lastLine = min(lineCount, Int(ceil((rect.maxY - padding.top) / pitch)) + 1)
        guard firstLine <= lastLine else { return }

        let textHeight = "0".size(withAttributes: textAttributes).height
        var digitCount = 0
        var textWidth: CGFloat = 0

        for lineNumber in firstLine ... lastLine {
            let numberString = "\(lineNumber)"
            if numberString.count != digitCount {
                digitCount = numberString.count
                textWidth = numberString.size(withAttributes: textAttributes).width
            }

            let x = bounds.width - padding.right - textWidth
            let y = lineMidY(lineNumber) - textHeight / 2

            let textRect = CGRect(
                x: x,
                y: y,
                width: textWidth,
                height: textHeight
            )

            numberString.draw(in: textRect, withAttributes: textAttributes)
        }
    }

    func configure(
        lineCount: Int,
        contentHeight: CGFloat,
        lineSpacing: CGFloat,
        font: UIFont,
        textColor: UIColor
    ) {
        self.lineCount = lineCount
        self.lineSpacing = lineSpacing
        self.contentHeight = contentHeight
        self.font = font
        self.textColor = textColor
    }

    func updateForContent(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        lineCount = max(lines.count, 1)
    }
}
