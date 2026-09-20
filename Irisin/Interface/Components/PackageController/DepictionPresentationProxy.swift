//
//  DepictionPresentationProxy.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/19.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import PackageDepiction
import SafariServices
import UIKit

class DepictionPresentationProxy: UIViewController, DepictionRenderObserver {
    weak var parentController: UIViewController?

    /// The classes the depiction named that this build could not build.
    private(set) var unrenderedClasses: [String] = []

    func depictionCouldNotRender(className: String) {
        unrenderedClasses.append(className)
    }

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        if let navigator = parentController?.navigationController,
           !(viewControllerToPresent is SFSafariViewController)
        {
            if viewControllerToPresent.title?.count ?? 0 < 1 {
                viewControllerToPresent.title = String(localized: "Details")
            }
            navigator.pushViewController(viewControllerToPresent, animated: true)
        } else {
            if UIDevice.current.userInterfaceIdiom == .pad {
                viewControllerToPresent.modalTransitionStyle = .coverVertical
                viewControllerToPresent.modalPresentationStyle = .formSheet
                viewControllerToPresent.preferredContentSize = preferredPopOverSize
            }
            parentController?.present(
                viewControllerToPresent,
                animated: flag,
                completion: completion
            )
        }
    }
}
