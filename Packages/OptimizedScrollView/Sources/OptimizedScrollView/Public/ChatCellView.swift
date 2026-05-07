import UIKit

public protocol ChatCellView: UIView {
    associatedtype Model: ChatItem

    static var reuseId: String { get }

    func configure(with model: Model)
}
