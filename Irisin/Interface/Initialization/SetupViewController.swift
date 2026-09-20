//
//  SetupViewController.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/8.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import SnapKit
import Then
import UIKit

class SetupViewController: UIViewController {
    let descriptionLabel = UILabel().then {
        $0.text = ""
        $0.textColor = .textMuted
        $0.font = .monospacedDigit(.caption, emphasized: true)
    }

    private let indicator = UIActivityIndicatorView(style: .medium)

    /// Bootstrap runs once per process; a second setup controller that
    /// appears while the first is still working waits on the same task.
    private static var bootstrap: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .plainBackground

        indicator.startAnimating()
        view.addSubview(indicator)
        indicator.snp.makeConstraints { x in
            x.center.equalTo(self.view)
        }

        view.addSubview(descriptionLabel)
        descriptionLabel.snp.makeConstraints { x in
            x.centerX.equalTo(self.view)
            x.centerY.equalTo(self.view).offset(25)
        }

        #if !DEBUG
            UserDefaults.standard.set(false, forKey: "_UIConstraintBasedLayoutLogUnsatisfiable")
        #endif
        UITableView.appearance().sectionHeaderTopPadding = 0.0
        adoptDynamicTypeEverywhere()

        guard EnvironmentDetector.incompatibilityMessage == nil else {
            indicator.stopAnimating()
            descriptionLabel.text = String(localized: "Unsupported Architecture")
            return
        }

        Task { [weak self] in
            await Self.bootstrapApplication { text in
                self?.descriptionLabel.text = text
            }
            await self?.dispatchAllocInterface()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let message = EnvironmentDetector.incompatibilityMessage,
              presentedViewController == nil
        else { return }
        presentNotice(title: "Unsupported Architecture", message: message, dismissTitle: "Close") {
            UIApplication.prepareForExitAndSuspend()
        }
    }

    /// Brings up every engine, once per process. Their state lives on the
    /// main actor; each does its reading off it and returns when done.
    private static func bootstrapApplication(progress: @escaping (String) -> Void) async {
        if bootstrap == nil {
            bootstrap = Task {
                DeviceInfo.current.applyNetworkingHeaders()

                // MARK: - CENTER

                progress(String(localized: "Loading packages…"))
                await PackageCenter.default.load()
                progress(String(localized: "Loading repositories…"))
                await RepositoryCenter.default.load()
                progress(String(localized: "Setting up…"))

                // MARK: - PRIVILEGED BACKEND

                PrivilegedBackend.start()

                // MARK: - DOWNLOAD ENGINE

                CellularPolicy.allowForThisApplication()

                await DownloadCenter.shared.load()

                // MARK: - PROCESSOR

                _ = TaskProcessor.shared
            }
        }
        await bootstrap?.value
    }

    func dispatchAllocInterface() async {
        let controller = InterfaceHostController()
        controller.modalPresentationStyle = .fullScreen
        // this screen is still the loading one while the first page fills in
        await controller.prepare(filling: view.bounds, within: .milliseconds(200))
        // the interface covers this screen; nothing here keeps spinning
        indicator.stopAnimating()
        indicator.removeFromSuperview()
        descriptionLabel.removeFromSuperview()
        present(controller, animated: false)
    }
}
