//
//  Created by Lakr233 on 2025/1/22.
//  Copyright (c) 2025 MarkdownView. All rights reserved.
//

import Litext
import UIKit

final class LineNumberView: UIView {
    var lineCount: Int = 1 {
        didSet {
            guard oldValue != lineCount else { return }
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }

    var font: UIFont = .monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet {
            guard oldValue != font else { return }
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }

    var textColor: UIColor = .secondaryLabel {
        didSet {
            guard oldValue != textColor else { return }
            setNeedsDisplay()
        }
    }

    var padding: UIEdgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8) {
        didSet {
            guard oldValue != padding else { return }
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
        }
    }

    var contentHeight: CGFloat = 0 {
        didSet {
            guard oldValue != contentHeight else { return }
            setNeedsDisplay()
            invalidateIntrinsicContentSize()
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

    override var intrinsicContentSize: CGSize {
        let maxLineNumber = max(lineCount, 1)
        let numberString = "\(maxLineNumber)"
        let textSize = numberString.size(withAttributes: [.font: font])

        return CGSize(
            width: textSize.width + padding.left + padding.right,
            height: max(contentHeight + padding.top + padding.bottom, textSize.height + padding.top + padding.bottom)
        )
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(rect)

        guard lineCount > 0, contentHeight > 0 else { return }

        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]

        let availableHeight = contentHeight
        let lineSpacing = availableHeight / CGFloat(lineCount)
        let startY = padding.top

        guard lineSpacing > 0 else { return }

        let firstLine = max(1, Int(floor((rect.minY - padding.top) / lineSpacing)))
        let lastLine = min(lineCount, Int(ceil((rect.maxY - padding.top) / lineSpacing)) + 1)
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
            let y = startY + CGFloat(lineNumber - 1) * lineSpacing + (lineSpacing - textHeight) / 2

            let textRect = CGRect(
                x: x,
                y: y,
                width: textWidth,
                height: textHeight
            )

            numberString.draw(in: textRect, withAttributes: textAttributes)
        }
    }

    func configure(lineCount: Int, contentHeight: CGFloat, font: UIFont, textColor: UIColor) {
        self.lineCount = lineCount
        self.contentHeight = contentHeight
        self.font = font
        self.textColor = textColor
    }

    func updateForContent(_ content: String) {
        let lines = content.components(separatedBy: .newlines)
        lineCount = max(lines.count, 1)
    }
}

