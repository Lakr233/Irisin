//
//  DepictionLabelView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionLabelView: DepictionView {
    private let label = UILabel().then {
        $0.numberOfLines = 0
    }

    /// A label that named no colour of its own follows the tint while it is
    /// tappable, and the label colour otherwise.
    private let usesDefaultColor: Bool

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let text = dictionary["text"] as? String else {
            return nil
        }

        var margins = (dictionary["margins"] as? String).map(NSCoder.uiEdgeInsets(for:))
            ?? UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        if margins.left == 0 {
            margins.left = 16
        }
        if margins.right == 0 {
            margins.right = 16
        }
        if (dictionary["useMargins"] as? Bool) == false {
            margins = .zero
        } else if (dictionary["usePadding"] as? Bool) == false {
            margins.top = 0
            margins.bottom = 0
        }

        let color = (dictionary["textColor"] as? String).flatMap { UIColor(css: $0) }
        usesDefaultColor = color == nil

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        // The json's `fontSize` is ignored: every label is body-sized, and a
        // weight of medium or heavier is the one emphasis there is.
        let fontWeight = (dictionary["fontWeight"] as? String)?.lowercased() ?? "normal"
        let emphasized = ["medium", "semibold", "bold", "heavy", "black"].contains(fontWeight)

        label.text = text
        label.font = emphasized ? .depictionBodyEmphasized : .depictionBody
        label.textColor = color
        label.textAlignment = .depiction(dictionary["alignment"] as? Int)
        addSubview(label)
        label.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(margins)
        }
        recolor()
    }

    override var isHighlighted: Bool {
        didSet { recolor() }
    }

    private func recolor() {
        guard usesDefaultColor else { return }
        guard isActionable else {
            label.textColor = .label
            return
        }
        label.textColor = isHighlighted ? tintColor.pressed : tintColor
    }
}
