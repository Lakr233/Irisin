import UIKit

final class OperationLogCell: UITableViewCell {
    private let numberLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .pageBackground
        selectionStyle = .none
        numberLabel.font = .monospaced(.caption2)
        numberLabel.textColor = .textSubtitle
        numberLabel.textAlignment = .right
        messageLabel.font = .monospaced(.footnote)
        messageLabel.textColor = .textTitle
        messageLabel.numberOfLines = 0
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(numberLabel)
        contentView.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            numberLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            numberLabel.widthAnchor.constraint(equalToConstant: 32),
            numberLabel.firstBaselineAnchor.constraint(equalTo: messageLabel.firstBaselineAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: numberLabel.trailingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            messageLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            messageLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
        isAccessibilityElement = true
        numberLabel.isAccessibilityElement = false
        messageLabel.isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    func configure(number: Int, message: String) {
        numberLabel.text = String(number)
        messageLabel.text = message
        accessibilityLabel = message
    }
}
