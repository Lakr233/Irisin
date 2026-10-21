//
//  WelcomeConfirmationController.swift
//  Irisin
//
//  The onboarding page that offers to verify the device's owner, with
//  Face ID, Touch ID, Optic ID or the passcode, before a change to the
//  system. Shown only on a device that has one; the setting is on unless
//  the user says Not Now.
//

import SnapKit
import Then
import UIKit

class WelcomeConfirmationController: UIViewController {
    private let method: OperationConfirmation.Method
    private let onContinue: (UIViewController) -> Void

    /// `onContinue` is handed this page once the user has answered either way.
    init(method: OperationConfirmation.Method, onContinue: @escaping (UIViewController) -> Void) {
        self.method = method
        self.onContinue = onContinue
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .always
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Verify Ownership")
        view.backgroundColor = .groupedBackground

        let symbol = UIImageView(image: UIImage(systemName: method.symbol)).then {
            $0.tintColor = .buttonNormal
            $0.preferredSymbolConfiguration = .init(pointSize: 44)
        }
        let body = UILabel().then {
            $0.text = String(
                localized: "Irisin can verify that you own this device before it installs or removes packages."
            )
            $0.font = WelcomeStyle.subtitleFont
            $0.textColor = WelcomeStyle.titleColor
            $0.numberOfLines = 0
        }
        let detail = UILabel().then {
            $0.text = String(localized: "You can change this in Settings.")
            $0.font = WelcomeStyle.detailFont
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [symbol, body, detail]).then {
            $0.axis = .vertical
            $0.alignment = .leading
            $0.spacing = 16
            $0.setCustomSpacing(24, after: body)
        }
        let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
        let contentView = UIView()
        let actionBar = WelcomeActionBar(
            title: String(localized: "Turn On"),
            secondaryTitle: String(localized: "Not Now"),
            action: { [weak self] in self?.turnOn() },
            secondaryAction: { [weak self] in
                guard let self else { return }
                OperationConfirmation.isEnabled = false
                onContinue(self)
            }
        )
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        view.addSubview(actionBar)

        scrollView.snp.makeConstraints { x in
            x.top.leading.trailing.equalToSuperview()
            x.bottom.equalTo(actionBar.snp.top)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        // under the large title, and in line with it
        stack.snp.makeConstraints { x in
            x.top.equalToSuperview().inset(8)
            x.bottom.equalToSuperview().inset(24)
            x.leading.trailing.equalTo(view.layoutMarginsGuide)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }

    /// On once the owner has confirmed it works here; a cancel leaves the
    /// page up to answer again.
    private func turnOn() {
        Task { [weak self] in
            guard await OperationConfirmation.authenticate(), let self else { return }
            OperationConfirmation.isEnabled = true
            onContinue(self)
        }
    }
}
