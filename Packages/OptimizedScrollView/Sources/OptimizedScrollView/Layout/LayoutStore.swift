import CoreGraphics

@MainActor
final class LayoutStore {
    private(set) var order: [ItemID] = []
    private var indexById: [ItemID: Int] = [:]
    private var attrs: [LayoutAttributes] = []
    private(set) var contentHeight: CGFloat = 0

    private(set) var headerOrder: [ItemID] = []
    private var headerIndexById: [ItemID: Int] = [:]
    private var headerAttrs: [LayoutAttributes] = []
    private var headerGroupIds: [ItemID: ItemID] = [:]

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }

    func index(of id: ItemID) -> Int? { indexById[id] }
    func attributes(at index: Int) -> LayoutAttributes { attrs[index] }
    func attributes(for id: ItemID) -> LayoutAttributes? {
        indexById[id].map { attrs[$0] }
    }
    func frame(for id: ItemID) -> CGRect? { attributes(for: id)?.frame }
    func allAttributes() -> [LayoutAttributes] { attrs }

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
        self.order = order
        self.attrs = attributes
        self.indexById = .init(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        self.headerOrder = headerOrder
        self.headerAttrs = headerAttributes
        self.headerIndexById = .init(uniqueKeysWithValues: headerOrder.enumerated().map { ($1, $0) })
        self.headerGroupIds = headerGroupIds

        let lastItemY = attributes.last?.frame.maxY ?? 0
        let lastHeaderY = headerAttributes.last?.frame.maxY ?? 0
        self.contentHeight = max(lastItemY, lastHeaderY)
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
}
