import CoreGraphics

public struct Anchor: Hashable, Sendable {
    public let id: ItemID
    public let offsetFromTop: CGFloat

    public init(id: ItemID, offsetFromTop: CGFloat) {
        self.id = id
        self.offsetFromTop = offsetFromTop
    }
}
