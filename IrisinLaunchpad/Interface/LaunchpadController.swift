//
//  LaunchpadController.swift
//  IrisinLaunchpad
//

import AptRepository
import Combine
import UIKit

/// The launchpad's one screen (Documentation/WebManagement.md): the QR
/// code, and under it the address and code it carries, for a browser on
/// the same network; a line at the foot when there is something going on.
/// The owner's answers come up over it as the system's alert
/// (`QuestionAlert`); everything else is the page's.
final class LaunchpadController: UIViewController {
    private let qrGround = UIView()
    private let qrView = UIImageView()
    private let instructionLabel = UILabel()
    private let addressLabel = UILabel()
    private let codeCaption = UILabel()
    private let codeLabel = UILabel()
    private let statusLabel = UILabel()

    private var subscriptions = Set<AnyCancellable>()
    private var ticker: Task<Void, Never>?
    private weak var asking: UIAlertController?
    private var askingID: WebManagement.Question.ID?

    /// The QR code's side, in points: read from across a room on a
    /// television, from arm's length in a window.
    private static var codeSide: CGFloat {
        #if os(tvOS)
            400
        #else
            320
        #endif
    }

    /// The white around the code that a camera needs to find its edge.
    private static let quietZone: CGFloat = 24

    /// The gap between the lines of the screen: a line's height, so they
    /// read double-spaced. The QR code keeps twice it above them.
    private static var spacing: CGFloat {
        UIFont.launchpadText.lineHeight.rounded()
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
        // what runs read once a second; the addresses too, since the
        // network can change under the screen
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
        qrGround.backgroundColor = .launchpadCodeGround
        qrGround.layer.cornerRadius = Self.quietZone
        qrGround.layer.cornerCurve = .continuous
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.contentMode = .scaleAspectFit
        qrView.layer.magnificationFilter = .nearest
        qrGround.addSubview(qrView)

        instructionLabel.font = .launchpadText
        instructionLabel.textColor = .launchpadSecondaryText
        instructionLabel.numberOfLines = 0
        instructionLabel.textAlignment = .center

        addressLabel.font = .launchpadEmphasis
        addressLabel.textColor = .launchpadPrimaryText
        addressLabel.numberOfLines = 0
        addressLabel.textAlignment = .center

        codeCaption.font = .launchpadText
        codeCaption.textColor = .launchpadSecondaryText
        codeCaption.text = String(localized: "Verification Code")

        codeLabel.font = .launchpadEmphasis
        codeLabel.textColor = .launchpadPrimaryText

        statusLabel.font = .launchpadText
        statusLabel.textColor = .launchpadSecondaryText
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        let content = UIStackView(arrangedSubviews: [qrGround, instructionLabel, addressLabel, codeCaption, codeLabel])
        content.axis = .vertical
        content.alignment = .center
        content.spacing = Self.spacing
        content.setCustomSpacing(Self.spacing * 2, after: qrGround)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        let side = Self.codeSide
        let inset = Self.quietZone
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: margins.centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: margins.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: statusLabel.topAnchor, constant: -Self.spacing),
            instructionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: side * 4),
            qrGround.widthAnchor.constraint(equalToConstant: side),
            qrGround.heightAnchor.constraint(equalToConstant: side),
            qrView.topAnchor.constraint(equalTo: qrGround.topAnchor, constant: inset),
            qrView.leadingAnchor.constraint(equalTo: qrGround.leadingAnchor, constant: inset),
            qrView.trailingAnchor.constraint(equalTo: qrGround.trailingAnchor, constant: -inset),
            qrView.bottomAnchor.constraint(equalTo: qrGround.bottomAnchor, constant: -inset),
            statusLabel.centerXAnchor.constraint(equalTo: margins.centerXAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: margins.widthAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
    }

    // MARK: - State

    private func show(_ status: WebManagement.Status) {
        let serving = status.code != nil && !status.addresses.isEmpty
        qrGround.isHidden = !serving
        addressLabel.isHidden = !serving
        codeCaption.isHidden = !serving
        codeLabel.isHidden = !serving
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
        // the address as typed: without the code the QR code carries in its
        // fragment, or the slash a browser puts back
        addressLabel.text = status.addresses
            .map { address in
                let page = address.split(separator: "#").first.map(String.init) ?? address
                return page.hasSuffix("/") ? String(page.dropLast()) : page
            }
            .joined(separator: "\n")
        codeLabel.text = "\(code.prefix(3)) \(code.suffix(3))"
        codeLabel.accessibilityLabel = code.map(String.init).joined(separator: " ")
        let side = Self.codeSide - Self.quietZone * 2
        qrView.image = QRCodeImage.make(first, side: side, scale: traitCollection.displayScale)
    }

    /// Only what the owner should know at the screen: an operation the page
    /// runs, a refresh, or a build that can only browse. A daemon that has
    /// not answered yet is not news (AGENTS.md).
    private func updateStatus() {
        var lines: [String] = []
        if let backend = PrivilegedBackend.backend, !backend.isPrivileged {
            lines.append(PrivilegedBackend.localizedStatus)
        }
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
        if let asking, askingID != question?.id {
            // answered from its own buttons, the alert is already leaving
            if !asking.isBeingDismissed {
                asking.presentingViewController?.dismiss(animated: true)
            }
            self.asking = nil
        }
        guard let question, asking == nil else { return }
        let alert = QuestionAlert.make(question)
        asking = alert
        askingID = question.id
        // whatever is on screen, the question goes over it
        var host: UIViewController = self
        while let presented = host.presentedViewController {
            host = presented
        }
        host.present(alert, animated: true)
    }
}
