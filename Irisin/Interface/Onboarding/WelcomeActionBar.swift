//
//  WelcomeActionBar.swift
//  Irisin
//

import SnapKit
import Then
import UIKit

/// The bar under every onboarding page: a rule over a blur, and the page's
/// one button.
final class WelcomeActionBar: UIView {
    init(title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        let rule = UIView().then { $0.backgroundColor = .separator }
        let button = UIButton(type: .system)
        addSubview(blur)
        addSubview(rule)
        addSubview(button)

        blur.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        rule.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.height.equalTo(0.5)
        }
        button.snp.makeConstraints { x in
            x.top.equalTo(rule.snp.bottom).offset(12)
            x.leading.trailing.equalToSuperview().inset(24)
            x.bottom.equalTo(safeAreaLayoutGuide).inset(28)
            x.height.equalTo(48)
        }

        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.titleLabel?.font = WelcomeStyle.buttonFont
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = .buttonNormal
        configuration.baseForegroundColor = .onAccent
        configuration.title = title
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }
}
