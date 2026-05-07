import CoreGraphics

public protocol ChatItem: Sendable {
    var id: ItemID { get }
    /// Cell height. Authoritative — the host computes it from the cell's content
    /// (image sizes, label sizing, etc.) and provides it as a known value.
    var height: CGFloat { get }
    /// The group this item belongs to. Adjacent items sharing the same `groupId`
    /// form one sticky-header group; switching `groupId` (or going from non-nil
    /// to nil and back) starts a new group with its own header above the first item.
    /// Items returning `nil` participate in no group and get no header above them.
    var groupId: ItemID? { get }
}

public extension ChatItem {
    var groupId: ItemID? { nil }
}
