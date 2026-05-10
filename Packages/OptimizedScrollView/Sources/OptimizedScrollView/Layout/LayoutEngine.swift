import CoreGraphics

@MainActor
final class LayoutEngine {
    let store: LayoutStore

    /// Tracks how many times each `groupId` has been used to mint a header
    /// layout id. The same `groupId` can legitimately reappear non-adjacently
    /// (e.g. a server-pushed "today" message lands inside a history slice and
    /// a later loadNext fills the gap). The first occurrence keeps the host's
    /// `header.id` verbatim; later occurrences are suffixed with `#N`.
    /// Maintained by both `rebuildAll` (reset + re-counted) and `appendItems`
    /// (incremented as new headers are emitted).
    private var occurrenceByGroup: [ItemID: Int] = [:]

    /// `groupId` of the last item currently in the store. Used as the seam
    /// `prevGroup` when `appendItems` runs.
    private var lastItemGroupId: ItemID? = nil

    /// Latest viewport height seen via `setViewportHeight`. Drives
    /// `reconcileBottomFlow` — the routine that bottom-pins short content
    /// by shifting all stored frames downward (Approach B). Mutations
    /// (`rebuildAll`, `appendItems`, `tryPrependIncrementally`,
    /// `updateHeight`) reconcile against this value at their tail so the
    /// store is always in a viewport-consistent state.
    private var viewportHeight: CGFloat = 0

    init(store: LayoutStore) {
        self.store = store
    }

    var contentHeight: CGFloat { store.contentHeight }
    var topY: CGFloat { store.topY }
    var bottomFlowOffset: CGFloat { store.bottomFlowOffset }
    var totalScrollableHeight: CGFloat { store.totalScrollableHeight }

    /// Inform the engine of the current viewport height (`bounds.height -
    /// contentInset.bottom`). Triggers `reconcileBottomFlow`, which keeps
    /// the layout's `bottomFlowOffset` aligned with the viewport: a layout
    /// shorter than the viewport is shifted so the last item's `maxY`
    /// equals `viewportHeight` (bottom-pin via stored frames); a layout
    /// at-or-larger has its flow offset collapsed to 0.
    @discardableResult
    func setViewportHeight(_ newHeight: CGFloat) -> CGFloat {
        viewportHeight = newHeight
        return reconcileBottomFlow()
    }

    /// Compute and apply the desired `bottomFlowOffset` for the current
    /// `viewportHeight` and content extent. Returns the y-shift applied
    /// (0 when nothing changed). The caller can use the return value to
    /// decide whether to animate the resulting frame movement.
    @discardableResult
    private func reconcileBottomFlow() -> CGFloat {
        guard !store.isEmpty else { return 0 }
        // `itemsTotal` is the raw vertical extent of the laid-out content
        // (independent of where the topmost subview happens to sit).
        let itemsTotal = store.contentHeight - store.topY
        // `desiredOffset` > 0 only when items are shorter than the viewport;
        // then we want to shift the whole layout down so the last item sits
        // at `viewport`. When negative-y prepend has put `topY` below 0 the
        // content already exceeds the viewport — `desiredOffset` collapses
        // to 0 and we leave the prepended region alone (`max(0, topY)` is 0
        // in that branch, so `shift` is 0 too).
        let desiredOffset = max(0, viewportHeight - itemsTotal)
        let currentOffset = max(0, store.topY)
        let shift = desiredOffset - currentOffset
        if shift != 0 { store.shiftAllFrames(delta: shift) }
        return shift
    }

    /// Full rebuild — items y-flow with displacing headers between groups. A header
    /// is inserted above the first item of each group (any item whose `groupId`
    /// differs from the previous item's `groupId`, including nil→non-nil transitions).
    /// Items inside a group are pushed down by the header's height.
    /// Used for initial load and after any structural mutation that isn't a
    /// pure tail append.
    func rebuildAll(
        items: [any ChatItem],
        headerProvider: ((ItemID) -> any ChatItem)?
    ) {
        var itemAttrs: [LayoutAttributes] = []
        itemAttrs.reserveCapacity(items.count)
        var headerOrder: [ItemID] = []
        var headerAttrs: [LayoutAttributes] = []
        var headerGroupIds: [ItemID: ItemID] = [:]
        var occurrence: [ItemID: Int] = [:]

        var y: CGFloat = 0
        var prevGroup: ItemID? = nil

        for item in items {
            let group = item.groupId
            if let group, group != prevGroup, let provider = headerProvider {
                let header = provider(group)
                let n = occurrence[group, default: 0]
                occurrence[group] = n + 1
                let layoutId: ItemID = n == 0
                    ? header.id
                    : ItemID("\(header.id.raw)#\(n)")
                headerOrder.append(layoutId)
                headerAttrs.append(LayoutAttributes(
                    id: layoutId,
                    frame: CGRect(x: 0, y: y, width: 0, height: header.height)
                ))
                headerGroupIds[layoutId] = group
                y += header.height
            }
            prevGroup = group

            itemAttrs.append(LayoutAttributes(
                id: item.id,
                frame: CGRect(x: 0, y: y, width: 0, height: item.height)
            ))
            y += item.height
        }

        store.replaceAll(
            order: items.map(\.id),
            attributes: itemAttrs,
            headerOrder: headerOrder,
            headerAttributes: headerAttrs,
            headerGroupIds: headerGroupIds
        )

        occurrenceByGroup = occurrence
        lastItemGroupId = prevGroup

        // Bake the bottom-flow offset back in. `replaceAll` resets `topY` to
        // 0 and lays items from y=0; in short-content mode that would put
        // them at the top of the viewport instead of pinned at the bottom.
        reconcileBottomFlow()
    }

    /// Incremental tail-append. Called when the diff is a pure growth at the
    /// bottom — `loadNext`, push. Lays out only the new items + any seam header
    /// (when `newItems.first.groupId` differs from the last existing item's
    /// group), then reuses the existing layout untouched. Cost: O(newItems).
    /// The big win over `rebuildAll` is skipping a full `Dictionary` rebuild
    /// of the store's `indexById` / `headerIndexById` on every prefetch.
    func appendItems(
        _ newItems: [any ChatItem],
        headerProvider: ((ItemID) -> any ChatItem)?
    ) {
        guard !newItems.isEmpty else { return }

        var newItemAttrs: [LayoutAttributes] = []
        newItemAttrs.reserveCapacity(newItems.count)
        var newHeaderAttrs: [LayoutAttributes] = []
        var newHeaderGroups: [ItemID: ItemID] = [:]

        var y: CGFloat = store.contentHeight
        var prevGroup: ItemID? = lastItemGroupId

        for item in newItems {
            let group = item.groupId
            if let group, group != prevGroup, let provider = headerProvider {
                let header = provider(group)
                let n = occurrenceByGroup[group, default: 0]
                occurrenceByGroup[group] = n + 1
                let layoutId: ItemID = n == 0
                    ? header.id
                    : ItemID("\(header.id.raw)#\(n)")
                newHeaderAttrs.append(LayoutAttributes(
                    id: layoutId,
                    frame: CGRect(x: 0, y: y, width: 0, height: header.height)
                ))
                newHeaderGroups[layoutId] = group
                y += header.height
            }
            prevGroup = group

            newItemAttrs.append(LayoutAttributes(
                id: item.id,
                frame: CGRect(x: 0, y: y, width: 0, height: item.height)
            ))
            y += item.height
        }

        store.appendItems(
            attributes: newItemAttrs,
            headerAttributes: newHeaderAttrs,
            headerGroupIds: newHeaderGroups,
            newContentHeight: y
        )
        lastItemGroupId = prevGroup

        // In short-content mode, growth here may push past the viewport;
        // reconcile shifts the whole layout up by `oldOffset` so the
        // appended item lands exactly at the viewport bottom.
        reconcileBottomFlow()
    }

    /// Patch path — used when only one item's height changed and no group structure
    /// is affected. Shifts items and headers below by the delta. For anything that
    /// might cross a group boundary, callers should go through `rebuildAll`.
    @discardableResult
    func updateHeight(id: ItemID, to height: CGFloat) -> LayoutDiff {
        guard let i = store.index(of: id) else { return .empty }
        let delta = store.updateHeight(at: i, height: height)
        // A height change can flip short↔long mode (e.g. shrinking the only
        // tall item); reconcile keeps the bottom-flow offset in sync.
        reconcileBottomFlow()
        return LayoutDiff(changed: [id], contentSizeDelta: delta)
    }

    /// Incremental head-prepend (`loadPrevious`). Returns `true` on success;
    /// `false` if the block would force renumbering of existing `#N` header
    /// ids — in which case the caller falls back to `rebuildAll`.
    ///
    /// The "safe" path covers the typical history-paging case: prepended
    /// pages introduce older `groupId`s that aren't in the existing layout,
    /// possibly with the seam group continuing from the new block's last
    /// item into the first existing item. The bad case is when a prepended
    /// page contains a group that already has occurrences in the existing
    /// layout (other than at the seam) — both sides would mint
    /// `header.id` (occurrence #0) and collide. We refuse those cleanly.
    @discardableResult
    func tryPrependIncrementally(
        _ newItems: [any ChatItem],
        headerProvider: ((ItemID) -> any ChatItem)?,
        firstExistingGroup: ItemID?
    ) -> Bool {
        guard !newItems.isEmpty else { return true }
        // Empty store has no "first existing item" to seam with — incremental
        // doesn't apply, fall back to rebuildAll which lays from y=0.
        guard !store.isEmpty else { return false }

        // 1) Lay out the block alone, starting at block-local y=0. Header ids
        //    use *block-local* occurrence counts (`#N` based on what we've
        //    seen INSIDE the block so far). The store's translation will
        //    move the whole block into the negative-y region.
        var blockItemAttrs: [LayoutAttributes] = []
        blockItemAttrs.reserveCapacity(newItems.count)
        var blockHeaderAttrs: [LayoutAttributes] = []
        var blockHeaderGroups: [ItemID: ItemID] = [:]
        var blockOccurrence: [ItemID: Int] = [:]

        var y: CGFloat = 0
        var prevGroup: ItemID? = nil

        for item in newItems {
            let group = item.groupId
            if let group, group != prevGroup, let provider = headerProvider {
                let header = provider(group)
                let n = blockOccurrence[group, default: 0]
                blockOccurrence[group] = n + 1
                let layoutId: ItemID = n == 0
                    ? header.id
                    : ItemID("\(header.id.raw)#\(n)")
                blockHeaderAttrs.append(LayoutAttributes(
                    id: layoutId,
                    frame: CGRect(x: 0, y: y, width: 0, height: header.height)
                ))
                blockHeaderGroups[layoutId] = group
                y += header.height
            }
            prevGroup = group

            blockItemAttrs.append(LayoutAttributes(
                id: item.id,
                frame: CGRect(x: 0, y: y, width: 0, height: item.height)
            ))
            y += item.height
        }
        let blockHeight = y

        // 2) Seam: last new group matches first existing group AND there is
        //    a leading existing header to drop. The dropped header's id is
        //    the same as the new block's last header id (both `header.id`
        //    occurrence #0 of `seamGroup`), so dropping the existing one
        //    keeps the layout-id space conflict-free.
        let lastNewGroup = newItems.last?.groupId
        let seamMatches = lastNewGroup != nil && lastNewGroup == firstExistingGroup
        let seamCanDrop = seamMatches
            && (store.firstHeaderAttributes?.frame.minY == store.topY)

        // 3) Conflict check. For every group introduced by the block, if it
        //    already has occurrences in the existing layout, we'd need to
        //    renumber them — refuse that case.
        for (group, blockCount) in blockOccurrence {
            let existingCount = occurrenceByGroup[group, default: 0]
            guard existingCount > 0 else { continue }
            // Seam-safe sub-case: exactly one occurrence in the block,
            // and it's the seam group.
            if seamCanDrop, group == lastNewGroup, blockCount == 1 {
                continue
            }
            return false
        }

        // 4) Drop the redundant existing leading header in the seam case.
        if seamCanDrop {
            store.dropFirstHeader()
        }

        // 5) Splice the block into the negative-y region.
        store.prependItems(
            blockAttributes: blockItemAttrs,
            blockHeaderAttributes: blockHeaderAttrs,
            headerGroupIds: blockHeaderGroups,
            blockHeight: blockHeight
        )

        // 6) Update engine state.
        // - For the seam group (if any): we dropped existing #0 and added a
        //   new #0 of the same id, so the total count is unchanged.
        // - For every other group introduced by the block: existing count
        //   was 0 (verified above), so the new count is +blockCount.
        for (group, blockCount) in blockOccurrence {
            if seamCanDrop, group == lastNewGroup {
                continue
            }
            occurrenceByGroup[group, default: 0] += blockCount
        }
        // `lastItemGroupId` is unchanged — the last item is still whichever
        // existing item was at the bottom before this prepend.

        // Reconcile is a no-op in pure long-content prepend (currentOffset
        // stays 0, desiredOffset stays 0). In short-content prepend that
        // doesn't yet exceed the viewport, `topY` after `prependItems`
        // already equals the new desired offset (block was placed at
        // `[topY-blockHeight, topY]`, so `currentOffset == desiredOffset`).
        // In a short→long crossing prepend, the block went into negative-y;
        // again `currentOffset` is 0 (`topY` is now negative). So the call
        // is defensive — kept for symmetry and future-proofing.
        reconcileBottomFlow()

        return true
    }
}
