//
//  MarkdownTextView+Update.swift
//  MarkdownView
//
//  Created by 秋星桥 on 7/9/25.
//

import CoreText
import Litext
import UIKit

extension MarkdownTextView {
    func updateTextExecute() {
        assert(Thread.isMainThread)

        var oldViews: Set<UIView> = .init()
        for view in contextViews {
            oldViews.insert(view)
            if let view = view as? CodeView {
                viewProvider.stashCodeView(view)
                continue
            }
            if let view = view as? TableView {
                viewProvider.stashTableView(view)
                continue
            }
            assertionFailure()
        }

        viewProvider.reorderViews(matching: contextViews)
        contextViews.removeAll()

        let artifacts = TextBuilder.build(view: self, viewProvider: viewProvider)
        textLabelView.attributedText = artifacts.document
        contextViews = artifacts.subviews
        blockFragmentCache = artifacts.fragmentCache

        for view in artifacts.subviews {
            if let view = view as? CodeView {
                view.textView.delegate = self
            }
            if let view = view as? TableView {
                view.textSelectionDelegate = self
            }
        }

        for goneView in oldViews where !artifacts.subviews.contains(goneView) {
            goneView.removeFromSuperview()
        }

        textLabelView.setNeedsLayout()
        setNeedsLayout()

        textLabelView.setNeedsDisplay()
        setNeedsDisplay()
    }
}

