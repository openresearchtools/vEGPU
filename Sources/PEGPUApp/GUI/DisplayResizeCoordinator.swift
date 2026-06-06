import CoreGraphics
import CocoaSpiceNoUsb

@MainActor
final class DisplayResizeCoordinator {
    private var pending: Task<Void, Never>?
    private var lastRequested = CGSize.zero

    func targetSize(size: CGSize, backingScale: CGFloat, retina: Bool) -> CGSize {
        let targetScale = retina ? max(1, backingScale) : 1
        let width = max(640, Int((size.width * targetScale).rounded(.toNearestOrAwayFromZero)))
        let height = max(480, Int((size.height * targetScale).rounded(.toNearestOrAwayFromZero)))
        return CGSize(width: width, height: height)
    }

    @discardableResult
    func request(display: CSDisplay?, size: CGSize, backingScale: CGFloat, retina: Bool, force: Bool = false) -> CGSize? {
        guard let display else { return nil }
        let next = targetSize(size: size, backingScale: backingScale, retina: retina)
        guard force || next != lastRequested else {
            return nil
        }
        pending?.cancel()
        pending = Task { [weak self, weak display] in
            guard !Task.isCancelled, let display else { return }
            self?.lastRequested = next
            for delay in [UInt64(0), 250_000_000, 750_000_000, 1_500_000_000, 3_000_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                display.requestResolution(CGRect(origin: .zero, size: next))
            }
        }
        return next
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
