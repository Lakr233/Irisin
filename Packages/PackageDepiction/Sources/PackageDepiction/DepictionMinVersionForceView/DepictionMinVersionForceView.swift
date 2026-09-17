//
//  DepictionMinVersionForceView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import UIKit

final class DepictionMinVersionForceView: DepictionBaseView {
    private var containedView: DepictionBaseView?

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let view = dictionary["view"] as? [String: Any] else {
            return nil
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        // A child that cannot be built is reported by `view`; this stays,
        // flat, so the stack around it keeps its shape.
        guard let containedView = DepictionBaseView.view(
            dictionary: view,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        ) else {
            return
        }
        self.containedView = containedView
        addSubview(containedView)
        containedView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    override var isHighlighted: Bool {
        didSet { containedView?.isHighlighted = isHighlighted }
    }
}
