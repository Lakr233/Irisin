//
//  QueueBarView.swift
//  Irisin
//

import SnapKit
import Then
import UIKit

/// The bar that floats over a page while there is a queue: how many packages
/// it touches, and a tap opens it. A capsule of the system's own material,
/// glass from iOS 26, so it sits with the tab bar below it in either mode.
final class QueueBarView: UIControl {
    /// The capsule's height until the text size asks for more, and the gap
    /// `QueueBarDock` leaves around it.
    static let minimumHeight: CGFloat = 48
    static let spacing: CGFloat = 8
    /// As wide as the page lets it be, up to this.
    static let maximumWidth: CGFloat = 420

    /// The bar's height is not what it was: `QueueBarDock` makes room again.
    var heightChanged: (() -> Void)?
    private var laidOutHeight: CGFloat = 0

    /// How many packages the queue touches.
    var count = 0 {
        didSet {
            guard count != oldValue else { return }
            label.text = String(localized: "Packages in Queue: \(count)")
            accessibilityLabel = label.text
        }
    }

    private let glyph = UIImageView().then {
        $0.image = UIImage(systemName: "tray.full.fill", withConfiguration: UIImage.SymbolConfiguration(.body))
        $0.tintColor = .buttonNormal
        $0.contentMode = .center
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private let label = UILabel().then {
        $0.font = .rounded(.callout, emphasized: true)
        $0.textColor = .textTitle
        $0.numberOfLines = 2 // the largest text sizes wrap, and the bar grows
        $0.adjustsFontSizeToFitWidth = true
        $0.minimumScaleFactor = 0.8
    }

    private let chevron = UIImageView().then {
        $0.image = UIImage(
            systemName: "chevron.forward",
            withConfiguration: UIImage.SymbolConfiguration(.footnote, emphasized: true)
        )
        $0.tintColor = .textSubtitle
        $0.contentMode = .center
        $0.setContentHuggingPriority(.required, for: .horizontal)
        $0.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private let content = UIStackView().then {
        $0.axis = .horizontal
        $0.alignment = .center
        $0.spacing = 10
        $0.isUserInteractionEnabled = false
    }

    private let material = QueueBarView.makeMaterial()

    init() {
        super.init(frame: .zero)

        material.isUserInteractionEnabled = false // the whole bar is the button
        addSubview(material)
        material.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        content.addArrangedSubview(glyph)
        content.addArrangedSubview(label)
        content.addArrangedSubview(chevron)
        // inside the material, so glass keeps what is on it legible
        material.contentView.addSubview(content)
        content.snp.makeConstraints { x in
            x.leading.trailing.equalToSuperview().inset(18)
            x.top.bottom.equalToSuperview().inset(12)
        }
        snp.makeConstraints { x in
            x.height.greaterThanOrEqualTo(Self.minimumHeight)
        }

        if #unavailable(iOS 26.0) {
            layer.shadowColor = UIColor.floatingShadow.cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 4)
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens the queue.")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                // the content alone: the bar's own alpha is the dock's
                self.content.alpha = self.isHighlighted ? 0.4 : 1
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if #unavailable(iOS 26.0) { // glass is a capsule, and casts its own shadow
            material.layer.cornerRadius = bounds.height / 2
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
        }
        if bounds.height != laidOutHeight {
            laidOutHeight = bounds.height
            heightChanged?()
        }
    }

    private static func makeMaterial() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect()).then {
                $0.cornerConfiguration = .capsule()
            }
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)).then {
            $0.layer.cornerRadius = minimumHeight / 2
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
        }
    }
}
