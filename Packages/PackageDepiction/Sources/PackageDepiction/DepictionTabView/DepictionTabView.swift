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

    /// Each tab's json, in the strip's order.
    private var tabs: [[String: Any]]

    /// The tabs built so far. The first is built with the view; another
    /// only when it is first chosen, since a long changelog nobody opens
    /// costs the page's first frame as much as the prose everybody reads.
    private var tabContentViews: [Int: DepictionView] = [:]

    /// The tint the depiction handed down, kept for a tab built later:
    /// the view's own `tintColor` is dimmed while a sheet is up.
    private let tabTint: UIColor

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

        // The first tab that builds is the one on show. A tab after it is
        // kept when this build knows its class, and built when chosen; one
        // it does not know is left out and reported now, as building it
        // would have.
        var first: DepictionView?
        var shown: [[String: Any]] = []
        for tab in tabs {
            if first == nil {
                first = DepictionView.view(
                    dictionary: tab,
                    viewController: viewController,
                    tintColor: tintColor,
                    isActionable: isActionable
                )
                if first != nil {
                    shown.append(tab)
                }
            } else if DepictionView.viewClass(of: tab) != nil {
                shown.append(tab)
            } else {
                (viewController as? DepictionRenderObserver)?
                    .depictionCouldNotRender(className: (tab["class"] as? String) ?? "")
            }
        }
        guard let first else {
            return nil
        }
        self.tabs = shown
        tabContentViews[0] = first
        tabTint = tintColor

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        // The strip stays even for a single tab: it names the section.
        for tab in shown {
            segments.insertSegment(
                withTitle: tab["tabname"] as? String,
                at: segments.numberOfSegments,
                animated: false
            )
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

    /// The tab at `index`, built the first time it is asked for. The page
    /// hears of one whose fields turn out to be missing as it would have
    /// while loading.
    private func content(of index: Int) -> DepictionView? {
        if let view = tabContentViews[index] {
            return view
        }
        guard let parentViewController,
              let view = DepictionView.view(
                  dictionary: tabs[index],
                  viewController: parentViewController,
                  tintColor: tabTint,
                  isActionable: isActionable
              )
        else {
            return nil
        }
        view.isHighlighted = isHighlighted
        tabContentViews[index] = view
        return view
    }

    /// A tab that cannot be built leaves the strip, and the one before it
    /// is shown in its place: the first always built.
    private func show(tab index: Int) {
        contentArea.subviews.forEach { $0.removeFromSuperview() }
        guard let view = content(of: index) else {
            tabs.remove(at: index)
            tabContentViews = Dictionary(uniqueKeysWithValues: tabContentViews.map { key, view in
                (key > index ? key - 1 : key, view)
            })
            segments.removeSegment(at: index, animated: false)
            let previous = max(index - 1, 0)
            segments.selectedSegmentIndex = previous
            return show(tab: previous)
        }
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
            for view in tabContentViews.values {
                view.isHighlighted = isHighlighted
            }
        }
    }
}
