//
//  DepictionStackView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionStackView: DepictionView {
    private let stack: UIStackView

    private var views: [DepictionView] {
        stack.arrangedSubviews.compactMap { $0 as? DepictionView }
    }

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let views = dictionary["views"] as? [[String: Any]] else {
            return nil
        }
        var isLandscape = false
        if let orientation = dictionary["orientation"] as? String {
            guard orientation == "landscape" || orientation == "portrait" else {
                return nil
            }
            isLandscape = orientation == "landscape"
        }
        for viewDict in views {
            guard (viewDict["class"] as? String) != nil else {
                return nil
            }
        }

        let built = views.compactMap { viewDict in
            DepictionView.view(
                dictionary: viewDict,
                viewController: viewController,
                tintColor: tintColor,
                isActionable: isActionable
            )
        }
        stack = UIStackView(arrangedSubviews: isLandscape ? built : Self.dropEmptySections(built)).then {
            $0.axis = isLandscape ? .horizontal : .vertical
            $0.distribution = isLandscape ? .fillEqually : .fill
            $0.alignment = .fill
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.top.bottom.equalToSuperview()
            x.left.right.equalToSuperview().inset((dictionary["xPadding"] as? CGFloat) ?? 0)
        }
        if let backgroundColor = dictionary["backgroundColor"] as? String {
            self.backgroundColor = UIColor(css: backgroundColor)
        }
    }

    /// A child this build cannot render is dropped, and the views around
    /// it then say nothing: a header over an empty section, two separators
    /// in a row, a separator at an edge. A section is the run between two
    /// separators; one holding only headers and spacers goes, separator
    /// included, and so does a separator left at either end.
    static func dropEmptySections(_ views: [DepictionView]) -> [DepictionView] {
        var kept: [DepictionView] = []
        var sectionStart = 0
        var sectionHasContent = false
        for view in views {
            guard view is DepictionSeparatorView else {
                kept.append(view)
                sectionHasContent = sectionHasContent
                    || !(view is DepictionHeaderView || view is DepictionSpacerView)
                continue
            }
            if sectionHasContent {
                kept.append(view)
            } else {
                kept.removeSubrange(sectionStart...)
            }
            sectionStart = kept.count
            sectionHasContent = false
        }
        if !sectionHasContent {
            kept.removeSubrange(sectionStart...)
            if kept.last is DepictionSeparatorView {
                kept.removeLast()
            }
        }
        return kept
    }

    override var isHighlighted: Bool {
        didSet {
            for view in views {
                view.isHighlighted = isHighlighted
            }
        }
    }
}
