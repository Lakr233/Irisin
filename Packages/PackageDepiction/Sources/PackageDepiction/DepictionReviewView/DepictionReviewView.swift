//
//  DepictionReviewView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionReviewView: DepictionView {
    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let title = dictionary["title"] as? String,
              let author = dictionary["author"] as? String,
              let markdown = dictionary["markdown"] as? String
        else {
            return nil
        }
        let review = DepictionView.view(
            dictionary: [
                "class": "DepictionStackView",
                "views": [
                    ["class": "DepictionSubheaderView", "useMargins": false, "useBoldText": true, "title": title],
                    ["class": "DepictionSubheaderView", "useMargins": false, "useBoldText": false, "title": author],
                    ["class": "DepictionSpacerView", "spacing": 8],
                    ["class": "DepictionMarkdownView", "useSpacing": false, "useMargins": false, "markdown": markdown],
                ],
            ],
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )
        guard let review else {
            return nil
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        let background = UIView().then {
            $0.backgroundColor = .systemBackground
            $0.layer.cornerRadius = 10
        }
        addSubview(background)
        addSubview(review)
        background.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(8)
        }
        review.snp.makeConstraints { x in
            x.left.right.equalToSuperview().inset(20)
            x.top.bottom.equalToSuperview().inset(16)
        }
    }
}
