import CoreGraphics

enum BottomAnchoring {
    /// Top contentInset that pushes content down so it sits at the bottom of the viewport
    /// when shorter than viewportHeight. Zero if content already fills the viewport.
    static func topInset(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, viewportHeight - contentHeight)
    }

    /// contentOffset.y that scrolls the content's last edge to the bottom of the viewport.
    /// `topInset` is the inset already applied (positive value); the returned offset is in
    /// UIScrollView coordinates (i.e. compatible with `contentOffset.y`).
    static func bottomPinnedOffsetY(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        topInset: CGFloat
    ) -> CGFloat {
        if contentHeight <= viewportHeight {
            return -topInset
        }
        return contentHeight - viewportHeight
    }
}
