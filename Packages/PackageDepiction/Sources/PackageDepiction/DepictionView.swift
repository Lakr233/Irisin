//
//  DepictionView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SafariServices
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
///
/// `view(dictionary:…)` finds a class by the json's `class` string through
/// the Objective-C runtime, and a json can name this one. The runtime name
/// is pinned to the mangled spelling of the name the type had, so
/// `PackageDepiction.DepictionBaseView` still finds it.
@objc(_TtC16PackageDepiction17DepictionBaseView)
public class DepictionView: UIView {
    let parentViewController: UIViewController?
    let isActionable: Bool
    public var isHighlighted: Bool = false

    public class func view(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor?,
        isActionable: Bool
    ) -> DepictionView? {
        let className = (dictionary["class"] as? String) ?? ""

        var tintColor: UIColor = tintColor ?? .systemOrange
        if let tintColorStr = dictionary["tintColor"] as? String {
            tintColor = UIColor(css: tintColorStr) ?? .systemOrange
        }

        let view = viewClass(of: dictionary)?.init(
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

    /// The view this build has for the json's `class`, nil when it has
    /// none: what `view(dictionary:…)` builds, and what a tab built later
    /// is checked against.
    static func viewClass(of dictionary: [String: Any]) -> DepictionView.Type? {
        let className = (dictionary["class"] as? String) ?? ""
        return Bundle.main.classNamed("PackageDepiction.\(className)") as? DepictionView.Type
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

    /// Where a button, a table row or a link in the prose goes when tapped.
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
