//
//  DepictionButton.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SafariServices
import UIKit

class DepictionButton: UIButton {
    var isLink: Bool = false
    var depictionView: DepictionBaseView?

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

    static func processAction(_ action: String, parentViewController: UIViewController?, openExternal: Bool) {
        guard let url = URL(string: action) else { return }
        if action.hasPrefix("http"), !openExternal {
            let safariViewController = SFSafariViewController(url: url)
            parentViewController?.present(safariViewController, animated: true, completion: nil)
        } else if action.hasPrefix("http") || action.hasPrefix("mailto") {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        } else {
            debugPrint(url)
        }
    }
}
