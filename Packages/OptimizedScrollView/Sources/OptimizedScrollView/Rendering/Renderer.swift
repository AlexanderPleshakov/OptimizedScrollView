import UIKit

@MainActor
final class Renderer {
    private struct VisibleCell {
        let view: UIView
        let reuseId: String
    }

    private weak var container: UIView?
    private let store: LayoutStore
    private let pool: ReusePool
    private let headersHost: UIView

    private var visibleItems: [ItemID: VisibleCell] = [:]
    private var visibleHeaders: [ItemID: VisibleCell] = [:]
    private var customResolver: ((any ChatItem) -> String)?

    /// Invoked once per item when its cell is first dequeued into the visible
    /// window. The facade routes this to `ChatScrollViewDelegate.didShowItem`.
    var onNewItemAppear: ((ItemID) -> Void)?

    /// When `true`, the renderer drives the alpha of *actively pinned* sticky
    /// headers (those whose `pinnedY > naturalY`) to 0. Headers sitting at
    /// their natural y stay fully visible. The facade flips this on/off in
    /// response to scroll-state transitions when
    /// `ChatScrollView.showsStickyHeadersOnlyWhileScrolling` is on.
    private var hidesPinnedHeader: Bool = false

    /// Ids of sticky headers whose current frame is the pinned-to-top
    /// position rather than their natural y. Recomputed inside
    /// `updateVisibleHeaders` on every viewport tick and consulted by
    /// `setHidesPinnedHeader` to know which header views to fade.
    private var pinnedHeaderIds: Set<ItemID> = []

    /// Ids of items whose cell frame intersected the actual viewport on the
    /// last `updateVisibleItems` tick. Used to fire `onItemAppear` on the
    /// transition from out-of-viewport → in-viewport (so the callback runs
    /// when the user actually *sees* the item, not when its cell is merely
    /// dequeued into the preload buffer one screen below the viewport).
    private var inViewportIds: Set<ItemID> = []
    
    /// The height of the additional render from above and below.
    ///
    /// - NOTE: if 1, then an additional height of one screen will be rendered from above and below
    var bufferScreens: CGFloat = 1.0

    init(store: LayoutStore, pool: ReusePool, container: UIView) {
        self.store = store
        self.pool = pool
        self.container = container

        // Headers live in a dedicated transparent host kept on top of items in the
        // z-order. Items are inserted *below* this host (see `addItemView`) so we
        // don't pay for `bringSubviewToFront` on every scroll tick.
        let host = UIView(frame: .zero)
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = true
        container.addSubview(host)
        self.headersHost = host
    }

    func setCustomResolver(_ resolver: ((any ChatItem) -> String)?) {
        customResolver = resolver
    }

    /// Toggles fading of the *currently pinned* sticky header. Headers whose
    /// position is their natural y (i.e. they're scrolling with the content,
    /// not stuck to the viewport top) are untouched — they stay fully
    /// visible. Driven by the facade in response to scroll-state changes
    /// when `showsStickyHeadersOnlyWhileScrolling` is on.
    func setHidesPinnedHeader(_ hide: Bool, animated: Bool) {
        guard hidesPinnedHeader != hide else { return }
        hidesPinnedHeader = hide
        let apply = { [self] in
            for (id, cell) in visibleHeaders {
                let target = targetAlpha(forHeaderId: id)
                if cell.view.alpha != target { cell.view.alpha = target }
            }
        }
        if animated {
            UIView.animate(
                withDuration: 0.2,
                delay: 0,
                options: [.beginFromCurrentState, .curveEaseInOut]
            ) {
                apply()
            }
        } else {
            apply()
        }
    }

    private func targetAlpha(forHeaderId id: ItemID) -> CGFloat {
        (hidesPinnedHeader && pinnedHeaderIds.contains(id)) ? 0 : 1
    }

    /// Returns the live cell view for `id` when the cell is currently within
    /// the preload window, otherwise `nil`. Used by the facade to satisfy
    /// `ChatScrollView.visibleView(for:)`.
    func view(for id: ItemID) -> UIView? {
        visibleItems[id]?.view
    }

    /// Synchronizes both items and (sticky) header cells against the current
    /// viewport. Items are placed in the preload window; headers are placed at
    /// their pinned y derived from the sticky math below.
    func updateVisible(
        viewport: CGRect,
        items: [ItemID: any ChatItem],
        headerProvider: ((ItemID) -> any ChatItem)?
    ) {
        guard let container else { return }
        let width = container.bounds.width
        updateVisibleItems(viewport: viewport, items: items, width: width)
        if let headerProvider {
            updateVisibleHeaders(viewport: viewport, headerProvider: headerProvider, width: width)
        } else {
            recycleAllHeaders()
        }
    }

    func reconfigureVisible(ids: Set<ItemID>, items: [ItemID: any ChatItem]) {
        for id in ids {
            guard let cell = visibleItems[id], let item = items[id] else { continue }
            pool.configure(cell.view, with: item, reuseId: cell.reuseId)
        }
    }

    func recycleRemoved(ids: Set<ItemID>) {
        for id in ids {
            guard let cell = visibleItems[id] else { continue }
            pool.enqueue(cell.view, reuseId: cell.reuseId)
            visibleItems.removeValue(forKey: id)
        }
    }

    func recycleAll() {
        for (_, cell) in visibleItems {
            pool.enqueue(cell.view, reuseId: cell.reuseId)
        }
        visibleItems.removeAll(keepingCapacity: true)
        recycleAllHeaders()
    }

    // MARK: - Items

    private func updateVisibleItems(viewport: CGRect, items: [ItemID: any ChatItem], width: CGFloat) {
        let window = ContentWindow(viewport: viewport, bufferScreens: bufferScreens)
        let attrs = store.attributes(in: window.preloadRect)
        let needed = Set(attrs.lazy.map(\.id))

        for (id, cell) in visibleItems where !needed.contains(id) {
            pool.enqueue(cell.view, reuseId: cell.reuseId)
            visibleItems.removeValue(forKey: id)
        }

        for attr in attrs {
            guard let item = items[attr.id] else { continue }
            let target = CGRect(x: 0, y: attr.frame.minY, width: width, height: attr.frame.height)
            if let cell = visibleItems[attr.id] {
                if cell.view.frame != target {
                    // Frame moves are layout, not animation. The push-flow's
                    // visual motion comes from the scroll view's bounds.origin
                    // animation (driven by `UIView.animate { contentOffset.y = ... }`
                    // in the facade); cell frames in *content* coordinates must
                    // change synchronously so they appear stationary on screen
                    // while the bounds animates. Wrapping in
                    // `performWithoutAnimation` guards against the case where
                    // this method runs inside an active CATransaction (e.g.
                    // when invoked from `scrollViewDidScroll` that fired
                    // synchronously from setting `contentOffset.y` inside the
                    // facade's `UIView.animate` block).
                    UIView.performWithoutAnimation { cell.view.frame = target }
                }
            } else {
                let reuseId = resolveReuseId(for: item)
                let view = pool.dequeue(reuseId: reuseId)
                pool.configure(view, with: item, reuseId: reuseId)
                // Place the cell directly at its target frame. The earlier
                // design used an "entry frame" at `viewport.maxY` followed by a
                // frame change to target *outside* `performWithoutAnimation`
                // to interpolate "from below" while the facade ran `apply`
                // inside `UIView.animate`. The push path no longer wraps the
                // mutation in an animation block, so the two-step is dead
                // weight — and worse, a freshly added layer occasionally
                // picks up an implicit position animation on the second
                // assignment, producing a visible slide that fights the
                // bounds animation. One synchronous placement, no animation.
                UIView.performWithoutAnimation {
                    view.frame = target
                    addItemView(view)
                }
                visibleItems[attr.id] = VisibleCell(view: view, reuseId: reuseId)
            }
        }

        // Viewport-entry detection: fire `onItemAppear` for cells that
        // transitioned from "not fully visible" to "fully visible" on this
        // tick. A cell is "fully visible" when its frame is entirely
        // contained within `viewport` — partial-overlap cells (still
        // peeking out below the viewport bottom, or up past the top) don't
        // qualify, so a small scroll that only nudges an off-screen cell a
        // few points into view does NOT trigger the callback. Hosts receive
        // a strong "user actually saw this whole cell" signal.
        //
        // Cells taller than the viewport can never be "fully inside"; that
        // edge case is accepted — chat-cell heights are bounded in practice
        // and a stricter signal is more useful to hosts than a noisier one.
        var newInViewport: Set<ItemID> = []
        for (id, cell) in visibleItems {
            let f = cell.view.frame
            if f.minY >= viewport.minY && f.maxY <= viewport.maxY {
                newInViewport.insert(id)
            }
        }
        let entered = newInViewport.subtracting(inViewportIds)
        inViewportIds = newInViewport
        if let onNewItemAppear {
            for id in entered { onNewItemAppear(id) }
        }
    }

    // MARK: - Headers

    private func updateVisibleHeaders(
        viewport: CGRect,
        headerProvider: (ItemID) -> any ChatItem,
        width: CGFloat
    ) {
        let entries = store.stickyHeaderEntries(visibleRect: viewport)
        let needed = Set(entries.lazy.map(\.attr.id))

        for (id, cell) in visibleHeaders where !needed.contains(id) {
            pool.enqueue(cell.view, reuseId: cell.reuseId)
            visibleHeaders.removeValue(forKey: id)
        }

        // Pin baseline: the top edge of the visible viewport in content coordinates.
        // The host can pad below a top safe area / nav bar by raising this value;
        // for now we use the viewport top as-is.
        let pinTop = viewport.minY

        var nextPinnedIds: Set<ItemID> = []

        for (attr, nextNaturalY) in entries {
            guard let groupId = store.headerGroupId(for: attr.id) else { continue }
            let model = headerProvider(groupId)
            let naturalY = attr.frame.minY
            let upperBound = (nextNaturalY ?? .greatestFiniteMagnitude) - attr.frame.height
            let pinnedY = max(naturalY, min(pinTop, upperBound))
            let isPinned = pinnedY > naturalY
            if isPinned { nextPinnedIds.insert(attr.id) }
            let target = CGRect(x: 0, y: pinnedY, width: width, height: attr.frame.height)
            let desiredAlpha: CGFloat = (hidesPinnedHeader && isPinned) ? 0 : 1

            if let cell = visibleHeaders[attr.id] {
                if cell.view.frame != target {
                    // Same reasoning as the item-cell move: a header frame
                    // change that happens to land inside an active CATransaction
                    // (e.g. via `scrollViewDidScroll` firing synchronously from
                    // `contentOffset.y = …` inside the facade's `UIView.animate`)
                    // would otherwise pick up an implicit position animation.
                    UIView.performWithoutAnimation { cell.view.frame = target }
                }
                // Alpha guarded: reading `.alpha` returns the model layer's
                // value, so an in-flight UIView.animate fade (initiated by
                // `setHidesPinnedHeader`) has already set the model to the
                // target; the guard prevents the per-tick re-assignment from
                // cancelling the in-flight presentation animation.
                if cell.view.alpha != desiredAlpha { cell.view.alpha = desiredAlpha }
            } else {
                let reuseId = resolveReuseId(for: model)
                let view = pool.dequeue(reuseId: reuseId)
                pool.configure(view, with: model, reuseId: reuseId)
                // First-push pathology: when a push introduces a brand-new
                // sticky group (e.g. "today" landing in a chat whose existing
                // items all belong to older days), the new header view is
                // created *inside* the facade's `UIView.animate { contentOffset.y = … }`
                // block — `scrollViewDidScroll` fires synchronously from the
                // offset assignment, this method runs, and the new header
                // becomes visible only after the offset moves back to 0.
                // Setting `view.frame = target` on a freshly-allocated layer
                // inside an active CATransaction creates an implicit position
                // animation from `(0, 0)` (presentation layer default) to the
                // target frame, producing a visible "header descends from the
                // top of the screen" slide on the first push only. Subsequent
                // pushes hit an existing header view, so the path doesn't fire.
                UIView.performWithoutAnimation {
                    view.frame = target
                    view.alpha = desiredAlpha
                    headersHost.addSubview(view)
                }
                visibleHeaders[attr.id] = VisibleCell(view: view, reuseId: reuseId)
            }
        }

        pinnedHeaderIds = nextPinnedIds
    }

    private func recycleAllHeaders() {
        for (_, cell) in visibleHeaders {
            pool.enqueue(cell.view, reuseId: cell.reuseId)
        }
        visibleHeaders.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    private func addItemView(_ view: UIView) {
        guard let container else { return }
        // headersHost stays at the top of the z-order; insert items below it so
        // headers always overlay messages.
        if headersHost.superview === container {
            container.insertSubview(view, belowSubview: headersHost)
        } else {
            container.addSubview(view)
        }
    }

    private func resolveReuseId(for item: any ChatItem) -> String {
        if let resolver = customResolver { return resolver(item) }
        if let id = pool.reuseId(for: item) { return id }
        preconditionFailure(
            "Renderer: no cell registered for \(type(of: item)) and no custom resolver set"
        )
    }
}
