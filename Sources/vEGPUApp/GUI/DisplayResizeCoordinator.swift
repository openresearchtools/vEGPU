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
        pending = Task { @MainActor [weak self, weak display] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let display else { return }
            self.lastRequested = next
            display.requestResolution(CGRect(origin: .zero, size: next))
        }
        return next
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
