//
//  MarkdownTextView+ContextViewLayout.swift
//  MarkdownView
//
//  Created by Codex on 7/3/26.
//

import Foundation
import Litext
import UIKit

extension MarkdownTextView {
    func syncContextViewLayout() {
        var placed: Set<UIView> = []

        for run in textLabelView.layoutRuns(matching: .contextView) {
            if let codeView = run.attributes[.contextView] as? CodeView {
                syncCodeView(codeView, with: run)
                placed.insert(codeView)
                continue
            }

            if let tableView = run.attributes[.contextView] as? TableView {
                syncTableView(tableView, with: run)
                placed.insert(tableView)
            }
        }

        // A view whose line did not survive this layout pass has no known
        // position, and its previous frame belongs to a layout that no longer
        // exists. Hide it rather than let it paint over the text.
        for view in contextViews {
            view.isHidden = !placed.contains(view)
        }

        syncBlockquoteBars()
    }

    /// Gives every blockquote a bar spanning all of its lines.
    ///
    /// The bar is a view instead of a line drawing action because an action
    /// only runs for the lines a redraw touches, which paints a bar spanning
    /// several lines in fragments.
    private func syncBlockquoteBars() {
        let spans = blockquoteLineSpans()

        while blockquoteBars.count < spans.count {
            let bar = BlockquoteBarView()
            blockquoteBars.append(bar)
            addSubview(bar)
        }
        while blockquoteBars.count > spans.count {
            blockquoteBars.removeLast().removeFromSuperview()
        }

        for (bar, span) in zip(blockquoteBars, spans) {
            bar.setTheme(theme)
            bar.isHidden = false
            setFrameIfNeeded(for: bar, to: span)
        }
    }

    private func syncCodeView(_ codeView: CodeView, with run: TextLabel.LayoutRun) {
        if codeView.superview != self {
            addSubview(codeView)
        }
        codeView.textView.delegate = self
        codeView.previewAction = codePreviewHandler
        setFrameIfNeeded(
            for: codeView,
            to: contextViewFrame(for: run, height: codeView.intrinsicContentSize.height)
        )
    }

    private func syncTableView(_ tableView: TableView, with run: TextLabel.LayoutRun) {
        if tableView.superview != self {
            addSubview(tableView)
        }
        tableView.linkHandler = linkHandler
        tableView.textSelectionDelegate = self
        setFrameIfNeeded(
            for: tableView,
            to: contextViewFrame(for: run, height: tableView.intrinsicContentSize.height)
        )
    }

    private func contextViewFrame(for run: TextLabel.LayoutRun, height: CGFloat) -> CGRect {
        let leftIndent = paragraphHeadIndent(in: run.attributes)
        return CGRect(
            x: textLabelView.frame.minX + run.lineRect.minX + leftIndent,
            y: textLabelView.frame.minY + textLabelView.bounds.height - run.lineRect.maxY,
            width: max(0, textLabelView.bounds.width - leftIndent),
            height: height
        )
    }

    private func paragraphHeadIndent(in attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        guard let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle else {
            return 0
        }
        return paragraphStyle.headIndent
    }

    private func setFrameIfNeeded(for view: UIView, to frame: CGRect) {
        guard view.frame != frame else { return }
        view.frame = frame
    }
}
