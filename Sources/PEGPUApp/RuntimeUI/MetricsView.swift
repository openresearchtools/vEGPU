import SwiftUI

struct MetricsView: View {
    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                MetricTile(title: "Mac CPU", value: "Pending")
                MetricTile(title: "Mac RAM", value: "Pending")
                MetricTile(title: "Mac NET", value: "Pending")
                MetricTile(title: "Mac GPU", value: "Pending")
            }
            GridRow {
                MetricTile(title: "VM CPU", value: "Stopped")
                MetricTile(title: "VM RAM", value: "Stopped")
                MetricTile(title: "VM NET", value: "Stopped")
                MetricTile(title: "VM GPU", value: "Stopped")
            }
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
