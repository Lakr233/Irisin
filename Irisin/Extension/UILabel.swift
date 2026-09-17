//
//  UILabel.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/14.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

extension UILabel {
    func highlight(text: String?, font: UIFont? = nil, color: UIColor? = nil) {
        guard let fullText = self.text, let target = text else {
            return
        }

        let attribText = NSMutableAttributedString(string: fullText)
        let range: NSRange = attribText.mutableString.range(of: target, options: .caseInsensitive)

        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font {
            attributes[.font] = font
        }
        if let color {
            attributes[.foregroundColor] = color
        }
        attribText.addAttributes(attributes, range: range)
        attributedText = attribText
    }

    func limitedLeadingHighlight(text: String?, color: UIColor? = nil) {
        guard var fullText = self.text, let target = text else {
            return
        }
        guard let range = fullText.range(of: target) else { return }
        let index = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
        let leading = 15
        if index > leading {
            fullText.removeFirst(index - leading)
            fullText = "... " + fullText
        }

        self.text = fullText
        highlight(text: target, color: color)
    }
}
