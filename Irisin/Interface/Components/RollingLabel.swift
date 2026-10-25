//
//  RollingLabel.swift
//  Irisin
//
//  Created by Lakr Aream on 2026/10/25.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import LitextAnimation
import Then
import UIKit

/// One line of text that rolls from one value to the next: the glyphs the
/// two share slide into place, new ones spring in and old ones roll away,
/// the other way for a number that went down (Litext's numeric
/// transition). Litext draws from the top, so the line sits in the middle
/// of whatever height the view is given, as a `UILabel`'s does.
///
/// The text is drawn for the eye alone: every row that shows one carries
/// its value for VoiceOver itself.
final class RollingLabel: UIView {
    /// Where the line sits, following the layout direction.
    enum Alignment {
        case leading
        case center
        case trailing
    }

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            apply(animated: !disablesAnimations)
            invalidateIntrinsicContentSize()
        }
    }

    // A row may set these on every refresh of its value: only a change
    // restyles, since restyling ends the transition in flight.
    var font: UIFont = .body {
        didSet { if font != oldValue { restyle() } }
    }

    var textColor: UIColor = .label {
        didSet { if textColor != oldValue { restyle() } }
    }

    var textAlignment: Alignment = .leading {
        didSet { if textAlignment != oldValue { restyle() } }
    }

    /// Shows each change of the text at once while set.
    var disablesAnimations = false

    /// The layout direction the alignment was resolved for: a label is
    /// styled before it joins a window, whose direction it then follows.
    private var resolvedRightToLeft = false

    private let label = LTXAnimatableLabel().then {
        $0.animator = LTXNumericTransitionAnimator()
        $0.animationPolicy = LTXNumericTransitionAnimator.policy
        $0.isUserInteractionEnabled = false
        // arriving and departing glyphs travel past the line
        $0.clipsToBounds = false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        accessibilityElementsHidden = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: CGSize {
        label.intrinsicContentSize
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        label.sizeThatFits(size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if textAlignment != .center, isRightToLeft != resolvedRightToLeft {
            apply(animated: false)
        }
        let height = label.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
    }

    /// A new look for the same text is never a transition.
    private func restyle() {
        apply(animated: false)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func apply(animated: Bool) {
        let paragraph = NSMutableParagraphStyle()
        let rightToLeft = isRightToLeft
        resolvedRightToLeft = rightToLeft
        paragraph.alignment = switch textAlignment {
        case .leading: rightToLeft ? .right : .left
        case .center: .center
        case .trailing: rightToLeft ? .left : .right
        }
        label.setAttributedText(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]), animated: animated)
        setNeedsLayout()
    }

    private var isRightToLeft: Bool {
        effectiveUserInterfaceLayoutDirection == .rightToLeft
    }
}
