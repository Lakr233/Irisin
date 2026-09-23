//
//  ListMarkerLayout.swift
//  MarkdownView
//
//  Created by 秋星桥 on 8/8/26.
//

import CoreText
import Foundation
import Litext

/// The column a list item's marker is drawn into.
///
/// Bullets, numbers and checkboxes are drawn rather than typeset, so CoreText
/// holds none of them on a common axis — every kind used to pick its own offsets
/// from the text, and a list mixing kinds came out ragged. They all go through
/// this column instead, so a bullet, a circled number and a checkbox at the same
/// depth share one center and leave the same gap before their text.
enum ListMarkerLayout {
    /// Head indent one level of nesting adds.
    ///
    /// The column and the gap after it fill exactly one level, so a marker never
    /// reaches into the text of the item that encloses it.
    static let indent: CGFloat = 24
    /// Side of the square a marker is drawn into.
    static let size: CGFloat = 16
    /// Gap between the column and the text it belongs to.
    static let spacing: CGFloat = 8

    /// The square a marker is drawn into for a line whose text starts at `lineOrigin`.
    ///
    /// The square is centered on the cap height of `font` rather than on the line's
    /// typographic bounds: those bounds grow with the tallest run on the line, so a
    /// first line carrying inline code, math or an image would drag its marker out of
    /// line with the items around it. A marker also never occupies the descent the
    /// bounds include, which is what made it sit low against CJK text.
    static func column(lineOrigin: CGPoint, font: UIFont) -> CGRect {
        let center = CGPoint(
            x: lineOrigin.x - spacing - size / 2,
            y: lineOrigin.y + font.capHeight / 2
        )
        return .init(
            x: center.x - size / 2,
            y: center.y - size / 2,
            width: size,
            height: size
        )
    }

    /// `imageSize` scaled to fill the column along its longer side, without distortion.
    ///
    /// A symbol image is never exactly square — its box carries the padding the symbol
    /// reserves around the glyph — so stretching it to the column's bounds leaves
    /// circles subtly oval and heavier on one axis than the bullets beside them. The
    /// scale also normalizes symbols across platforms, which hand back their own
    /// natural sizes for one and the same configuration.
    static func fittedSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .init(width: size, height: size)
        }
        let scale = min(size / imageSize.width, size / imageSize.height)
        return .init(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    /// `imageSize` fitted to the column and centered in it.
    static func fit(imageSize: CGSize, in column: CGRect) -> CGRect {
        let fitted = fittedSize(for: imageSize)
        return .init(
            x: column.midX - fitted.width / 2,
            y: column.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
