//
//  AttributeStringKey.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import CoreText
import Foundation

extension NSAttributedString.Key {
    static let contextView: NSAttributedString.Key = .init("contextView")
    static let blockquoteGroup: NSAttributedString.Key = .init("blockquoteGroup")
    static let coreTextLanguage: NSAttributedString.Key = .init(kCTLanguageAttributeName as String)
}
