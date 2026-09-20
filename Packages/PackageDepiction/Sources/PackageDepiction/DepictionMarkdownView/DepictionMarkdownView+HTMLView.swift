//
//  DepictionMarkdownView+HTMLView.swift
//  JsonDepiction
//

import UIKit

extension DepictionMarkdownView {
    /// The html a depiction sends as `useRawFormat` markdown (Chariz writes its
    /// whole page this way), read by Foundation's html importer and set again in
    /// the depiction's own type: body size throughout, weight and slant kept,
    /// the label colour, the tint on links. No web view.
    final class HTMLView: UITextView, UITextViewDelegate {
        var linkHandler: ((String) -> Void)?

        init?(html: String, tintColor: UIColor) {
            guard let text = Self.styled(html: html) else { return nil }
            super.init(frame: .zero, textContainer: nil)
            attributedText = text
            isEditable = false
            isScrollEnabled = false
            backgroundColor = .clear
            textContainerInset = .zero
            textContainer.lineFragmentPadding = 0
            linkTextAttributes = [.foregroundColor: tintColor]
            delegate = self
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func textView(
            _: UITextView,
            shouldInteractWith url: URL,
            in _: NSRange,
            interaction _: UITextItemInteraction
        ) -> Bool {
            linkHandler?(url.absoluteString)
            return false
        }

        /// The importer's output with its fonts, sizes and colours replaced by
        /// the depiction's; paragraph styles (lists, spacing, alignment) stay.
        /// Nil for html that sets no text at all.
        static func styled(html: String) -> NSAttributedString? {
            guard let data = html.data(using: .utf8),
                  let text = try? NSMutableAttributedString(
                      data: data,
                      options: [
                          .documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue,
                      ],
                      documentAttributes: nil
                  )
            else { return nil }

            let string = text.string as NSString
            let lastGlyph = string.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
            guard lastGlyph.location != NSNotFound else { return nil }
            let end = NSMaxRange(lastGlyph)
            text.deleteCharacters(in: NSRange(location: end, length: string.length - end))

            let whole = NSRange(location: 0, length: text.length)
            text.enumerateAttribute(.font, in: whole) { value, range, _ in
                let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
                let font = UIFont.depictionBody(traits: traits.intersection([.traitBold, .traitItalic]))
                text.addAttribute(.font, value: font, range: range)
            }
            text.addAttribute(.foregroundColor, value: UIColor.label, range: whole)
            return text
        }
    }
}
