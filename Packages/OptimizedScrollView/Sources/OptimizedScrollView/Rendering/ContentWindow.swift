import CoreGraphics

/// The region for which cells must exist: visible viewport plus a buffer
/// above and below measured in viewport heights.
struct ContentWindow {
    let viewport: CGRect
    let bufferScreens: CGFloat

    var preloadRect: CGRect {
        let dy = viewport.height * bufferScreens
        return CGRect(
            x: viewport.minX,
            y: viewport.minY - dy,
            width: viewport.width,
            height: viewport.height + 2 * dy
        )
    }
}
