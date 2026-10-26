//
//  LaunchpadController.swift
//  IrisinLaunchpad
//

import AptRepository
import Combine
import UIKit

/// The launchpad's one screen (Documentation/WebManagement.md): the
/// device, the address and code that open it in a browser, the QR code of
/// both, and what is going on. The owner's answers come up over it
/// (`QuestionController`); everything else is the page's.
final class LaunchpadController: UIViewController {
    private let titleLabel = UILabel()
    private let deviceLabel = UILabel()
    private let instructionLabel = UILabel()
    private let addressLabel = UILabel()
    private let codeCaption = UILabel()
    private let codeLabel = UILabel()
    private let qrGround = UIView()
    private let qrView = UIImageView()
    private let statusLabel = UILabel()

    private var subscriptions = Set<AnyCancellable>()
    private var ticker: Task<Void, Never>?
    private weak var asking: QuestionController?

    /// The QR code's side, in points: read from across a room on a
    /// television, from arm's length in a window.
    private static var codeSide: CGFloat {
        #if os(tvOS)
            420
        #else
            260
        #endif
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        layout()
        WebManagement.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.show(status) }
            .store(in: &subscriptions)
        WebManagement.shared.$question
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] question in self?.ask(question) }
            .store(in: &subscriptions)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // what runs, and whether the daemon answered, read once a second;
        // the addresses too, since the network can change under the screen
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateStatus()
                WebManagement.shared.refreshAddresses()
                try? await Task.sleep(continuousSeconds: 1)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Layout

    private func layout() {
        titleLabel.font = .launchpadTitle
        titleLabel.textColor = .launchpadPrimaryText
        titleLabel.text = "Irisin"

        deviceLabel.font = .launchpadCaption
        deviceLabel.textColor = .launchpadSecondaryText
        let device = UIDevice.current
        deviceLabel.text = "\(device.name) · \(device.systemName) \(device.systemVersion)"

        instructionLabel.font = .launchpadBody
        instructionLabel.textColor = .launchpadSecondaryText
        instructionLabel.numberOfLines = 0

        addressLabel.font = .launchpadAddress
        addressLabel.textColor = .launchpadPrimaryText
        addressLabel.numberOfLines = 0

        codeCaption.font = .launchpadHeadline
        codeCaption.textColor = .launchpadSecondaryText
        codeCaption.text = String(localized: "Verification Code")

        codeLabel.font = .launchpadCode
        codeLabel.textColor = .launchpadAccent

        statusLabel.font = .launchpadCaption
        statusLabel.textColor = .launchpadSecondaryText
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center

        qrGround.backgroundColor = .launchpadCodeGround
        qrGround.layer.cornerRadius = 24
        qrGround.layer.cornerCurve = .continuous
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.contentMode = .scaleAspectFit
        qrView.layer.magnificationFilter = .nearest
        qrGround.addSubview(qrView)

        let header = UIStackView(arrangedSubviews: [titleLabel, deviceLabel])
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 8

        let code = UIStackView(arrangedSubviews: [codeCaption, codeLabel])
        code.axis = .vertical
        code.spacing = 4

        let text = UIStackView(arrangedSubviews: [instructionLabel, addressLabel, code])
        text.axis = .vertical
        text.spacing = 28
        text.setCustomSpacing(40, after: addressLabel)

        let body = UIStackView(arrangedSubviews: [text, qrGround])
        body.axis = .horizontal
        body.alignment = .center
        body.spacing = 80

        let content = UIStackView(arrangedSubviews: [header, body, statusLabel])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = 64
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        let side = Self.codeSide
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: margins.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: margins.topAnchor),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: side * 2),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: margins.widthAnchor),
            qrGround.widthAnchor.constraint(equalToConstant: side),
            qrGround.heightAnchor.constraint(equalToConstant: side),
            qrView.topAnchor.constraint(equalTo: qrGround.topAnchor, constant: 24),
            qrView.leadingAnchor.constraint(equalTo: qrGround.leadingAnchor, constant: 24),
            qrView.trailingAnchor.constraint(equalTo: qrGround.trailingAnchor, constant: -24),
            qrView.bottomAnchor.constraint(equalTo: qrGround.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - State

    private func show(_ status: WebManagement.Status) {
        let serving = status.code != nil && !status.addresses.isEmpty
        addressLabel.isHidden = !serving
        codeCaption.superview?.isHidden = !serving
        qrGround.isHidden = !serving
        if let problem = PackagedArchitecture.incompatibilityMessage {
            instructionLabel.text = problem
        } else if let problem = status.problem {
            instructionLabel.text = problem
        } else if status.code == nil {
            instructionLabel.text = String(localized: "Starting…")
        } else if status.addresses.isEmpty {
            instructionLabel.text = String(localized: "Connect this device to Wi-Fi or Ethernet to manage it from a browser.")
        } else {
            instructionLabel.text = String(localized: "On a phone or computer on the same network, scan the code or open this address:")
        }
        guard serving, let code = status.code, let first = status.addresses.first else { return }
        // the address as typed, without the code the QR code carries in its fragment
        addressLabel.text = status.addresses
            .map { $0.split(separator: "#").first.map(String.init) ?? $0 }
            .joined(separator: "\n")
        codeLabel.text = "\(code.prefix(3)) \(code.suffix(3))"
        codeLabel.accessibilityLabel = code.map(String.init).joined(separator: " ")
        qrView.image = QRCodeImage.make(first, side: Self.codeSide - 48, scale: traitCollection.displayScale)
    }

    private func updateStatus() {
        var lines = [PrivilegedBackend.localizedStatus]
        if WebCalls.isBusy {
            lines.append(String(localized: "Installing. Follow it in the browser."))
        } else if RepositoryCenter.default.obtainUpdateRemain() > 0 {
            lines.append(String(localized: "Refreshing repositories…"))
        }
        let text = lines.joined(separator: "\n")
        if statusLabel.text != text {
            statusLabel.text = text
        }
    }

    // MARK: - Owner

    /// Puts the browser's question on screen, and takes it away once it is
    /// answered or nobody can answer it any more.
    private func ask(_ question: WebManagement.Question?) {
        if let asking, asking.question != question {
            asking.dismiss(animated: true)
            self.asking = nil
        }
        guard let question, asking == nil else { return }
        let controller = QuestionController(question: question)
        asking = controller
        // whatever is on screen, the question goes over it
        var host: UIViewController = self
        while let presented = host.presentedViewController, presented !== controller {
            host = presented
        }
        host.present(controller, animated: true)
    }
}
