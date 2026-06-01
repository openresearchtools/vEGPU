import Foundation

public struct NvidiaGpuMetric: Codable, Equatable, Sendable {
    public var index: Int?
    public var name: String
    public var driverVersion: String
    public var temperatureC: Double?
    public var utilizationPercent: Double?
    public var memoryUsedMiB: Double?
    public var memoryTotalMiB: Double?
    public var powerW: Double?
}

public struct NvidiaSmiStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var state: String
    public var summary: String
    public var detail: String
    public var output: String
    public var gpus: [NvidiaGpuMetric]?
    public var sampledAtMs: Int64?
    public var stale: Bool?
}

public enum NvidiaSmiParser {
    public static let query = [
        "index",
        "name",
        "driver_version",
        "temperature.gpu",
        "utilization.gpu",
        "memory.used",
        "memory.total",
        "power.draw"
    ].joined(separator: ",")

    public static func stopped() -> NvidiaSmiStatus {
        NvidiaSmiStatus(available: false, state: "stopped", summary: "Runtime stopped", detail: "Start the runtime to poll nvidia-smi.", output: "", sampledAtMs: nowMs())
    }

    public static func unavailable(_ detail: String) -> NvidiaSmiStatus {
        let booting = detail.range(of: "ssh|connect|reset|closed|refused|timed out", options: [.regularExpression, .caseInsensitive]) != nil
        return NvidiaSmiStatus(available: false, state: booting ? "booting" : "unavailable", summary: "nvidia-smi unavailable", detail: detail, output: detail, sampledAtMs: nowMs())
    }

    public static func parse(_ output: String) -> NvidiaSmiStatus {
        if output.contains("__VEGPU_NVIDIA_SMI_MISSING__") {
            return NvidiaSmiStatus(available: false, state: "missing", summary: "nvidia-smi missing", detail: "NVIDIA driver tools are not installed inside Linux.", output: "", sampledAtMs: nowMs())
        }
        let rows = parseRows(output)
        guard !rows.isEmpty else {
            return NvidiaSmiStatus(available: false, state: "unavailable", summary: "No GPU data", detail: output.isEmpty ? "nvidia-smi returned no GPU rows." : output, output: output, sampledAtMs: nowMs())
        }
        return NvidiaSmiStatus(available: true, state: "ready", summary: summary(rows), detail: "Live nvidia-smi data", output: format(rows), gpus: metrics(rows), sampledAtMs: nowMs())
    }

    public static func parseRows(_ output: String) -> [[String]] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.range(of: #"^No devices were found"#, options: [.regularExpression, .caseInsensitive]) == nil }
            .map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }

    private static func metrics(_ rows: [[String]]) -> [NvidiaGpuMetric] {
        rows.map {
            NvidiaGpuMetric(
                index: intOrNil($0[safe: 0]),
                name: $0[safe: 1] ?? "NVIDIA GPU",
                driverVersion: $0[safe: 2] ?? "",
                temperatureC: numberOrNil($0[safe: 3]),
                utilizationPercent: numberOrNil($0[safe: 4]),
                memoryUsedMiB: numberOrNil($0[safe: 5]),
                memoryTotalMiB: numberOrNil($0[safe: 6]),
                powerW: numberOrNil($0[safe: 7])
            )
        }
    }

    private static func summary(_ rows: [[String]]) -> String {
        if rows.count == 1 {
            let row = rows[0]
            return "\(row[safe: 1] ?? "GPU") - \(row[safe: 4] ?? "0")% - \(row[safe: 5] ?? "0")/\(row[safe: 6] ?? "0") MiB - \(row[safe: 3] ?? "?")C"
        }
        let used = sum(rows, index: 5)
        let total = sum(rows, index: 6)
        let util = rows.isEmpty ? 0 : Int(round(sum(rows, index: 4) / Double(rows.count)))
        return "\(rows.count) GPUs - \(util)% avg - \(Int(used))/\(Int(total)) MiB"
    }

    private static func format(_ rows: [[String]]) -> String {
        var lines = ["GPU  Name                          Driver       Temp  Util  Memory MiB       Power W"]
        for row in rows {
            lines.append([
                pad(row[safe: 0] ?? "?", 4),
                pad(row[safe: 1] ?? "unknown", 29),
                pad(row[safe: 2] ?? "unknown", 12),
                pad("\(row[safe: 3] ?? "?")C", 5),
                pad("\(row[safe: 4] ?? "?")%", 5),
                pad("\(row[safe: 5] ?? "?")/\(row[safe: 6] ?? "?")", 16),
                row[safe: 7] ?? "?"
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private static func sum(_ rows: [[String]], index: Int) -> Double {
        rows.reduce(0) { $0 + (numberOrNil($1[safe: index]) ?? 0) }
    }

    private static func pad(_ value: String, _ length: Int) -> String {
        value.count > length ? String(value.prefix(max(0, length - 3))) + "..." : value.padding(toLength: length, withPad: " ", startingAt: 0)
    }
}

public func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

public func numberOrNil(_ value: String?) -> Double? {
    guard let value else { return nil }
    let filtered = value.filter { $0.isNumber || $0 == "." || $0 == "-" }
    return Double(filtered)
}

public func intOrNil(_ value: String?) -> Int? {
    numberOrNil(value).map(Int.init)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
