import CoreGraphics
import OptimizedScrollView

struct Message: ChatItem {
    let id: ItemID
    let text: String
    let isOutgoing: Bool
    let groupId: ItemID?
    let height: CGFloat
}
