import SnapKit
import UIKit

/// A persistent warning above an operation running with relaxed safeguards.
/// The table owns this header's frame; Auto Layout owns the full-width red
/// banner inside it and leaves breathing room above and below.
final class OperationWarningBanner: UIView {
    private let banner = UIView()
    private let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
    private let label = UILabel()

    init(title: String.LocalizationValue) {
        super.init(frame: .zero)
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = String(resolving: title)
        accessibilityTraits = .staticText

        banner.backgroundColor = .operationFailed

        icon.tintColor = .onAccent
        icon.preferredSymbolConfiguration = .init(.body, emphasized: true)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = .bodyEmphasized
        label.textColor = .onAccent
        label.numberOfLines = 0
        label.text = String(resolving: title)

        addSubview(banner)
        banner.addSubview(icon)
        banner.addSubview(label)
        banner.snp.makeConstraints { x in
            x.top.bottom.equalToSuperview().inset(12)
            x.leading.trailing.equalToSuperview()
        }
        icon.snp.makeConstraints { x in
            x.leading.equalToSuperview().inset(20)
            x.centerY.equalTo(label)
        }
        label.snp.makeConstraints { x in
            x.top.bottom.equalToSuperview().inset(12)
            x.leading.equalTo(icon.snp.trailing).offset(12)
            x.trailing.equalToSuperview().inset(20)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }
}
