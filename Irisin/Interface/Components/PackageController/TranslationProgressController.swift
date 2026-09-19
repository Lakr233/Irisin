//
//  TranslationProgressController.swift
//  Irisin
//

// preconcurrency: the configuration is a plain static var upstream, only
// ever touched on the main actor here
@preconcurrency import AlertController
import SnapKit
import Then
import UIKit

/// The card a translation asked for from the Translate menu waits behind: a
/// spinner and Cancel. A card of our own, like Download Archive's: the
/// library's progress alert loads its view as it is made, so an action added
/// to it afterwards is never drawn.
///
/// Cancel only says so. Taking the card down is the page's, which knows
/// whether the translation is still this card's to stop.
final class TranslationProgressController: UIViewController {
    /// The card in the alert that presents it.
    static func alert(onCancel: @escaping () -> Void) -> AlertViewController {
        AlertViewController(contentViewController: TranslationProgressController(onCancel: onCancel))
    }

    private let onCancel: () -> Void
    private let cancelButton = UIButton(type: .system)

    private init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        let titleLabel = UILabel().then {
            $0.text = String(localized: "Translating…")
            $0.font = .bodyEmphasized
            $0.textColor = .label
        }
        let messageLabel = UILabel().then {
            $0.text = String(localized: "The system is translating this page.")
            $0.font = .footnote
            $0.textColor = .label
        }
        for label in [titleLabel, messageLabel] {
            label.textAlignment = .center
            label.numberOfLines = 0
        }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

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
            guard let self, cancelButton.isEnabled else { return }
            // once: the card is on its way out from here
            cancelButton.isEnabled = false
            onCancel()
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            artwork, titleLabel, messageLabel, spinner, cancelButton,
        ]).then {
            $0.axis = .vertical
            $0.alignment = .center
            $0.spacing = 12
            $0.setCustomSpacing(16, after: artwork)
            $0.setCustomSpacing(16, after: messageLabel)
            $0.setCustomSpacing(16, after: spinner)
        }
        view.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
        for child in [titleLabel, messageLabel, cancelButton] {
            child.snp.makeConstraints { $0.width.equalToSuperview() }
        }
    }
}
