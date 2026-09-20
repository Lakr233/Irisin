import UIKit

/// A persistent warning above an operation running with relaxed safeguards.
/// The symbol and text carry the meaning as well as the colour, and the table
/// owns the banner's outer size.
final class OperationWarningBanner: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
    private let label = UILabel()

    init(title: String.LocalizationValue) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .operationFailed
        isAccessibilityElement = true
        accessibilityLabel = String(localized: title)
        accessibilityTraits = .staticText

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .onAccent
        icon.preferredSymbolConfiguration = .init(.body, emphasized: true)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .bodyEmphasized
        label.textColor = .onAccent
        label.numberOfLines = 0
        label.text = String(localized: title)

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
