import UIKit
import OptimizedScrollView

final class MessageCell: UIView, ChatCellView {
    typealias Model = Message
    static let reuseId = "MessageCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Bottom is at .defaultHigh so a slight under-estimate of height by the
        // host produces overflow rather than an AutoLayout conflict warning.
        let bottom = label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        bottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bottom,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with model: Message) {
        label.text = model.text
        if model.isOutgoing {
            backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
            label.textAlignment = .right
            label.textColor = .systemBlue
        } else {
            backgroundColor = UIColor.systemGray5
            label.textAlignment = .left
            label.textColor = .label
        }
    }
}
