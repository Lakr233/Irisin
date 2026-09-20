//
//  DepictionSeparatorView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionSeparatorView: DepictionView {
    private let line = UIView().then {
        $0.backgroundColor = .depictionSeparator
    }

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )
        addSubview(line)
        line.snp.makeConstraints { x in
            x.left.right.equalToSuperview().inset(16)
            x.top.bottom.equalToSuperview().inset(1)
            x.height.equalTo(1)
        }
    }
}
