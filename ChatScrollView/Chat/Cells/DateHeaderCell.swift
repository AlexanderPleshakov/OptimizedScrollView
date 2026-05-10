import UIKit
import OptimizedScrollView

final class DateHeaderCell: UIView, ChatCellView {
    typealias Model = DateHeader
    static let reuseId = "DateHeaderCell"

    private let pill = UIView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Match chat background so the header pill occludes anything that
        // scrolls underneath when sticky-pinned.
        backgroundColor = .clear

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = .systemGray4
        pill.layer.cornerRadius = 11

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel

        addSubview(pill)
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 22),
            label.topAnchor.constraint(equalTo: pill.topAnchor),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with model: DateHeader) {
        label.text = model.dateText
    }
}
