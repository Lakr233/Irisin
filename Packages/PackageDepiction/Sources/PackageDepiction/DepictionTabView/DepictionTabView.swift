//
//  DepictionTabView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import UIKit

final class DepictionTabView: DepictionView {
    private let segments = UISegmentedControl()
    private let tabContentViews: [DepictionView]

    /// Holds the one tab on show; the others are not in the hierarchy.
    private let contentArea = UIView()

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let tabs = dictionary["tabs"] as? [[String: Any]] else {
            return nil
        }
        for tab in tabs {
            guard (tab["tabname"] as? String) != nil, (tab["class"] as? String) != nil else {
                return nil
            }
        }

        var views: [DepictionView] = []
        var names: [String] = []
        for tab in tabs {
            guard let tabName = tab["tabname"] as? String,
                  let view = DepictionView.view(
                      dictionary: tab,
                      viewController: viewController,
                      tintColor: tintColor,
                      isActionable: isActionable
                  )
            else {
                continue
            }
            names.append(tabName)
            views.append(view)
        }
        guard !views.isEmpty else {
            return nil
        }
        tabContentViews = views

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        // The strip stays even for a single tab: it names the section.
        for name in names {
            segments.insertSegment(withTitle: name, at: segments.numberOfSegments, animated: false)
        }
        addSubview(segments)
        addSubview(contentArea)
        segments.snp.makeConstraints { x in
            x.top.equalToSuperview().offset(8)
            x.left.right.equalToSuperview().inset(16)
            x.height.equalTo(32)
        }
        contentArea.snp.makeConstraints { x in
            x.top.equalTo(segments.snp.bottom).offset(8)
            x.left.right.bottom.equalToSuperview()
        }

        segments.selectedSegmentIndex = 0
        segments.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        show(tab: 0)
    }

    private func show(tab index: Int) {
        contentArea.subviews.forEach { $0.removeFromSuperview() }
        let view = tabContentViews[index]
        contentArea.addSubview(view)
        view.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
    }

    @objc private func segmentChanged() {
        show(tab: segments.selectedSegmentIndex)
    }

    override var isHighlighted: Bool {
        didSet {
            for view in tabContentViews {
                view.isHighlighted = isHighlighted
            }
        }
    }
}
