//
//  UIColor+Extension.swift
//  MarkdownView
//
//  Created by 秋星桥 on 2025/1/7.
//

import UIKit

extension UIColor {
    convenience init(light: UIColor, dark: UIColor) {
        self.init(dynamicProvider: { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

