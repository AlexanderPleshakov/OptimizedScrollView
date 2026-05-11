@MainActor
public protocol ChatScrollViewDelegate: AnyObject {
    /// Fired when items arrive at the bottom (typically via `appendNewItems`)
    /// while the user is scrolled away from the bottom. Hosts usually surface
    /// a "new messages" banner; tapping it should call `scroll(to:animated:)`
    /// or `scrollToBottom`.
    func didReceiveNewItemsWhileScrolledUp(count: Int)

    /// Fired when an asynchronous load (`loadInitial`, prefetch, or jump-to-id)
    /// throws.
    func didFailLoad(_ error: Error)

    /// Fired when a `scroll(to:animated:)` request has finished settling the
    /// target item into the viewport. For non-animated requests this fires
    /// synchronously at the end of `scroll(to:animated:)`; for animated
    /// requests it fires when the scroll animation completes. Hosts typically
    /// use this to flash a highlight on the target row.
    func didScrollToItem(id: ItemID)

    /// Fired the first time an item pushed via `appendNewItems` becomes
    /// fully visible inside the viewport (the cell's frame is entirely
    /// contained in the visible bounds — not merely intersecting the edge).
    /// Items that were part of the initial load, paginated history, or
    /// loaded via a jump are NOT tracked: the renderer's underlying
    /// viewport-entry signal is filtered through a set of "pending"
    /// pushed ids so the host receives a clean "the user has now seen
    /// the message I pushed" event. Hosts use this to mark messages as
    /// read and decrement an unread-counter badge.
    func didShowItem(id: ItemID)
}

public extension ChatScrollViewDelegate {
    func didReceiveNewItemsWhileScrolledUp(count: Int) {}
    func didFailLoad(_ error: Error) {}
    func didScrollToItem(id: ItemID) {}
    func didShowItem(id: ItemID) {}
}
