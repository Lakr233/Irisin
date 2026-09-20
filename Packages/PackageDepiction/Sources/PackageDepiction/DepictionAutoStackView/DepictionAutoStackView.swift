//
//  DepictionAutoStackView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import UIKit

/// Children of a preferred width each, laid in rows that wrap at the edge,
/// every row centred.
final class DepictionAutoStackView: DepictionView {
    private var items: [(view: DepictionView, width: CGFloat)] = []
    private let spacing: CGFloat
    private var laidOutHeight: CGFloat = 0

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let views = dictionary["views"] as? [[String: Any]],
              let spacing = dictionary["horizontalSpacing"] as? CGFloat
        else {
            return nil
        }
        self.spacing = spacing
        var preferredWidths: [CGFloat] = []
        for viewDict in views {
            guard (viewDict["class"] as? String) != nil,
                  let preferredWidth = viewDict["preferredWidth"] as? CGFloat
            else {
                return nil
            }
            preferredWidths.append(preferredWidth)
        }

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        for (viewDict, preferredWidth) in zip(views, preferredWidths) {
            guard let view = DepictionView.view(
                dictionary: viewDict,
                viewController: viewController,
                tintColor: tintColor,
                isActionable: isActionable
            ) else {
                continue
            }
            // ponytail: rows are placed by hand, Auto Layout has no wrapping
            // row; each child is still constraint-built inside its frame.
            view.translatesAutoresizingMaskIntoConstraints = true
            items.append((view, preferredWidth))
            addSubview(view)
        }
        if let backgroundColor = dictionary["backgroundColor"] as? String {
            self.backgroundColor = UIColor(css: backgroundColor)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: laidOutHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }

        var rows: [(items: [(view: UIView, size: CGSize)], width: CGFloat)] = []
        for (view, preferred) in items {
            let itemWidth = min(preferred, width)
            let itemHeight = view.systemLayoutSizeFitting(
                CGSize(width: itemWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
            let item: (view: UIView, size: CGSize) = (view, CGSize(width: itemWidth, height: itemHeight))
            if let rowWidth = rows.last?.width, rowWidth + (itemWidth + spacing) <= width {
                rows[rows.count - 1].items.append(item)
                rows[rows.count - 1].width += itemWidth + spacing
            } else {
                rows.append((items: [item], width: itemWidth))
            }
        }

        var y: CGFloat = 0
        for row in rows {
            var x = (width - row.width) / 2
            for (view, size) in row.items {
                view.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + spacing
            }
            y += row.items.map(\.size.height).max() ?? 0
        }
        if y != laidOutHeight {
            laidOutHeight = y
            invalidateIntrinsicContentSize()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            for (view, _) in items {
                view.isHighlighted = isHighlighted
            }
        }
    }
}
