//
//  Created by ktiays on 2025/1/20.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import CoreText
import Litext
import UIKit

// MARK: - TextBuilder Callback Types

extension TextBuilder {
    typealias DrawingCallback = (CGContext, CTLine, CGPoint) -> Void
    typealias BulletDrawingCallback = (CGContext, CTLine, CGPoint, Int) -> Void
    typealias CheckboxDrawingCallback = (CGContext, CTLine, CGPoint, Bool) -> Void
    typealias NumberedDrawingCallback = (CGContext, CTLine, CGPoint, Int) -> Void
    /// One run of rendered body text, as the view wants it shown —
    /// ``MarkdownTextView/decorate(inlineText:theme:)`` seen from the builder.
    /// The theme is not a parameter because a build has exactly one.
    typealias InlineTextDecoration = (NSAttributedString) -> NSAttributedString
}

// MARK: - RenderText

struct RenderText {
    let attributedString: NSAttributedString
    let fullWidthAttachments: [TextLabel.Attachment]
}

// MARK: - String Extension

extension String {
    func deletingSuffix(of characterSet: CharacterSet) -> String {
        var result = self
        while let lastChar = result.last, characterSet.contains(lastChar.unicodeScalars.first!) {
            result.removeLast()
        }
        return result
    }
}
