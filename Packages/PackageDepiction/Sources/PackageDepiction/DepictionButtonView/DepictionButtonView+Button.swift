//
//  DepictionButtonView+Button.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import UIKit

extension DepictionButtonView {
    final class Button: UIButton {
        var isLink: Bool = false
        var depictionView: DepictionView?

        override var isHighlighted: Bool {
            didSet {
                if isLink {
                    backgroundColor = .clear
                    depictionView?.isHighlighted = isHighlighted
                    return
                }
                backgroundColor = isHighlighted ? tintColor.pressed : tintColor
            }
        }
    }
}
