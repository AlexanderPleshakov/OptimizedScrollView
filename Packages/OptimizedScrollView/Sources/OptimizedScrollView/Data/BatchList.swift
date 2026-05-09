import DequeModule

/// An ordered chain of adjacent batches (top –> bottom). Adjacency is enforced at
/// the call site — `BatchList.append`/`prepend` trust the caller to have verified
/// cursor equality. Non-adjacent batches go into separate lists.
///
/// `batches` is a `Deque`.
struct BatchList: Sendable {
    let id: BatchListID
    var batches: Deque<Batch>

    init(id: BatchListID, batches: Deque<Batch>) {
        self.id = id
        self.batches = batches
    }

    init(id: BatchListID, batches: [Batch]) {
        self.id = id
        self.batches = Deque(batches)
    }

    var topCursor: Cursor? { batches.first?.topCursor }
    var bottomCursor: Cursor? { batches.last?.bottomCursor }

    var items: [any ChatItem] {
        var out: [any ChatItem] = []
        out.reserveCapacity(batches.reduce(0) { $0 + $1.items.count })
        for batch in batches { out.append(contentsOf: batch.items) }
        return out
    }

    func contains(itemId: ItemID) -> Bool {
        for batch in batches where batch.items.contains(where: { $0.id == itemId }) {
            return true
        }
        return false
    }

    mutating func append(_ batch: Batch) { batches.append(batch) }
    mutating func prepend(_ batch: Batch) { batches.prepend(batch) }
}
