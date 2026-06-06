import SwiftUI

struct WrappingHStackLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrangedRows(for: subviews, maxWidth: proposal.width)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + row.height
        } + CGFloat(max(rows.count - 1, 0)) * rowSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangedRows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let point = CGPoint(x: x, y: y + (row.height - item.size.height) / 2)
                subviews[item.index].place(
                    at: point,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrangedRows(for subviews: Subviews, maxWidth proposedMaxWidth: CGFloat?) -> [ToolbarRow] {
        let maxWidth = proposedMaxWidth.map { max($0, 0) } ?? .greatestFiniteMagnitude
        var rows: [ToolbarRow] = []
        var current = ToolbarRow()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if nextWidth > maxWidth, !current.items.isEmpty {
                rows.append(current)
                current = ToolbarRow()
            }
            current.append(ToolbarItem(index: index, size: size), spacing: spacing)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

private struct ToolbarRow {
    var items: [ToolbarItem] = []
    var width: CGFloat = 0
    var height: CGFloat = 0

    mutating func append(_ item: ToolbarItem, spacing: CGFloat) {
        width += items.isEmpty ? item.size.width : spacing + item.size.width
        height = max(height, item.size.height)
        items.append(item)
    }
}

private struct ToolbarItem {
    let index: Int
    let size: CGSize
}
