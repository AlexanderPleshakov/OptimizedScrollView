public extension ChatScrollView {
    /// A single mutation in a batch passed to `apply(_:)`.
    /// Removes are applied first, then inserts (in ascending index order),
    /// then updates. This keeps indices in `.insert(_, at:)` stable across the batch.
    enum Change: Sendable {
        case insert(any ChatItem, at: Int)
        case remove(ItemID)
        case update(any ChatItem)
    }
}
