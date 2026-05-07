public struct BatchID: Hashable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// Opaque pagination cursor. The host designs cursor values so that two batches
/// are adjacent iff `B.topCursor == A.bottomCursor` (i.e. `B` is the result of
/// `loadNext(after: A.bottomCursor)`). The data source uses cursor equality to
/// decide whether a freshly fetched batch can be spliced into an existing
/// `BatchList` or must start a new one.
public struct Cursor: Hashable, Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct Batch: Sendable {
    public let id: BatchID
    public let items: [any ChatItem]
    /// Cursor used to fetch the batch immediately above this one (`loadPrevious`).
    /// `nil` means there is nothing above (top of history).
    public let topCursor: Cursor?
    /// Cursor used to fetch the batch immediately below this one (`loadNext`).
    /// `nil` means there is nothing below (bottom of history).
    public let bottomCursor: Cursor?

    public init(
        id: BatchID,
        items: [any ChatItem],
        topCursor: Cursor?,
        bottomCursor: Cursor?
    ) {
        self.id = id
        self.items = items
        self.topCursor = topCursor
        self.bottomCursor = bottomCursor
    }
}
