//
//  UIColor.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import UIKit

extension UIColor {
    /// A dynamic color that follows the interface style. Either side may be
    /// dynamic itself (a system color that follows the level).
    convenience init(light: UIColor, dark: UIColor) {
        self.init { ($0.userInterfaceStyle == .dark ? dark : light).resolvedColor(with: $0) }
    }

    /// An opaque color from a `0xRRGGBB` value.
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
