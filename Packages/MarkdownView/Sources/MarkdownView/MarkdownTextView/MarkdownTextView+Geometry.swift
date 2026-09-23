//
//  MarkdownTextView+Geometry.swift
//  MarkdownView
//
//  Created by Claude on 8/8/26.
//

import Foundation
import Litext

extension MarkdownTextView {
    /// Converts a CoreText layout rect into ``MarkdownTextView`` coordinates.
    ///
    /// Text is anchored to the top of the layout container, so the flip runs
    /// against the height the lines were laid out against.
    func convertFromTextLayout(_ rect: CGRect) -> CGRect {
        CGRect(
            x: textLabelView.frame.minX + rect.minX,
            y: textLabelView.frame.minY + textLabelView.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// One bar frame per blockquote, spanning every line the quote occupies.
    ///
    /// Quotes are returned top to bottom so a bar keeps its quote across layout
    /// passes, and a quote whose lines all fall outside the layout contributes
    /// nothing rather than a bar of unknown position.
    func blockquoteLineSpans() -> [CGRect] {
        var spansByGroup: [BlockquoteGroup: CGRect] = [:]

        for run in textLabelView.layoutRuns(matching: .blockquoteGroup) {
            guard let group = run.attributes[.blockquoteGroup] as? BlockquoteGroup else { continue }
            let lineRect = convertFromTextLayout(run.lineRect)
            spansByGroup[group] = spansByGroup[group]?.union(lineRect) ?? lineRect
        }

        return spansByGroup.values
            .sorted { $0.minY < $1.minY }
            .map {
                CGRect(
                    x: textLabelView.frame.minX,
                    y: $0.minY,
                    width: BlockquoteBarView.width,
                    height: $0.height
                )
            }
    }
}
