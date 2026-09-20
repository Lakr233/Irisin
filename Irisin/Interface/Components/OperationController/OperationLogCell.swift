import SnapKit
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
        contentView.addSubview(numberLabel)
        contentView.addSubview(messageLabel)
        numberLabel.snp.makeConstraints { x in
            x.leading.equalToSuperview().inset(12)
            x.width.equalTo(32)
            x.firstBaseline.equalTo(messageLabel)
        }
        messageLabel.snp.makeConstraints { x in
            x.leading.equalTo(numberLabel.snp.trailing).offset(12)
            x.trailing.equalToSuperview().inset(20)
            x.top.bottom.equalToSuperview().inset(5)
        }
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
