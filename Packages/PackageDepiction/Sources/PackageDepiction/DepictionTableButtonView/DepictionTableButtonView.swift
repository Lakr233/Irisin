//
//  DepictionTableButtonView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionTableButtonView: DepictionView {
    private let action: String
    private let backupAction: String
    private let openExternal: Bool

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let title = dictionary["title"] as? String else {
            return nil
        }
        guard let action = dictionary["action"] as? String else {
            return nil
        }
        self.action = action
        backupAction = (dictionary["backupAction"] as? String) ?? ""
        openExternal = (dictionary["openExternal"] as? Bool) ?? false

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        let titleLabel = UILabel().then {
            $0.text = title
            $0.font = .depictionBody
            $0.textColor = tintColor
        }
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right")).then {
            $0.preferredSymbolConfiguration = .init(font: .depictionBody, scale: .small)
            $0.tintColor = tintColor
            $0.setContentHuggingPriority(.required, for: .horizontal)
        }
        addSubview(titleLabel)
        addSubview(chevron)

        snp.makeConstraints { x in
            x.height.equalTo(44)
        }
        titleLabel.snp.makeConstraints { x in
            x.left.equalToSuperview().inset(16)
            x.centerY.equalToSuperview()
        }
        chevron.snp.makeConstraints { x in
            x.left.equalTo(titleLabel.snp.right).offset(8)
            x.right.equalToSuperview().inset(16)
            x.centerY.equalToSuperview()
        }

        let press = UILongPressGestureRecognizer(target: self, action: #selector(buttonTapped))
        press.minimumPressDuration = 0.05
        addGestureRecognizer(press)

        accessibilityTraits = .link
        isAccessibilityElement = true
        accessibilityLabel = title
    }

    override func accessibilityActivate() -> Bool {
        buttonTapped(nil)
        return true
    }

    @objc private func buttonTapped(_ gestureRecognizer: UIGestureRecognizer?) {
        if let gestureRecognizer, gestureRecognizer.state != .ended {
            return
        }
        for action in [action, backupAction] {
            DepictionView.processAction(
                action,
                parentViewController: parentViewController,
                openExternal: openExternal
            )
        }
    }
}
