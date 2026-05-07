import CoreGraphics

public struct LayoutDiff: Sendable {
    public let changed: Set<ItemID>
    public let inserted: Set<ItemID>
    public let removed: Set<ItemID>
    public let contentSizeDelta: CGFloat

    public init(
        changed: Set<ItemID> = [],
        inserted: Set<ItemID> = [],
        removed: Set<ItemID> = [],
        contentSizeDelta: CGFloat = 0
    ) {
        self.changed = changed
        self.inserted = inserted
        self.removed = removed
        self.contentSizeDelta = contentSizeDelta
    }

    public static let empty = LayoutDiff()
}
