import UIKit

@MainActor
final class ReusePool {
    private struct Registration {
        let factory: () -> UIView
        let configure: (UIView, any ChatItem) -> Void
    }

    private var registrations: [String: Registration] = [:]
    private var pools: [String: [UIView]] = [:]
    private var modelTypeToReuseId: [ObjectIdentifier: String] = [:]

    /// Registers a cell type. The model into reuseId mapping is recorded so the renderer
    /// can resolve a reuseId from an `any ChatItem` without help from the host.
    func register<Cell: ChatCellView>(_ cellType: Cell.Type) {
        registrations[Cell.reuseId] = Registration(
            factory: { Cell(frame: .zero) },
            configure: { view, item in
                guard let cell = view as? Cell else {
                    preconditionFailure(
                        "ReusePool: dequeued view is \(type(of: view)), expected \(Cell.self) for reuseId '\(Cell.reuseId)'"
                    )
                }
                guard let model = item as? Cell.Model else {
                    preconditionFailure(
                        "ReusePool: model type mismatch for reuseId '\(Cell.reuseId)' — expected \(Cell.Model.self), got \(type(of: item))"
                    )
                }
                cell.configure(with: model)
            }
        )
        modelTypeToReuseId[ObjectIdentifier(Cell.Model.self)] = Cell.reuseId
    }

    /// Auto-resolved reuseId for a given item, based on its dynamic type.
    /// Returns nil when the item's model type was never registered; the renderer
    /// falls back to the host-supplied resolver in that case.
    func reuseId(for item: any ChatItem) -> String? {
        modelTypeToReuseId[ObjectIdentifier(type(of: item))]
    }

    func dequeue(reuseId: String) -> UIView {
        guard let registration = registrations[reuseId] else {
            preconditionFailure("ReusePool: no cell registered for reuseId '\(reuseId)'")
        }
        if var bucket = pools[reuseId], let view = bucket.popLast() {
            pools[reuseId] = bucket
            return view
        }
        return registration.factory()
    }

    func enqueue(_ view: UIView, reuseId: String) {
        view.removeFromSuperview()
        pools[reuseId, default: []].append(view)
    }

    func configure(_ view: UIView, with item: any ChatItem, reuseId: String) {
        guard let registration = registrations[reuseId] else {
            preconditionFailure("ReusePool: no cell registered for reuseId '\(reuseId)'")
        }
        registration.configure(view, item)
    }
}
