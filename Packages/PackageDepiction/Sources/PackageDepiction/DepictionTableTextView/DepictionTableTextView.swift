//
//  DepictionTableTextView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionTableTextView: DepictionView {
    /// Not part of Sileo's format: the app's own depiction sets it to turn
    /// the value into a link (a maintainer's name opening `mailto:`).
    private let action: String?

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let title = dictionary["title"] as? String else {
            return nil
        }
        guard let text = dictionary["text"] as? String else {
            return nil
        }
        action = dictionary["action"] as? String

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        let titleLabel = UILabel().then {
            $0.text = title
            $0.font = .depictionBody
            $0.textColor = .depictionSecondaryLabel
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let textLabel = UILabel().then {
            $0.text = text
            $0.textAlignment = .right
            $0.font = .depictionBody
            $0.textColor = action == nil ? .label : tintColor
        }
        if action != nil {
            textLabel.isUserInteractionEnabled = true
            textLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(textTapped)))
            textLabel.isAccessibilityElement = true
            textLabel.accessibilityTraits = .link
        }
        addSubview(titleLabel)
        addSubview(textLabel)

        snp.makeConstraints { x in
            x.height.equalTo(44)
        }
        titleLabel.snp.makeConstraints { x in
            x.left.equalToSuperview().inset(16)
            x.centerY.equalToSuperview()
        }
        textLabel.snp.makeConstraints { x in
            x.left.equalTo(titleLabel.snp.right).offset(16)
            x.right.equalToSuperview().inset(16)
            x.centerY.equalToSuperview()
        }
    }

    @objc private func textTapped() {
        guard let action else { return }
        DepictionView.processAction(action, parentViewController: parentViewController, openExternal: true)
    }
}
