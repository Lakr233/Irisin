//
//  TextLabel.Attachment+Extension.swift
//  MarkdownView
//
//  Created by 秋星桥 on 3/27/25.
//

import Foundation
import Litext

private class HolderAttachment: TextLabel.Attachment {
    let attrString: NSAttributedString
    init(attrString: NSAttributedString) {
        self.attrString = attrString
        super.init()
    }

    override func attributedStringRepresentation() -> NSAttributedString {
        attrString
    }
}

extension TextLabel.Attachment {
    static func hold(attrString: NSAttributedString) -> TextLabel.Attachment {
        HolderAttachment(attrString: attrString)
    }
}
