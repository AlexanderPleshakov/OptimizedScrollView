/// Host-supplied async batch fetcher. Methods run off the main actor inside
/// `ChatDataSource`. Implementations are typically network- or cache-backed and
/// free to be slow — the caller will not block the UI.
public protocol ChatDataSourceProvider: Sendable {
    func loadInitial() async throws -> Batch

    /// Returns the batch immediately below `cursor` (towards the bottom of history),
    /// or `nil` when no further content exists.
    func loadNext(after cursor: Cursor) async throws -> Batch?

    /// Returns the batch immediately above `cursor` (towards the top of history),
    /// or `nil` when no further content exists.
    func loadPrevious(before cursor: Cursor) async throws -> Batch?

    /// Returns the batch containing the given item id. The data source uses cursor
    /// equality to decide whether the fetched batch is adjacent to an existing
    /// `BatchList`; non-adjacent batches start a new list and become the active one.
    func loadBatch(containing id: ItemID) async throws -> Batch?
}
