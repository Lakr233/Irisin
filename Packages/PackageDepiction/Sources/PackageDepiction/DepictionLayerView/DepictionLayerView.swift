//
//  DepictionLayerView.swift
//  Sileo
//
//  Created by CoolStar on 8/29/20.
//  Copyright © 2020 CoolStar. All rights reserved.
//

import SnapKit
import UIKit

/// Its children stacked on top of one another, each at its own height; the
/// layer is as tall as the tallest.
final class DepictionLayerView: DepictionView {
    private var views: [DepictionView] = []

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let rawViews = dictionary["views"] as? [[String: Any]] else {
            return nil
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        for rawView in rawViews {
            guard let view = DepictionView.view(
                dictionary: rawView,
                viewController: viewController,
                tintColor: tintColor,
                isActionable: isActionable
            ) else {
                continue
            }
            views.append(view)
            addSubview(view)
            view.snp.makeConstraints { x in
                x.top.left.right.equalToSuperview()
                x.bottom.lessThanOrEqualToSuperview()
                // pulls the layer down to the tallest child without
                // stretching a shorter one (below content hugging)
                x.bottom.equalToSuperview().priority(100)
            }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            for view in views {
                view.isHighlighted = isHighlighted
            }
        }
    }
}
