import UIKit

public final class ChatScrollView: UIScrollView, UIScrollViewDelegate {
    public typealias StickyHeaderProvider = @MainActor (ItemID) -> any ChatItem

    public weak var chatDelegate: ChatScrollViewDelegate?

    private let pool = ReusePool()
    private let engine = LayoutEngine(store: LayoutStore())
    private lazy var anchors = AnchorController(store: engine.store)
    private let scrollState = ScrollStateMachine()
    private lazy var renderer = Renderer(store: engine.store, pool: pool, container: self)

    private var items: [ItemID: any ChatItem] = [:]
    private var headerProvider: StickyHeaderProvider?

    private var dataSource: ChatDataSource?
    private var currentListId: BatchListID?

    private var pendingPrefetchTop: Task<Void, Never>?
    private var pendingPrefetchBottom: Task<Void, Never>?
    private var pendingJump: Task<Void, Never>?

    private var lastBoundsSize: CGSize = .zero
    private var didInitialPin = false

    public init() {
        super.init(frame: .zero)
        contentInsetAdjustmentBehavior = .never
        delegate = self
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingPrefetchTop?.cancel()
        pendingPrefetchBottom?.cancel()
        pendingJump?.cancel()
    }

    // MARK: - Registration

    public func register<Cell: ChatCellView>(_ cellType: Cell.Type) {
        pool.register(cellType)
    }

    public func setReuseIdResolver(_ resolver: ((any ChatItem) -> String)?) {
        renderer.setCustomResolver(resolver)
    }

    public func setStickyHeaderProvider(_ provider: StickyHeaderProvider?) {
        headerProvider = provider
        guard !items.isEmpty else { return }
        let capture = anchors.capture(contentOffsetY: contentOffset.y, topInset: contentInset.top)
        rebuildLayoutFromCurrentState()
        commitMutation(restoring: capture)
    }

    // MARK: - Data source

    public func setDataSourceProvider(_ provider: ChatDataSourceProvider) {
        dataSource = ChatDataSource(provider: provider)
    }

    /// Launch the initial fetch. Errors surface via
    /// `ChatScrollViewDelegate.didFailLoad`.
    public func loadInitial() {
        guard let dataSource else {
            preconditionFailure("ChatScrollView.loadInitial called before setDataSourceProvider")
        }
        Task { @MainActor [weak self] in
            do {
                let snapshot = try await dataSource.loadInitial()
                self?.applyInitialSnapshot(snapshot)
            } catch {
                self?.chatDelegate?.didFailLoad(error)
            }
        }
    }

    /// Push-style insertion at the bottom. If the user is anchored to the bottom,
    /// scrolls there with animation; otherwise fires
    /// `didReceiveNewItemsWhileScrolledUp` so the host can show a banner.
    public func appendNewItems(_ newItems: [any ChatItem]) {
        guard !newItems.isEmpty else { return }
        if let dataSource {
            Task { @MainActor [weak self] in
                guard let snapshot = await dataSource.append(items: newItems) else { return }
                self?.applyAppendedSnapshot(snapshot, addedCount: newItems.count)
            }
        } else {
            // No data source bound — fall through to a direct append.
            let wasAtBottom = isPinnedToBottom()
            let endIndex = engine.store.order.count
            apply(newItems.enumerated().map { .insert($1, at: endIndex + $0) })
            if wasAtBottom {
                scrollSyncToBottom(animated: true)
            } else {
                chatDelegate?.didReceiveNewItemsWhileScrolledUp(count: newItems.count)
            }
        }
    }

    // MARK: - Data API

    public func setItems(_ newItems: [any ChatItem]) {
        setItemsInternal(newItems, pinToBottom: true)
    }

    public func apply(_ changes: [Change]) {
        guard !changes.isEmpty else { return }

        // Fast path: when the change set is a contiguous tail-append (push,
        // `loadNext` snapshot diff), skip `DiffApplier.plan` and the full
        // `rebuildAll` and run `engine.appendItems` instead.
        if let appended = pureTailAppend(from: changes) {
            let capture = anchors.capture(contentOffsetY: contentOffset.y, topInset: contentInset.top)
            for item in appended { items[item.id] = item }
            engine.appendItems(appended, headerProvider: headerProvider)
            commitMutation(restoring: capture)
            return
        }

        // Fast path: contiguous head-prepend (`loadPrevious` snapshot diff).
        // `engine.tryPrependIncrementally` lays the new block in the
        // negative-y region (no shift of existing items) and returns false
        // when it would force renumbering of existing `#N` header ids — that
        // case falls through to the `rebuildAll` path below.
        if !engine.store.isEmpty, let prepended = pureHeadPrepend(from: changes) {
            let savedOffsetY = contentOffset.y
            let firstExistingGroup = engine.store.firstItemId.flatMap { items[$0]?.groupId }
            if engine.tryPrependIncrementally(
                prepended,
                headerProvider: headerProvider,
                firstExistingGroup: firstExistingGroup
            ) {
                for item in prepended { items[item.id] = item }
                commitPrependIncremental(savedOffsetY: savedOffsetY)
                return
            }
            // Fall through: tryPrependIncrementally bailed without mutating
            // the store, so the slow path picks up cleanly.
        }

        let capture = anchors.capture(contentOffsetY: contentOffset.y, topInset: contentInset.top)
        let plan = DiffApplier.plan(
            changes: changes,
            currentOrder: Array(engine.store.order),
            currentItems: items
        )
        items = plan.newItems
        let ordered = plan.newOrder.compactMap { items[$0] }
        engine.rebuildAll(items: ordered, headerProvider: headerProvider)
        renderer.recycleRemoved(ids: plan.removed)
        renderer.reconfigureVisible(ids: plan.modelChanged, items: items)
        commitMutation(restoring: capture)
    }

    /// Returns the new items as a contiguous tail-append, or nil if the change
    /// set isn't a pure tail append (mixed insert positions, removes, or
    /// updates make this impossible).
    private func pureTailAppend(from changes: [Change]) -> [any ChatItem]? {
        var inserts: [(at: Int, item: any ChatItem)] = []
        inserts.reserveCapacity(changes.count)
        for change in changes {
            switch change {
            case .insert(let item, let at):
                inserts.append((at, item))
            case .remove, .update:
                return nil
            }
        }
        inserts.sort { $0.at < $1.at }
        let baseIndex = engine.store.order.count
        for (offset, entry) in inserts.enumerated() {
            if entry.at != baseIndex + offset { return nil }
        }
        return inserts.map(\.item)
    }

    /// Returns the new items as a contiguous head-prepend (inserts at indices
    /// 0…K-1), or nil if the change set is anything else.
    private func pureHeadPrepend(from changes: [Change]) -> [any ChatItem]? {
        var inserts: [(at: Int, item: any ChatItem)] = []
        inserts.reserveCapacity(changes.count)
        for change in changes {
            switch change {
            case .insert(let item, let at):
                inserts.append((at, item))
            case .remove, .update:
                return nil
            }
        }
        inserts.sort { $0.at < $1.at }
        for (offset, entry) in inserts.enumerated() {
            if entry.at != offset { return nil }
        }
        return inserts.map(\.item)
    }

    /// Commit path for the incremental prepend: the existing items kept their
    /// content y values, so visual stability boils down to keeping
    /// `contentOffset.y` exactly where it was. We deliberately bypass the
    /// `AnchorController` formula here — its `(currentTopInset - captureTopInset)`
    /// term is designed for the y-shift world; with the negative-y trick
    /// the anchor item's content y did NOT change, so applying the inset
    /// delta would visually move it.
    private func commitPrependIncremental(savedOffsetY: CGFloat) {
        let newSize = CGSize(width: bounds.width, height: engine.contentHeight)
        if contentSize != newSize { contentSize = newSize }
        updateTopInsetForBottomAnchoring()
        contentOffset.y = savedOffsetY
        renderer.updateVisible(viewport: currentViewport(), items: items, headerProvider: headerProvider)
        setNeedsLayout()
    }

    public func insert(_ chatItems: [any ChatItem], at index: Int) {
        apply(chatItems.enumerated().map { .insert($1, at: index + $0) })
    }

    public func remove(ids: Set<ItemID>) {
        apply(ids.map(Change.remove))
    }

    public func updateHeight(id: ItemID, to height: CGFloat) {
        let capture = anchors.capture(contentOffsetY: contentOffset.y, topInset: contentInset.top)
        engine.updateHeight(id: id, to: height)
        commitMutation(restoring: capture)
    }

    // MARK: - Insets / scroll

    public func setBottomInset(_ inset: CGFloat, animated: Bool) {
        let wasAtBottom = isPinnedToBottom()
        let capture = anchors.capture(contentOffsetY: contentOffset.y, topInset: contentInset.top)

        let apply: () -> Void = { [self] in
            contentInset.bottom = inset
            verticalScrollIndicatorInsets.bottom = inset
            updateTopInsetForBottomAnchoring()
            if wasAtBottom {
                contentOffset.y = bottomPinnedOffsetY()
            } else if let c = capture, let y = anchors.restoredOffsetY(for: c, currentTopInset: contentInset.top) {
                contentOffset.y = y
            }
        }
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    /// Scrolls to the given item id. If the item is in the currently-loaded layout,
    /// scrolls directly. Otherwise, asks the data source for the batch containing
    /// it; if the resulting batch is adjacent to the current list it is spliced in
    /// and the scroll is animated, otherwise the layout is replaced with the new
    /// list and the offset snaps without animation.
    public func scroll(to id: ItemID, animated: Bool) {
        if engine.store.frame(for: id) != nil {
            scrollSync(to: id, animated: animated)
            return
        }
        guard let dataSource else { return }
        pendingJump?.cancel()
        pendingJump = Task { @MainActor [weak self] in
            defer { self?.pendingJump = nil }
            do {
                guard let snapshot = try await dataSource.loadBatch(containing: id) else { return }
                self?.applyJumpSnapshot(snapshot, targetId: id, requestedAnimated: animated)
            } catch {
                self?.chatDelegate?.didFailLoad(error)
            }
        }
    }

    public func scrollToBottom(animated: Bool) {
        scrollSyncToBottom(animated: animated)
    }

    /// Switches the view to the live-tail list (the one with no `bottomCursor`)
    /// and scrolls it to the very end. Used to acknowledge a "new messages"
    /// banner: takes the user from a history slice back to the conversation
    /// bottom where push messages have been accumulating. When the live tail
    /// is already the current view, this just scrolls to bottom.
    public func scrollToLiveTail(animated: Bool) {
        guard let dataSource else {
            scrollSyncToBottom(animated: animated)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await dataSource.switchToLiveTail() else {
                self.scrollSyncToBottom(animated: animated)
                return
            }
            let isSameList = (self.currentListId == snapshot.listId)
            self.currentListId = snapshot.listId
            if isSameList {
                self.applySnapshotDiff(snapshot)
                self.layoutIfNeeded()
                self.scrollSyncToBottom(animated: animated)
            } else {
                // Crossing list boundaries — the previous content has nothing
                // visually in common with the new one, so snap rather than
                // animate the offset against alien items.
                self.setItemsInternal(snapshot.items, pinToBottom: false)
                self.layoutIfNeeded()
                self.scrollSyncToBottom(animated: false)
            }
        }
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()

        let newSize = CGSize(width: bounds.width, height: engine.contentHeight)
        if contentSize != newSize { contentSize = newSize }

        let boundsChanged = bounds.size != lastBoundsSize
        let needInitialPin = !didInitialPin && !engine.store.isEmpty && bounds.height > 0

        if boundsChanged || needInitialPin {
            let prevSize = lastBoundsSize
            lastBoundsSize = bounds.size
            let wasAtBottom = prevSize.height > 0
                && contentOffset.y + prevSize.height - contentInset.bottom >= engine.contentHeight - 1
            let capture = anchors.capture(contentOffsetY: contentOffset.y, topInset: contentInset.top)
            updateTopInsetForBottomAnchoring()

            if !didInitialPin && !engine.store.isEmpty {
                contentOffset.y = bottomPinnedOffsetY()
                didInitialPin = true
            } else if wasAtBottom {
                contentOffset.y = bottomPinnedOffsetY()
            } else if let c = capture, let y = anchors.restoredOffsetY(for: c, currentTopInset: contentInset.top) {
                contentOffset.y = y
            }
        }

        renderer.updateVisible(viewport: currentViewport(), items: items, headerProvider: headerProvider)
    }

    // MARK: - UIScrollViewDelegate

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        renderer.updateVisible(viewport: currentViewport(), items: items, headerProvider: headerProvider)
        tickPrefetch()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollState.willBeginDragging()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        scrollState.didEndDragging(willDecelerate: decelerate)
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollState.didEndDecelerating()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollState.didEndProgrammaticScroll()
    }

    // MARK: - Snapshot application

    private func applyInitialSnapshot(_ snapshot: DataSnapshot) {
        currentListId = snapshot.listId
        setItemsInternal(snapshot.items, pinToBottom: true)
    }

    private func applyAppendedSnapshot(_ snapshot: DataSnapshot, addedCount: Int) {
        // The data source targets the live-tail list, regardless of which list
        // the user is currently viewing. If those happen to coincide, we apply
        // the diff and decide between scroll-to-bottom and the new-items banner;
        // otherwise the user is reading a history slice and should not have
        // their view shifted — surface only the delegate event.
        if currentListId == snapshot.listId {
            let wasAtBottom = isPinnedToBottom()
            applySnapshotDiff(snapshot)
            if wasAtBottom {
                scrollSyncToBottom(animated: true)
            } else {
                chatDelegate?.didReceiveNewItemsWhileScrolledUp(count: addedCount)
            }
        } else {
            chatDelegate?.didReceiveNewItemsWhileScrolledUp(count: addedCount)
        }
    }

    private func applyPaginationSnapshot(_ snapshot: DataSnapshot) {
        let isSameList = (currentListId == snapshot.listId)
        currentListId = snapshot.listId
        if isSameList {
            applySnapshotDiff(snapshot)
        } else {
            // Active list moved during a prefetch — replace and don't animate.
            setItemsInternal(snapshot.items, pinToBottom: false)
        }
    }

    private func applyJumpSnapshot(_ snapshot: DataSnapshot, targetId: ItemID, requestedAnimated: Bool) {
        let isSameList = (currentListId == snapshot.listId)
        currentListId = snapshot.listId
        if isSameList {
            applySnapshotDiff(snapshot)
        } else {
            // Jumping into a fresh list — there's nothing visually continuous to
            // animate against. Suppress the bottom-pin and snap to target.
            setItemsInternal(snapshot.items, pinToBottom: false)
        }
        // Force layout so frames exist for the target id we're about to scroll to.
        layoutIfNeeded()
        guard let frame = engine.store.frame(for: targetId) else { return }
        let target = max(-contentInset.top, frame.minY)
        scrollState.willBeginProgrammaticScroll()
        let animate = isSameList && requestedAnimated
        setContentOffset(CGPoint(x: 0, y: target), animated: animate)
        if !animate { scrollState.didEndProgrammaticScroll() }
    }

    private func applySnapshotDiff(_ snapshot: DataSnapshot) {
        let currentIds = Set(items.keys)
        let newIdSet = Set(snapshot.items.lazy.map(\.id))
        let removedIds = currentIds.subtracting(newIdSet)

        var changes: [Change] = []
        changes.append(contentsOf: removedIds.map(Change.remove))
        for (idx, item) in snapshot.items.enumerated() where !currentIds.contains(item.id) {
            changes.append(.insert(item, at: idx))
        }
        for item in snapshot.items {
            if let existing = items[item.id], existing.height != item.height {
                changes.append(.update(item))
            }
        }
        if !changes.isEmpty { apply(changes) }
    }

    // MARK: - Internals

    private func setItemsInternal(_ newItems: [any ChatItem], pinToBottom: Bool) {
        renderer.recycleAll()
        items = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
        engine.rebuildAll(items: newItems, headerProvider: headerProvider)
        // `rebuildAll` resets `topY` to 0 — the new layout has no
        // negative-y prepended region. We MUST sync `contentInset.top` to
        // reflect this immediately. Otherwise the inset stays at the previous
        // list's `prependHeadroom`; the next mutation that runs through
        // `commitMutation` (e.g. an `appendItems` after the user scrolls)
        // would see a stale `capture.topInset`, and the anchor's
        // `(currentTopInset - capture.topInset)` term would visually jump
        // the viewport by the leftover prepend headroom.
        updateTopInsetForBottomAnchoring()
        // pinToBottom == true -> arm initial bottom-pin in the next layout pass.
        // pinToBottom == false -> caller will scroll to a specific target itself.
        didInitialPin = !pinToBottom
        setNeedsLayout()
    }

    private func rebuildLayoutFromCurrentState() {
        let ordered = engine.store.order.compactMap { items[$0] }
        engine.rebuildAll(items: ordered, headerProvider: headerProvider)
    }

    private func commitMutation(restoring capture: AnchorController.Capture?) {
        updateTopInsetForBottomAnchoring()
        let newSize = CGSize(width: bounds.width, height: engine.contentHeight)
        if contentSize != newSize { contentSize = newSize }
        if let c = capture, let y = anchors.restoredOffsetY(for: c, currentTopInset: contentInset.top) {
            contentOffset.y = y
        }
        renderer.updateVisible(viewport: currentViewport(), items: items, headerProvider: headerProvider)
        setNeedsLayout()
    }

    private func tickPrefetch() {
        guard let dataSource else { return }
        let viewport = currentViewport()
        let threshold = viewport.height
        // Compare the viewport top to the *current* layout top (`engine.topY`),
        // not to a fixed 0. After any incremental prepend the layout extends
        // into the negative-y region; a `viewport.minY <= threshold` against 0
        // would be true on every scroll tick once `topY` has gone below
        // `-threshold`, kicking off a runaway loadPrevious chain.
        let nearTop = viewport.minY - engine.topY <= threshold
        let nearBottom = viewport.maxY >= engine.contentHeight - threshold

        if nearTop, pendingPrefetchTop == nil {
            pendingPrefetchTop = Task { @MainActor [weak self] in
                defer { self?.pendingPrefetchTop = nil }
                do {
                    if let snapshot = try await dataSource.loadPrevious() {
                        self?.applyPaginationSnapshot(snapshot)
                    }
                } catch {
                    self?.chatDelegate?.didFailLoad(error)
                }
            }
        }
        if nearBottom, pendingPrefetchBottom == nil {
            pendingPrefetchBottom = Task { @MainActor [weak self] in
                defer { self?.pendingPrefetchBottom = nil }
                do {
                    if let snapshot = try await dataSource.loadNext() {
                        self?.applyPaginationSnapshot(snapshot)
                    }
                } catch {
                    self?.chatDelegate?.didFailLoad(error)
                }
            }
        }
    }

    private func currentViewport() -> CGRect {
        CGRect(x: 0, y: contentOffset.y, width: bounds.width, height: bounds.height)
    }

    private func scrollSync(to id: ItemID, animated: Bool) {
        guard let frame = engine.store.frame(for: id) else { return }
        let target = max(-contentInset.top, frame.minY)
        scrollState.willBeginProgrammaticScroll()
        setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        if !animated { scrollState.didEndProgrammaticScroll() }
    }

    private func scrollSyncToBottom(animated: Bool) {
        let target = bottomPinnedOffsetY()
        scrollState.willBeginProgrammaticScroll()
        setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        if !animated { scrollState.didEndProgrammaticScroll() }
    }

    private func updateTopInsetForBottomAnchoring() {
        let viewportBelowTop = bounds.height - contentInset.bottom
        // Bottom-anchoring uses the *full* scrollable extent — including any
        // negative-y prepended region — so a layout that's gone past viewport
        // height through prepends doesn't keep getting padded at the top.
        let bottomAnchorInset = BottomAnchoring.topInset(
            contentHeight: engine.totalScrollableHeight,
            viewportHeight: viewportBelowTop
        )
        // Prepend headroom: extra room above contentSize (which starts at y=0)
        // so the user can scroll up into the negative-y region where prepended
        // history lives. `engine.topY` is ≤ 0 once any prepend has happened.
        let prependHeadroom = max(0, -engine.topY)
        let target = bottomAnchorInset + prependHeadroom
        if contentInset.top != target { contentInset.top = target }
    }

    private func bottomPinnedOffsetY() -> CGFloat {
        let viewportBelowTop = bounds.height - contentInset.bottom
        return BottomAnchoring.bottomPinnedOffsetY(
            contentHeight: engine.contentHeight,
            viewportHeight: viewportBelowTop,
            topInset: contentInset.top
        )
    }

    private func isPinnedToBottom(epsilon: CGFloat = 0.5) -> Bool {
        let viewportBottom = contentOffset.y + bounds.height - contentInset.bottom
        return viewportBottom >= engine.contentHeight - epsilon
    }
}
