//
//  UnsupportedArchitectureController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import SnapKit
import Then
import UIKit

/// The window's root when this build was packaged for another bootstrap:
/// it says so and closes the app. The interface never opens.
class UnsupportedArchitectureController: UIViewController {
    private let descriptionLabel = UILabel().then {
        $0.text = String(localized: "Unsupported Architecture")
        $0.textColor = .textMuted
        $0.font = .monospacedDigit(.caption, emphasized: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground

        view.addSubview(descriptionLabel)
        descriptionLabel.snp.makeConstraints { x in
            x.centerX.equalTo(self.view)
            x.centerY.equalTo(self.view).offset(25)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let message = PackagedArchitecture.incompatibilityMessage,
              presentedViewController == nil
        else { return }
        presentNotice(title: "Unsupported Architecture", message: message, dismissTitle: "Close") {
            UIApplication.prepareForExitAndSuspend()
        }
    }
}
