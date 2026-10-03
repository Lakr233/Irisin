//
//  MarkdownTextView+ContextViewSelection.swift
//  MarkdownView
//

import Foundation
import Litext
import UIKit

extension MarkdownTextView {
    /// Tints each code and table view the document's selection runs across.
    ///
    /// Those views sit over the text as siblings of the label, each standing in
    /// for one attachment character, so the label's own selection is drawn
    /// beneath them, and only as wide as that character. A view whose character
    /// is selected is covered in the selection colour instead.
    func syncContextViewSelection() {
        let selection = textLabelView.selectionRange.flatMap { $0.length > 0 ? $0 : nil }
        let color = theme.colors.selectionBackground ?? Self.fallbackSelectionTint
        for view in contextViews {
            let isSelected = selection.map { selection in
                guard !view.isHidden,
                      let location = contextViewLocations[ObjectIdentifier(view)]
                else { return false }
                return NSLocationInRange(location, selection)
            } ?? false
            view.setSelectionTint(isSelected ? color : nil)
        }
    }

    private static let fallbackSelectionTint = UIColor.systemBlue.withAlphaComponent(0.1)
}

private let selectionTintLayerName = "MarkdownView.selectionTint"

extension UIView {
    /// Lays `color` over the whole view, above its subviews, or removes it for nil.
    func setSelectionTint(_ color: UIColor?) {
        let host = layer
        let existing = host.sublayers?.first { $0.name == selectionTintLayerName }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let color else {
            existing?.removeFromSuperlayer()
            return
        }
        let tint = existing ?? {
            let tint = CALayer()
            tint.name = selectionTintLayerName
            // Above the layers of subviews added after it.
            tint.zPosition = 1000
            tint.cornerRadius = 8
            tint.cornerCurve = .continuous
            host.addSublayer(tint)
            return tint
        }()
        tint.frame = bounds
        tint.backgroundColor = color.cgColor
    }
}
