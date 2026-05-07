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
}

public extension ChatScrollViewDelegate {
    func didReceiveNewItemsWhileScrolledUp(count: Int) {}
    func didFailLoad(_ error: Error) {}
}
