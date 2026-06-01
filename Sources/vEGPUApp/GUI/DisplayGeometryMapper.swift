import CoreGraphics

struct DisplayRenderGeometry {
    let displayRect: CGRect
    let viewportOrigin: CGPoint
    let viewportScaleX: CGFloat
    let viewportScaleY: CGFloat
    let backingScale: CGFloat
}

struct DisplayGeometryMapper {
    static func renderGeometry(displaySize: CGSize, in bounds: CGRect, backingScale: CGFloat) -> DisplayRenderGeometry {
        guard displaySize.width > 0, displaySize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return DisplayRenderGeometry(
                displayRect: bounds,
                viewportOrigin: .zero,
                viewportScaleX: max(1, backingScale),
                viewportScaleY: max(1, backingScale),
                backingScale: max(1, backingScale)
            )
        }

        let scale = max(1, backingScale)
        let scaleX = max(0.01, (bounds.width * scale) / displaySize.width)
        let scaleY = max(0.01, (bounds.height * scale) / displaySize.height)

        return DisplayRenderGeometry(
            displayRect: bounds,
            viewportOrigin: .zero,
            viewportScaleX: scaleX,
            viewportScaleY: scaleY,
            backingScale: scale
        )
    }

    static func guestPoint(_ point: CGPoint, in geometry: DisplayRenderGeometry) -> CGPoint? {
        let renderRect = geometry.displayRect
        guard renderRect.width > 0, renderRect.height > 0, renderRect.contains(point) else {
            return nil
        }
        let x = (point.x - renderRect.minX) * geometry.backingScale / geometry.viewportScaleX
        let y = (renderRect.height - (point.y - renderRect.minY)) * geometry.backingScale / geometry.viewportScaleY
        return CGPoint(x: max(0, x), y: max(0, y))
    }
}
