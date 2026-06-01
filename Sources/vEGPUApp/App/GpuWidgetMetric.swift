import Foundation

struct GpuWidgetMetric: Equatable, Identifiable {
    var source: String
    var index: Int?
    var title: String
    var name: String
    var primary: String
    var lines: [String]
    var percent: Double?

    var id: String {
        "\(source)-\(index.map(String.init) ?? name)"
    }
}
