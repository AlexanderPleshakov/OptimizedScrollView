import Foundation

public struct BatchListID: Hashable, Sendable {
    public let raw: String
    public init() { self.raw = UUID().uuidString }
    public init(raw: String) { self.raw = raw }
}

/// Immutable snapshot of the currently-active `BatchList`. Returned by
/// `ChatDataSource` calls and consumed on the main actor by `ChatScrollView`.
public struct DataSnapshot: Sendable {
    public let listId: BatchListID
    public let items: [any ChatItem]
    public let topCursor: Cursor?
    public let bottomCursor: Cursor?

    public var canLoadPrevious: Bool { topCursor != nil }
    public var canLoadNext: Bool { bottomCursor != nil }

    public init(
        listId: BatchListID,
        items: [any ChatItem],
        topCursor: Cursor?,
        bottomCursor: Cursor?
    ) {
        self.listId = listId
        self.items = items
        self.topCursor = topCursor
        self.bottomCursor = bottomCursor
    }
}
