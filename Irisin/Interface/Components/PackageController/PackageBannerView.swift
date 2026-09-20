//
//  PackageBannerView.swift
//  Irisin
//
//  Created by Lakr Aream on 2021/8/17.
//  Copyright © 2021 Lakr Aream. All rights reserved.
//

import AptRepository
import Combine
import Then
import UIKit

class PackageBannerView: UIView {
    let package: Package

    var icon = UIImageView().then {
        $0.clipsToBounds = true
        $0.layer.cornerRadius = 8
        $0.contentMode = .scaleAspectFill
        $0.tintColor = .buttonNormal
    }

    /// The name is read whole: it wraps, and the banner grows with it.
    var name = UILabel().then {
        $0.textColor = .textTitle
        $0.font = .title
        $0.numberOfLines = 0
    }

    var version = UILabel().then {
        $0.textColor = .textSubtitle
        $0.font = .subheadline
    }

    let padding = 15

    var button = UIButton().then {
        $0.titleLabel?.numberOfLines = 1
        $0.titleLabel?.minimumScaleFactor = 0.2
        $0.titleLabel?.lineBreakMode = .byClipping
        $0.titleLabel?.font = .bodyEmphasized
        $0.setTitleColor(.onAccent, for: .normal)
        $0.setTitleColor(.onAccentPressed, for: .highlighted)
    }

    let buttonBackground = UIView().then {
        $0.backgroundColor = .buttonNormal
        $0.layer.cornerRadius = 17
    }

    private var queueSubscription: AnyCancellable?

    init(package: Package) {
        self.package = PackageMenu.requestPackage(for: package)

        super.init(frame: CGRect())

        addSubview(icon)
        addSubview(name)
        addSubview(version)
        addSubview(buttonBackground)
        addSubview(button)

        // 80 tall around a name of one line, as it always was; a longer
        // name makes the banner taller and the icon stays beside its middle
        snp.makeConstraints { x in
            x.height.greaterThanOrEqualTo(80)
        }
        icon.snp.makeConstraints { x in
            x.centerY.equalToSuperview()
            x.left.equalToSuperview().offset(padding)
            x.width.height.equalTo(50)
        }
        name.snp.makeConstraints { x in
            x.left.equalTo(icon.snp.right).offset(8)
            x.top.greaterThanOrEqualToSuperview().offset(padding)
            x.right.equalTo(button.snp.left).offset(-12)
        }
        version.snp.makeConstraints { x in
            x.left.equalTo(icon.snp.right).offset(8)
            x.top.equalTo(name.snp.bottom).offset(2)
            x.bottom.lessThanOrEqualToSuperview().offset(-padding)
            x.right.equalTo(button.snp.left).offset(-8)
        }
        // the two lines sit around the middle together
        let text = UILayoutGuide()
        addLayoutGuide(text)
        text.snp.makeConstraints { x in
            x.top.equalTo(name)
            x.bottom.equalTo(version)
            x.centerY.equalToSuperview()
        }

        // a tap installs or updates, a long press opens the menu
        button.menu = actionMenu
        button.addTarget(self, action: #selector(performQuickAction), for: .touchUpInside)

        button.snp.makeConstraints { x in
            x.centerY.equalToSuperview()
            x.right.equalToSuperview().offset(-20)
            x.width.equalTo(50)
            x.height.equalTo(34)
        }
        buttonBackground.snp.makeConstraints { x in
            x.top.equalTo(button)
            x.bottom.equalTo(button)
            x.leading.equalTo(button).offset(-8)
            x.trailing.equalTo(button).offset(8)
        }

        updateValues()
        // Open Queue follows the queue, whichever page changed it
        queueSubscription = NotificationCenter.default.publisher(for: .TaskQueueChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButton() }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        button.titleLabel?.alpha = 1
    }

    /// The package itself never changes under this view: name, version and
    /// icon are set once.
    func updateValues() {
        name.text = PackageCenter.default.name(of: package)
        // the version, then what the repository says the download weighs
        // (what it takes on disk for a package only dpkg knows)
        version.text = [
            package.latestVersion ?? String(localized: "Unknown"),
            (package.publishedSize ?? package.installedSize).map(DownloadCenter.shared.byteFormat),
        ].compactMap(\.self).joined(separator: " · ")
        icon.showIcon(of: package)
        updateButton()
    }

    /// The name as the page reads: the translation in its place, under it
    /// when the page compares, and as written with none. An engine that
    /// hands the name back (a name is often no word at all) changes nothing.
    func showName(translated: String?, comparing: Bool) {
        let written = PackageCenter.default.name(of: package)
        let text = if let translated, translated != written {
            comparing ? written + "\n" + translated : translated
        } else {
            written
        }
        guard name.text != text else { return }
        UIView.transition(
            with: name,
            duration: 0.35,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) { self.name.text = text }
    }

    func updateButton() {
        button.setTitle(grabButtonString(), for: .normal)
        // with nothing to install or update, the tap opens the menu itself;
        // a queued package keeps its tap for the queue, an unsupported one
        // for the explanation
        button.showsMenuAsPrimaryAction = obtainQuickAction() == nil
            && !opensQueue
            && (package.isSupportedOnDevice || package.localFileURL != nil)

        // now we need to update button size from localized string
        var width = button.intrinsicContentSize.width
        if width < 50 {
            width = 50
        }
        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: 1.0,
            initialSpringVelocity: 0.8,
            options: .curveEaseInOut
        ) {
            self.button.snp.updateConstraints { make in
                make.width.equalTo(width + 10) // so min would be 60
            }
            self.button.layoutIfNeeded()
        } completion: { _ in }
    }

    func grabButtonString() -> String {
        if !package.isSupportedOnDevice, package.localFileURL == nil {
            return String(localized: "Unsupported").uppercased()
        }
        if TaskManager.shared.isQueued(package.identity) {
            return (obtainQuickAction()?.descriptor.describe() ?? String(localized: "Open Queue")).uppercased()
        }
        if PackageCenter
            .default
            .obtainPackageInstallationInfo(with: package.identity)
            == nil
        {
            if let tag = package.latestMetadata?["tag"],
               tag.contains("cydia::commercial")
            {
                return String(localized: "Buy").uppercased()
            }
            return String(localized: "Install").uppercased()
        }
        return obtainQuickAction()?.descriptor.describe() ?? String(localized: "Actions")
    }
}
