//
//  DepictionSpacerView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import UIKit

final class DepictionSpacerView: DepictionView {
    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let spacing = dictionary["spacing"] as? CGFloat else {
            return nil
        }
        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )
        snp.makeConstraints { x in
            x.height.equalTo(spacing)
        }
    }
}
