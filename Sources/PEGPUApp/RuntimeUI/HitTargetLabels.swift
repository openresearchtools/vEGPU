import SwiftUI

struct HitTargetLabel: View {
    let title: String
    let minWidth: CGFloat?
    let minHeight: CGFloat

    init(_ title: String, minWidth: CGFloat? = nil, minHeight: CGFloat = 24) {
        self.title = title
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    var body: some View {
        Text(title)
            .frame(minWidth: minWidth, minHeight: minHeight)
            .contentShape(Rectangle())
    }
}

struct CircleHitTargetLabel: View {
    let title: String
    let size: CGFloat

    init(_ title: String, size: CGFloat = 24) {
        self.title = title
        self.size = size
    }

    var body: some View {
        Text(title)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }
}

