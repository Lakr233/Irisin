//
//  DepictionHeaderView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

/// A section title. `DepictionSubheaderView` is the same view with a
/// quieter default weight and more room around it.
class DepictionHeaderView: DepictionView {
    class var boldByDefault: Bool {
        true
    }

    class var verticalInset: CGFloat {
        8
    }

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let title = dictionary["title"] as? String else {
            return nil
        }
        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        let bold = (dictionary["useBoldText"] as? Bool) ?? Self.boldByDefault
        let useMargins = (dictionary["useMargins"] as? Bool) ?? true
        let useBottomMargin = (dictionary["useBottomMargin"] as? Bool) ?? true

        let label = UILabel().then {
            $0.text = title
            $0.numberOfLines = 0
            $0.font = bold ? .depictionBodyEmphasized : .depictionBody
            $0.textColor = bold ? .label : .depictionSecondaryLabel
            $0.textAlignment = .depiction(dictionary["alignment"] as? Int)
        }
        addSubview(label)
        label.snp.makeConstraints { x in
            x.left.right.equalToSuperview().inset(useMargins ? 16 : 0)
            x.top.equalToSuperview().inset(useMargins ? Self.verticalInset : 0)
            x.bottom.equalToSuperview().inset(useMargins && useBottomMargin ? Self.verticalInset : 0)
        }
    }
}
