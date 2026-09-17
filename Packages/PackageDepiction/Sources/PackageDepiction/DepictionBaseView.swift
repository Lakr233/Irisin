//
//  DepictionBaseView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import UIKit

/// The view controller handed to a depiction may adopt this to hear about
/// every view in the json that could not be built: a class this build does
/// not know, or one whose required fields are missing.
public protocol DepictionRenderObserver: AnyObject {
    func depictionCouldNotRender(className: String)
}

/// One view of a depiction. Every subclass lays itself out with constraints
/// and so has a height of its own: the page that shows a depiction pins its
/// edges and measures nothing.
public class DepictionBaseView: UIView {
    let parentViewController: UIViewController?
    let isActionable: Bool
    public var isHighlighted: Bool = false

    public class func view(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor?,
        isActionable: Bool
    ) -> DepictionBaseView? {
        let className = (dictionary["class"] as? String) ?? ""

        var tintColor: UIColor = tintColor ?? .systemOrange
        if let tintColorStr = dictionary["tintColor"] as? String {
            tintColor = UIColor(css: tintColorStr) ?? .systemOrange
        }

        let rawclass = Bundle.main.classNamed("PackageDepiction.\(className)") as? DepictionBaseView.Type
        let view = rawclass?.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )
        if view == nil {
            (viewController as? DepictionRenderObserver)?.depictionCouldNotRender(className: className)
        }
        return view
    }

    public required init?(
        dictionary _: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        parentViewController = viewController
        self.isActionable = isActionable
        super.init(frame: .zero)
        self.tintColor = tintColor
        // A section never draws past its own height: a child that grows
        // wrong stays inside, instead of covering the sections below.
        clipsToBounds = true
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
