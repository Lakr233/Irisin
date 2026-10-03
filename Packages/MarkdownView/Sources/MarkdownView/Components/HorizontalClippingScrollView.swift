//
//  HorizontalClippingScrollView.swift
//  MarkdownView
//

import UIKit

/// A horizontal scroller that clips scrolled content but not a selection's
/// handles.
///
/// A scroll view clips to its bounds, and the blocks scrolled here — a code
/// block, a table — are exactly as tall as their text, so the knobs of a
/// selection's handles, which reach past the first and last line and the
/// first character, were cut off. A mask in place of `clipsToBounds` leaves
/// room above and below for the handles and their shadow, and at a side
/// only while that side is scrolled to its blank padding: past it, the
/// overflow would show scrolled text over whatever sits beside the view.
final class HorizontalClippingScrollView: UIScrollView {
    /// How far content may draw past the bounds: a handle's knob reaches
    /// 13.5 pt past its line and casts an 8 pt shadow.
    static let overflow: CGFloat = 32

    /// How much of the content's start and end holds nothing, so the mask
    /// can open that side while it is in view.
    var blankLeadingWidth: CGFloat = 0
    var blankTrailingWidth: CGFloat = 0

    private let clipMask = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        clipMask.backgroundColor = UIColor.black.cgColor
        layer.mask = clipMask
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Called on every scroll, since scrolling moves `bounds.origin`; the mask
    /// is in the scrolled coordinate space and has to follow it.
    override func layoutSubviews() {
        super.layoutSubviews()
        var minX = bounds.minX
        if minX <= blankLeadingWidth {
            minX -= Self.overflow
        }
        var maxX = bounds.maxX
        if maxX >= contentSize.width - blankTrailingWidth {
            maxX += Self.overflow
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipMask.frame = CGRect(
            x: minX,
            y: bounds.minY - Self.overflow,
            width: maxX - minX,
            height: bounds.height + Self.overflow * 2
        )
        CATransaction.commit()
    }
}
