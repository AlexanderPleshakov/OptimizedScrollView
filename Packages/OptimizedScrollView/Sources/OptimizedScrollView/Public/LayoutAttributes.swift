import CoreGraphics

public struct LayoutAttributes: Sendable {
    public let id: ItemID
    public var frame: CGRect

    public init(id: ItemID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}
