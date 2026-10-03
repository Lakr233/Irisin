//
//  MarkdownTextView+ContextViewLayout.swift
//  MarkdownView
//
//  Created by Codex on 7/3/26.
//

import Foundation
import Litext

extension MarkdownTextView {
    func syncContextViewLayout() {
        var placed: Set<UIView> = []
        contextViewLocations.removeAll(keepingCapacity: true)

        for run in textLabelView.layoutRuns(matching: .contextView) {
            if let view = run.attributes[.contextView] as? UIView {
                contextViewLocations[ObjectIdentifier(view)] = run.stringRange.location
            }
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
        syncContextViewSelection()
    }

    /// Gives every blockquote a bar spanning all of its lines.
    ///
    /// The bar is a view instead of a line drawing action because an action
    /// only runs for the lines a redraw touches, which paints a bar spanning
    /// several lines in fragments.
    private func syncBlockquoteBars() {
        let spans = blockquoteLineSpans()

        while blockquoteBars.count > spans.count {
            blockquoteBars.removeLast().removeFromSuperview()
        }

        for (index, span) in spans.enumerated() {
            guard index < blockquoteBars.count else {
                let bar = BlockquoteBarView()
                bar.setTheme(theme)
                bar.place(at: span, in: self)
                blockquoteBars.append(bar)
                continue
            }
            let bar = blockquoteBars[index]
            bar.setTheme(theme)
            bar.isHidden = false
            setFrameIfNeeded(for: bar, to: span)
        }
    }

    private func syncCodeView(_ codeView: CodeView, with run: TextLabel.LayoutRun) {
        codeView.textView.delegate = self
        codeView.previewAction = codePreviewHandler
        codeView.actionProvider = codeBlockActionProvider
        placeContextView(
            codeView,
            at: contextViewFrame(for: run, height: codeView.intrinsicContentSize.height)
        )
    }

    private func syncTableView(_ tableView: TableView, with run: TextLabel.LayoutRun) {
        tableView.linkHandler = linkHandler
        tableView.textSelectionDelegate = self
        placeContextView(
            tableView,
            at: contextViewFrame(for: run, height: tableView.intrinsicContentSize.height)
        )
    }

    /// Moves a view that was on screen last pass; places one that was not —
    /// new, taken from the pool, or hidden — straight at `frame`, so it does
    /// not animate in from wherever it last was.
    private func placeContextView(_ view: UIView, at frame: CGRect) {
        guard view.superview === self, !view.isHidden else {
            view.place(at: frame, in: self)
            return
        }
        setFrameIfNeeded(for: view, to: frame)
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
