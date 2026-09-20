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
    /// The capsule's height, and the gap `QueueBarDock` leaves around it.
    static let height: CGFloat = 48
    static let spacing: CGFloat = 8
    /// As wide as the page lets it be, up to this.
    static let maximumWidth: CGFloat = 420

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

    init() {
        super.init(frame: .zero)

        let material = Self.makeMaterial()
        material.isUserInteractionEnabled = false // the whole bar is the button
        addSubview(material)
        material.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }

        content.addArrangedSubview(glyph)
        content.addArrangedSubview(label)
        content.addArrangedSubview(chevron)
        addSubview(content)
        content.snp.makeConstraints { x in
            x.leading.trailing.equalToSuperview().inset(18)
            x.centerY.equalToSuperview()
        }
        snp.makeConstraints { x in
            x.height.equalTo(Self.height)
        }

        if #unavailable(iOS 26.0) {
            layer.shadowColor = UIColor.floatingShadow.cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 4)
        }

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Open Queue")
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
        guard #unavailable(iOS 26.0) else { return } // glass casts its own
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    private static func makeMaterial() -> UIView {
        if #available(iOS 26.0, *) {
            return UIVisualEffectView(effect: UIGlassEffect()).then {
                $0.cornerConfiguration = .capsule()
            }
        }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial)).then {
            $0.layer.cornerRadius = height / 2
            $0.layer.cornerCurve = .continuous
            $0.clipsToBounds = true
        }
    }
}
