import CoreGraphics
import DequeModule

@MainActor
final class LayoutStore {
    /// Items and headers are kept in `Deque`s rather than `Array`s so prepend
    /// (the `loadPrevious` path) is amortized O(1) at the storage layer.
    /// Both still index by `Int`, so everything that walks them — the binary
    /// search, `attributes(in:)`, header sticky math — stays unchanged.
    private(set) var order: Deque<ItemID> = []
    private var indexById: [ItemID: Int] = [:]
    private var attrs: Deque<LayoutAttributes> = []
    private(set) var contentHeight: CGFloat = 0

    private(set) var headerOrder: Deque<ItemID> = []
    private var headerIndexById: [ItemID: Int] = [:]
    private var headerAttrs: Deque<LayoutAttributes> = []
    private var headerGroupIds: [ItemID: ItemID] = [:]

    /// y-coordinate of the topmost subview (item or header) in the layout.
    ///
    /// - `topY == 0` — long content laid out directly from y=0. The default
    ///   after `replaceAll`.
    /// - `topY < 0` — long content with prepended history. The negative-y
    ///   region holds older items; existing items keep their stored y values.
    ///   The facade exposes the region by adding `-topY` to `contentInset.top`.
    /// - `topY > 0` — short content (items shorter than the viewport) shifted
    ///   downward by `LayoutEngine.setViewportHeight` so the last item's
    ///   `maxY == viewportHeight` (Approach-B bottom-pin via stored frames,
    ///   not via `contentInset.top`).
    private(set) var topY: CGFloat = 0

    /// The y-shift currently baked into stored frames to bottom-pin short
    /// content. Equals `topY` when positive, 0 otherwise. Cross-mode prepend
    /// (short→long) collapses this back to 0; subsequent reconcile
    /// is then a no-op.
    var bottomFlowOffset: CGFloat { max(0, topY) }

    /// Full vertical extent of the laid-out content (negative-y prepended
    /// region plus the positive-y region). Used by callers that need to know
    /// the whole reachable scroll extent regardless of where the topmost
    /// subview happens to sit.
    var totalScrollableHeight: CGFloat { contentHeight - min(0, topY) }

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }

    func index(of id: ItemID) -> Int? { indexById[id] }
    func attributes(at index: Int) -> LayoutAttributes { attrs[index] }
    func attributes(for id: ItemID) -> LayoutAttributes? {
        indexById[id].map { attrs[$0] }
    }
    func frame(for id: ItemID) -> CGRect? { attributes(for: id)?.frame }
    func allAttributes() -> [LayoutAttributes] { Array(attrs) }

    /// First item index whose frame.maxY is strictly greater than y.
    func firstIndex(intersecting y: CGFloat) -> Int {
        var lo = 0, hi = attrs.count
        while lo < hi {
            let mid = (lo &+ hi) >> 1
            if attrs[mid].frame.maxY <= y {
                lo = mid &+ 1
            } else {
                hi = mid
            }
        }
        return lo
    }

    /// Item attributes whose frames intersect rect along Y. O(visible).
    func attributes(in rect: CGRect) -> [LayoutAttributes] {
        guard !attrs.isEmpty else { return [] }
        var out: [LayoutAttributes] = []
        var i = firstIndex(intersecting: rect.minY)
        while i < attrs.count, attrs[i].frame.minY < rect.maxY {
            out.append(attrs[i])
            i &+= 1
        }
        return out
    }

    // MARK: - Headers

    func headerAttributes(for id: ItemID) -> LayoutAttributes? {
        headerIndexById[id].map { headerAttrs[$0] }
    }

    func headerGroupId(for headerId: ItemID) -> ItemID? {
        headerGroupIds[headerId]
    }

    /// Returns the headers whose sticky range overlaps `visibleRect` along Y, paired
    /// with the next header's natural y (used as the upper bound when pinning).
    /// A header's sticky range is `[naturalY, nextHeaderNaturalY)` — for the last
    /// header it extends to `+infinity`, but bounded for math by `contentHeight`.
    func stickyHeaderEntries(visibleRect: CGRect) -> [(attr: LayoutAttributes, nextNaturalY: CGFloat?)] {
        guard !headerAttrs.isEmpty else { return [] }
        var out: [(LayoutAttributes, CGFloat?)] = []
        for k in headerAttrs.indices {
            let cur = headerAttrs[k]
            let nextY: CGFloat? = k + 1 < headerAttrs.count
                ? headerAttrs[k + 1].frame.minY
                : nil
            let activeMinY = cur.frame.minY
            let activeMaxY = nextY ?? .greatestFiniteMagnitude
            if activeMinY < visibleRect.maxY && activeMaxY > visibleRect.minY {
                out.append((cur, nextY))
            }
        }
        return out
    }

    /// First/last item ids — used by callers that need to inspect the boundary
    /// of the laid-out range without poking the deque directly.
    var firstItemId: ItemID? { order.first }
    var lastItemId: ItemID? { order.last }

    /// First/last header attributes — used by the engine when computing the
    /// seam between an existing layout and a prepended/appended block.
    var firstHeaderAttributes: LayoutAttributes? { headerAttrs.first }
    var lastHeaderAttributes: LayoutAttributes? { headerAttrs.last }

    // MARK: - Mutations

    func replaceAll(
        order: [ItemID],
        attributes: [LayoutAttributes],
        headerOrder: [ItemID] = [],
        headerAttributes: [LayoutAttributes] = [],
        headerGroupIds: [ItemID: ItemID] = [:]
    ) {
        precondition(order.count == attributes.count)
        precondition(headerOrder.count == headerAttributes.count)
        self.order = Deque(order)
        self.attrs = Deque(attributes)
        self.indexById = .init(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        self.headerOrder = Deque(headerOrder)
        self.headerAttrs = Deque(headerAttributes)
        self.headerIndexById = .init(uniqueKeysWithValues: headerOrder.enumerated().map { ($1, $0) })
        self.headerGroupIds = headerGroupIds

        let lastItemY = attributes.last?.frame.maxY ?? 0
        let lastHeaderY = headerAttributes.last?.frame.maxY ?? 0
        self.contentHeight = max(lastItemY, lastHeaderY)
        // rebuildAll always lays out from y=0, so the topmost subview sits at 0.
        self.topY = 0

        print("replaceAll \(attributes.count)")
    }

    /// Patches a single item's height and shifts everything below — both items and
    /// headers — by the resulting delta. Group structure is unchanged.
    func updateHeight(at index: Int, height: CGFloat) -> CGFloat {
        let oldHeight = attrs[index].frame.height
        let oldMaxY = attrs[index].frame.maxY
        let delta = height - oldHeight
        attrs[index].frame.size.height = height
        if delta != 0 {
            for i in (index + 1)..<attrs.count {
                attrs[i].frame.origin.y += delta
            }
            for i in 0..<headerAttrs.count where headerAttrs[i].frame.minY >= oldMaxY {
                headerAttrs[i].frame.origin.y += delta
            }
            contentHeight += delta
        }
        return delta
    }

    // MARK: - Incremental: append at the bottom
    
    /// Add items in the start of list.
    ///
    /// Used when the diff is a pure tail growth — `loadNext`, push. Item attrs
    /// arrive with absolute y already laid out from the previous `contentHeight`.
    /// Headers ditto. `indexById` / `headerIndexById` get keys appended without
    /// touching existing entries. Cost: O(new items + new headers) — no full
    /// rebuild of either index dictionary.
    ///
    /// - Complexity: O(*m*), where *m* is the count of `attributes + headerAttributes` items.
    func appendItems(
        attributes newAttrs: [LayoutAttributes],
        headerAttributes newHeaders: [LayoutAttributes] = [],
        headerGroupIds newHeaderGroups: [ItemID: ItemID] = [:],
        newContentHeight: CGFloat
    ) {
        let baseItemIndex = order.count
        for (offset, attr) in newAttrs.enumerated() {
            order.append(attr.id)
            attrs.append(attr)
            indexById[attr.id] = baseItemIndex + offset
        }
        let baseHeaderIndex = headerOrder.count
        for (offset, header) in newHeaders.enumerated() {
            headerOrder.append(header.id)
            headerAttrs.append(header)
            headerIndexById[header.id] = baseHeaderIndex + offset
        }
        for (k, v) in newHeaderGroups { headerGroupIds[k] = v }
        contentHeight = newContentHeight

        print("appendItems \(newAttrs.count)")
    }

    // MARK: - Incremental: prepend at the top
    
    /// Add items in the end of list
    ///
    /// The existing items keep their stored y values untouched. New items go
    /// into the negative-y region: their block-local y in [0, blockHeight] is
    /// translated by `topY - blockHeight` so the block's bottom (y=blockHeight)
    /// sits exactly at the current `topY`. After prepend, `topY -= blockHeight`.
    ///
    /// The facade adds `max(0, -topY)` to `contentInset.top` so the negative
    /// region is reachable by scrolling up.
    ///
    /// - Complexity: O(*m*), where *m* is the count of `blockAttributes + blockHeaderAttributes` items.
    func prependItems(
        blockAttributes blockAttrs: [LayoutAttributes],
        blockHeaderAttributes blockHeaders: [LayoutAttributes] = [],
        headerGroupIds newHeaderGroups: [ItemID: ItemID] = [:],
        blockHeight: CGFloat
    ) {
        let itemCount = blockAttrs.count
        let headerCount = blockHeaders.count
        let yShift = topY - blockHeight

        // Bump existing index-dict values; we don't touch the existing y values.
        if itemCount > 0 {
            for key in indexById.keys { indexById[key]! += itemCount }
        }
        if headerCount > 0 {
            for key in headerIndexById.keys { headerIndexById[key]! += headerCount }
        }

        // Translate the block from its block-local y=[0, blockHeight] to
        // absolute y=[topY-blockHeight, topY], then prepend.
        var translatedItems = blockAttrs
        for i in translatedItems.indices { translatedItems[i].frame.origin.y += yShift }
        var translatedHeaders = blockHeaders
        for i in translatedHeaders.indices { translatedHeaders[i].frame.origin.y += yShift }

        order.prepend(contentsOf: translatedItems.lazy.map(\.id))
        attrs.prepend(contentsOf: translatedItems)
        for (offset, attr) in translatedItems.enumerated() {
            indexById[attr.id] = offset
        }

        headerOrder.prepend(contentsOf: translatedHeaders.lazy.map(\.id))
        headerAttrs.prepend(contentsOf: translatedHeaders)
        for (offset, header) in translatedHeaders.enumerated() {
            headerIndexById[header.id] = offset
        }
        for (k, v) in newHeaderGroups { headerGroupIds[k] = v }

        topY -= blockHeight
        // contentHeight is unchanged: the block sits above the existing
        // content; nothing was added below.

        print("prependItems(negative-y) \(blockAttrs.count) topY=\(topY)")
    }

    // MARK: - Incremental: viewport-driven bottom-flow shift

    /// Translates every stored frame (items + headers) along the y-axis by
    /// `delta`, adjusting `topY` and `contentHeight` to match. Used by the
    /// engine to apply a `bottomFlowOffset` change after rebuild/append in
    /// short-content mode and on viewport size changes.
    ///
    /// - Complexity: O(items + headers).
    func shiftAllFrames(delta: CGFloat) {
        guard delta != 0, !isEmpty else { return }
        for i in attrs.indices {
            attrs[i].frame.origin.y += delta
        }
        for i in headerAttrs.indices {
            headerAttrs[i].frame.origin.y += delta
        }
        topY += delta
        contentHeight += delta
    }

    /// Removes the topmost header. Used by the engine in the seam case
    /// (last prepended item shares its group with the first existing item) —
    /// the existing leading header is now redundant and would collide with
    /// the new block's leading header. Recomputes `topY`.
    func dropFirstHeader() {
        guard !headerOrder.isEmpty else { return }
        let removedId = headerOrder.removeFirst()
        headerAttrs.removeFirst()
        headerIndexById.removeValue(forKey: removedId)
        headerGroupIds.removeValue(forKey: removedId)
        for key in headerIndexById.keys { headerIndexById[key]! -= 1 }
        recomputeTopY()

        print("dropFirstHeader -> topY=\(topY)")
    }

    private func recomputeTopY() {
        let firstItemY = attrs.first?.frame.minY
        let firstHeaderY = headerAttrs.first?.frame.minY
        switch (firstItemY, firstHeaderY) {
        case let (i?, h?): topY = min(i, h)
        case let (i?, nil): topY = i
        case let (nil, h?): topY = h
        case (nil, nil): topY = 0
        }
    }
}
