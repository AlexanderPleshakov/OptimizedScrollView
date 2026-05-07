import CoreGraphics

@MainActor
struct AnchorController {
    let store: LayoutStore

    struct Capture {
        let anchor: Anchor
        let topInset: CGFloat
    }

    /// Capture the topmost item visible at `contentOffsetY` together with the contentInset.top
    /// at the moment of capture. Storing the inset lets `restoredOffsetY` compensate when the
    /// inset shifts between capture and restore (e.g. bottom-anchoring engages/disengages).
    func capture(contentOffsetY: CGFloat, topInset: CGFloat) -> Capture? {
        guard !store.isEmpty else { return nil }
        let raw = store.firstIndex(intersecting: contentOffsetY)
        let i = min(max(raw, 0), store.count - 1)
        let attr = store.attributes(at: i)
        let anchor = Anchor(id: attr.id, offsetFromTop: attr.frame.minY - contentOffsetY)
        return Capture(anchor: anchor, topInset: topInset)
    }

    /// New contentOffset.y that keeps the anchored item visually at the same screen position,
    /// accounting for any contentInset.top change between capture and restore.
    /// Returns nil if the anchor item is no longer in the store.
    func restoredOffsetY(for capture: Capture, currentTopInset: CGFloat) -> CGFloat? {
        guard let attr = store.attributes(for: capture.anchor.id) else { return nil }
        let scrollSpaceY = attr.frame.minY - capture.anchor.offsetFromTop
        return scrollSpaceY + (currentTopInset - capture.topInset)
    }
}
