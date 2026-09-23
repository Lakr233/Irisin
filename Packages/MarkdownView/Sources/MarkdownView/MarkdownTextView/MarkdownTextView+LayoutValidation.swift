//
//  MarkdownTextView+LayoutValidation.swift
//  MarkdownView
//
//  Created by Claude on 8/8/26.
//

import Foundation
import Litext

extension MarkdownTextView {
    /// One laid-out element of the document, in ``MarkdownTextView`` coordinates.
    ///
    /// Text lines contribute their line rect; a line that hosts a context view
    /// contributes the view's frame instead, since the view is what the reader sees.
    struct VerticalLayoutBox {
        let label: String
        let frame: CGRect
    }

    /// Every laid-out element ordered top to bottom.
    ///
    /// Read by the tests that prove no block is drawn on top of another one.
    func verticalLayoutBoxes() -> [VerticalLayoutBox] {
        var boxesByLine: [Int: VerticalLayoutBox] = [:]

        for run in textLabelView.layoutRuns(matching: .font) {
            guard boxesByLine[run.lineIndex] == nil else { continue }
            boxesByLine[run.lineIndex] = .init(
                label: "line \(run.lineIndex)",
                frame: convertFromTextLayout(run.lineRect)
            )
        }

        // Context views are compared by their own frames rather than by the line
        // that reserved them: a view whose line was never laid out still covers
        // the text it is drawn over.
        let contextLines = Set(textLabelView.layoutRuns(matching: .contextView).map(\.lineIndex))
        var boxes = boxesByLine
            .filter { lineIndex, _ in !contextLines.contains(lineIndex) }
            .map(\.value)
        let visibleContextViews = contextViews.lazy.filter {
            $0.superview === self && !$0.isHidden
        }
        boxes.append(contentsOf: visibleContextViews.map {
            .init(label: "\(type(of: $0))", frame: $0.frame)
        })

        return boxes.sorted {
            $0.frame.minY == $1.frame.minY
                ? $0.frame.maxY < $1.frame.maxY
                : $0.frame.minY < $1.frame.minY
        }
    }
}
