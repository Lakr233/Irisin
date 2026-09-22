//
//  DepictionButtonView.swift
//  Sileo
//
//  Created by CoolStar on 7/6/19.
//  Copyright © 2019 CoolStar. All rights reserved.
//

import SnapKit
import Then
import UIKit

final class DepictionButtonView: DepictionView {
    private let button = Button(type: .custom)

    private let action: String
    private let backupAction: String
    private let openExternal: Bool

    required init?(
        dictionary: [String: Any],
        viewController: UIViewController,
        tintColor: UIColor,
        isActionable: Bool
    ) {
        guard let action = dictionary["action"] as? String else {
            return nil
        }
        self.action = action
        backupAction = (dictionary["backupAction"] as? String) ?? ""
        openExternal = (dictionary["openExternal"] as? Bool) ?? false
        let isLink = (dictionary["isLink"] as? Bool) ?? false
        let yPadding = (dictionary["yPadding"] as? CGFloat) ?? 0

        super.init(
            dictionary: dictionary,
            viewController: viewController,
            tintColor: tintColor,
            isActionable: isActionable
        )

        button.isLink = isLink
        button.titleLabel?.font = .depictionBodyEmphasized
        button.setTitleColor(isLink ? tintColor : .white, for: .normal)
        if !isLink {
            button.layer.cornerRadius = 10
            button.backgroundColor = tintColor
        }
        button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        addSubview(button)

        let inset: CGFloat = isLink ? 0 : 8
        button.snp.makeConstraints { x in
            x.left.right.equalToSuperview().inset(inset)
            x.top.bottom.equalToSuperview().inset(inset + yPadding)
        }

        let content = (dictionary["view"] as? [String: Any]).flatMap { dict in
            DepictionView.view(
                dictionary: dict,
                viewController: viewController,
                tintColor: isLink ? tintColor : .white,
                isActionable: true
            )
        }
        if let content {
            content.isUserInteractionEnabled = false
            button.depictionView = content
            // a button that wraps a view has no title of its own, and the
            // words inside it are not read through it: its name is the text
            // the view it wraps was written with
            button.accessibilityLabel = (dictionary["view"] as? [String: Any])?["text"] as? String
            button.addSubview(content)
            content.snp.makeConstraints { x in
                x.edges.equalToSuperview()
            }
        } else {
            button.setTitle(dictionary["text"] as? String, for: .normal)
            button.snp.makeConstraints { x in
                x.height.equalTo(isLink ? 30 : 40)
            }
        }
    }

    @objc private func buttonTapped() {
        for action in [action, backupAction] {
            DepictionView.processAction(
                action,
                parentViewController: parentViewController,
                openExternal: openExternal
            )
        }
    }
}
