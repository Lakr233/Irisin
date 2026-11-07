//
//  PackageProgressCard.swift
//  Irisin
//

import AlertController
import SnapKit
import Then
import UIKit

/// The card a long job on one package's .deb waits on: the package, what is
/// going on, a bar, a count and Cancel. A subclass does the job in `run`,
/// which starts once the card is on screen and is cancelled by the button.
class PackageProgressCard: UIViewController {
    private let cardTitle: String
    private let firstMessage: String
    private var work: Task<Void, Never>?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let countLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let cancelButton = UIButton(type: .system)

    init(title: String, message: String) {
        cardTitle = title
        firstMessage = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The job. Whatever it has to say after the card goes, it says after
    /// `close`, and it looks at `Task.isCancelled` first.
    func run() async {}

    /// What Cancel does beyond cancelling `run`'s task.
    func cancelled() {}

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        show(message: firstMessage)
    }

    /// Not before: a cached file finishes at once, and a card dismissed
    /// while it is still being presented stays on screen.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard work == nil else { return }
        work = Task { [weak self] in await self?.run() }
    }

    final func close() async {
        guard let alert = parent, alert.presentingViewController != nil, !alert.isBeingDismissed else { return }
        cancelButton.isEnabled = false
        await alert.dismissFinishing(animated: true)
    }

    /// Every line is on the card from the first frame, one line tall, so
    /// nothing here changes its height. A blank count still takes its line.
    final func show(message: String, fraction: Double = 0, count: String = " ") {
        messageLabel.text = message
        countLabel.text = count
        bar.moveProgress(to: Float(fraction))
    }

    private func build() {
        view.backgroundColor = AlertControllerConfiguration.backgroundColor.withAlphaComponent(0.5)
        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        view.addSubview(material)
        material.snp.makeConstraints { $0.edges.equalToSuperview() }

        let artwork = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 12
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
            $0.snp.makeConstraints { $0.size.equalTo(64) }
        }
        titleLabel.do {
            $0.text = cardTitle
            $0.font = .bodyEmphasized
            $0.textColor = .label
        }
        messageLabel.do {
            $0.font = .footnote
            $0.textColor = .label
        }
        countLabel.do {
            $0.font = .monospacedDigit(.footnote)
            $0.textColor = .secondaryLabel
        }
        for label in [titleLabel, messageLabel, countLabel] {
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingMiddle
        }
        bar.progressTintColor = AlertControllerConfiguration.accentColor

        // a lone action is the accent one, as the library draws it; the
        // library does not export its button
        var accent = UIButton.Configuration.filled()
        accent.title = String(localized: "Cancel")
        accent.baseForegroundColor = AlertControllerConfiguration.accentForegroundColor
        accent.baseBackgroundColor = AlertControllerConfiguration.accentColor
        accent.background.cornerRadius = 12
        accent.cornerStyle = .fixed
        accent.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8)
        accent.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var outgoing = $0
            outgoing.font = .bodyEmphasized
            return outgoing
        }
        cancelButton.configuration = accent
        cancelButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            work?.cancel()
            cancelled()
            Task { await self.close() }
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            artwork, titleLabel, messageLabel, bar, countLabel, cancelButton,
        ]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 12
            $0.setCustomSpacing(16, after: artwork)
            $0.setCustomSpacing(16, after: messageLabel)
            $0.setCustomSpacing(8, after: bar)
            $0.setCustomSpacing(16, after: countLabel)
        }
        view.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
        for child in stack.arrangedSubviews where child !== artwork {
            child.snp.makeConstraints { $0.width.equalToSuperview() }
        }
    }
}
