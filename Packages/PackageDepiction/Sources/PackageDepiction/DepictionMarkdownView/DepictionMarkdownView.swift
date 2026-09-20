//
//  DepictionMarkdownView.swift
//  Sileo
//
//  Created by CoolStar on 11/18/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import MarkdownView
import SnapKit
import UIKit

final class DepictionMarkdownView: DepictionView {
    /// Markdown is a `MarkdownTextView`; html (`useRawFormat`) is a
    /// `HTMLView`. Both wear the same theme.
    private let content: UIView

    /// The width the markdown was last laid out for; its height follows.
    private var laidOutWidth: CGFloat = 0

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let markdown = dictionary["markdown"] as? String else {
            return nil
        }
        let useSpacing = (dictionary["useSpacing"] as? Bool) ?? true
        let useMargins = (dictionary["useMargins"] as? Bool) ?? true

        if (dictionary["useRawFormat"] as? Bool) == true {
            guard let htmlView = HTMLView(html: markdown, tintColor: tintColor) else {
                return nil
            }
            content = htmlView
        } else {
            let markdownView = MarkdownTextView()
            markdownView.theme = .depiction(tintColor: tintColor)
            markdownView.setMarkdown(markdown)
            content = markdownView
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        let open: (String) -> Void = { [weak self] action in
            DepictionView.processAction(
                action,
                parentViewController: self?.parentViewController,
                openExternal: false
            )
        }
        switch content {
        case let markdownView as MarkdownTextView:
            markdownView.linkHandler = { payload, _, _ in
                switch payload {
                case let .url(url): open(url.absoluteString)
                case let .string(string): open(string)
                }
            }
        case let htmlView as HTMLView:
            htmlView.linkHandler = open
        default:
            break
        }
        addSubview(content)
        content.snp.makeConstraints { x in
            x.left.right.equalToSuperview().inset(useMargins ? 16 : 0)
            x.top.bottom.equalToSuperview().inset(useSpacing ? 13 : 0)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // MarkdownTextView measures for the width it was last told, like a
        // label's preferredMaxLayoutWidth: a new width is a new height.
        guard let markdownView = content as? MarkdownTextView, markdownView.bounds.width != laidOutWidth else {
            return
        }
        laidOutWidth = markdownView.bounds.width
        _ = markdownView.boundingSize(for: laidOutWidth)
        markdownView.invalidateIntrinsicContentSize()
    }
}
