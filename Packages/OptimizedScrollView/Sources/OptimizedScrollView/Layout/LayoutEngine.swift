import CoreGraphics

@MainActor
final class LayoutEngine {
    let store: LayoutStore

    init(store: LayoutStore) {
        self.store = store
    }

    var contentHeight: CGFloat { store.contentHeight }

    /// Full rebuild — items y-flow with displacing headers between groups. A header
    /// is inserted above the first item of each group (any item whose `groupId`
    /// differs from the previous item's `groupId`, including nil→non-nil transitions).
    /// Items inside a group are pushed down by the header's height.
    /// Used for initial load and after any structural mutation.
    func rebuildAll(
        items: [any ChatItem],
        headerProvider: ((ItemID) -> any ChatItem)?
    ) {
        var itemAttrs: [LayoutAttributes] = []
        itemAttrs.reserveCapacity(items.count)
        var headerOrder: [ItemID] = []
        var headerAttrs: [LayoutAttributes] = []
        var headerGroupIds: [ItemID: ItemID] = [:]
        var occurrenceByGroup: [ItemID: Int] = [:]

        var y: CGFloat = 0
        var prevGroup: ItemID? = nil

        for item in items {
            let group = item.groupId
            if let group, group != prevGroup, let provider = headerProvider {
                let header = provider(group)
                // The same groupId can legitimately reappear non-adjacently — for
                // example when a server-pushed "today" message lands inside a
                // currently-loaded history slice and a subsequent loadNext fills
                // in the gap behind it. The host's `header.id` is then ambiguous,
                // so the layout disambiguates by suffixing later occurrences with
                // `#N`. The first occurrence keeps the host id verbatim, which
                // covers the overwhelming common case (one occurrence per group).
                let occurrence = occurrenceByGroup[group, default: 0]
                occurrenceByGroup[group] = occurrence + 1
                let layoutId: ItemID = occurrence == 0
                    ? header.id
                    : ItemID("\(header.id.raw)#\(occurrence)")
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
    }

    /// Patch path — used when only one item's height changed and no group structure
    /// is affected. Shifts items and headers below by the delta. For anything that
    /// might cross a group boundary, callers should go through `rebuildAll`.
    @discardableResult
    func updateHeight(id: ItemID, to height: CGFloat) -> LayoutDiff {
        guard let i = store.index(of: id) else { return .empty }
        let delta = store.updateHeight(at: i, height: height)
        return LayoutDiff(changed: [id], contentSizeDelta: delta)
    }
}
