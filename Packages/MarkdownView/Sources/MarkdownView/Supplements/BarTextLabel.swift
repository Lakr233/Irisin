//
//  BarTextLabel.swift
//  MarkdownView
//

import CoreText
import Foundation
import Litext
import UIKit

/// One line of plain text in a bar, drawn by the text engine with
/// interaction off: cheaper than a platform label, and it takes no touch,
/// click or selection from the bar's buttons.
///
/// The text engine wraps rather than truncates, so a line wider than the
/// label is cut here, at the tail, with an ellipsis.
class BarTextLabel: TextLabelView {
    var text: String = "" {
        didSet {
            guard oldValue != text else { return }
            textDidChange()
        }
    }

    var font: UIFont = .systemFont(ofSize: UIFont.systemFontSize) {
        didSet {
            guard oldValue != font else { return }
            textDidChange()
        }
    }

    var textColor: UIColor = BarTextLabel.defaultTextColor {
        didSet {
            guard oldValue != textColor else { return }
            textDidChange()
        }
    }

    static var defaultTextColor: UIColor {
        .label
    }

    /// The width the text was last cut to fit.
    private var fittedWidth: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isSelectable = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// One line of the font: its ascent, descent and leading.
    var lineHeight: CGFloat {
        ceil(font.ascender + abs(font.descender) + font.leading)
    }

    /// The width of the whole text, measured once per change: the bar
    /// lays out on every pass while a window resizes.
    private var textWidth: CGFloat?

    /// The whole text on one line, however wide.
    override var intrinsicContentSize: CGSize {
        let width = textWidth ?? ceil(width(of: text))
        textWidth = width
        return CGSize(width: width, height: lineHeight)
    }

    override func layoutSubviews() {
        fitTextIfNeeded()
        super.layoutSubviews()
    }

    private func textDidChange() {
        fittedWidth = -1
        textWidth = nil
        invalidateIntrinsicContentSize()
        fitTextIfNeeded()
    }

    private func fitTextIfNeeded() {
        let width = bounds.width
        guard width != fittedWidth else { return }
        fittedWidth = width
        let fitted = NSAttributedString(string: Self.truncated(text, toFit: width, measure: self.width(of:)), attributes: attributes)
        guard !attributedText.isEqual(to: fitted) else { return }
        attributedText = fitted
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: textColor]
    }

    private func width(of string: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// `text` whole when it fits `width`, otherwise the longest start of it
    /// that fits with an ellipsis after it. A label not yet given a width
    /// shows the whole text.
    static func truncated(_ text: String, toFit width: CGFloat, measure: (String) -> CGFloat) -> String {
        guard width > 0, measure(text) > width else { return text }
        let characters = Array(text)
        var low = 0
        var high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(String(characters[..<middle]) + "…") <= width {
                low = middle
            } else {
                high = middle - 1
            }
        }
        let head = String(characters[..<low]).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? "…" : head + "…"
    }
}
