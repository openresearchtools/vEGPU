import Foundation
import Darwin

public struct MetricsPayload: @unchecked Sendable {
    public let value: [String: Any]
}

public struct CpuSnapshot: Sendable {
    public var idle: UInt64
    public var total: UInt64
}

public struct NetworkSnapshot: Sendable {
    public var receivedBytes: Int64
    public var transmittedBytes: Int64
    public var sampledAtMs: Int64
    public var interfaceName: String?
}

public struct DiskSnapshot: Sendable {
    public var totalBytes: Int64
    public var busyMs: Int64?
    public var sampledAtMs: Int64
    public var deviceName: String?
}

public final class MetricsService: @unchecked Sendable {
    private let runner: ProcessRunner
    private let ssh: SSHClient
    private let machinePid: () -> Int32?
    private var hostCpu: CpuSnapshot?
    private var guestCpu: CpuSnapshot?
    private var hostNetwork: NetworkSnapshot?
    private var guestNetwork: NetworkSnapshot?
    private var hostDisk: DiskSnapshot?
    private var guestDisk: DiskSnapshot?
    private var hostDiskName: String?
    private var lastNvidia: NvidiaSmiStatus?

    public init(ssh: SSHClient, runner: ProcessRunner = ProcessRunner(), machinePid: @escaping () -> Int32?) {
        self.ssh = ssh
        self.runner = runner
        self.machinePid = machinePid
    }

    public func metrics() async -> MetricsPayload {
        await Task.detached(priority: .utility) {
            let host = self.readHostMetrics()
            let resolvedGuest = await self.readGuestMetrics()
            let resolvedNvidia = await self.readNvidiaSmiStatus()
            return MetricsPayload(value: [
                "host": host,
                "guest": resolvedGuest,
                "nvidia": [
                    "available": resolvedNvidia.available,
                    "state": resolvedNvidia.state,
                    "summary": resolvedNvidia.summary,
                    "detail": resolvedNvidia.detail,
                    "gpus": resolvedNvidia.gpus ?? []
                ],
                "sampledAt": ISO8601DateFormatter().string(from: Date())
            ])
        }.value
    }

    public func readNvidiaSmiStatus() async -> NvidiaSmiStatus {
        guard machinePid() != nil else {
            lastNvidia = nil
            return NvidiaSmiParser.stopped()
        }
        do {
            let output = try await ssh.ssh([
                "if ! command -v nvidia-smi >/dev/null 2>&1; then echo '__PEGPU_NVIDIA_SMI_MISSING__'; exit 127; fi",
                "nvidia-smi --query-gpu=\(NvidiaSmiParser.query) --format=csv,noheader,nounits"
            ].joined(separator: "; "))
            let status = NvidiaSmiParser.parse(output)
            if status.state == "ready" || status.state == "missing" {
                lastNvidia = status
            }
            return status
        } catch {
            return NvidiaSmiParser.unavailable(firstLine(String(describing: error)))
        }
    }

    private func readHostMetrics() -> [String: Any] {
        let next = readHostCpuSnapshot()
        let cpuPercent = percentBetween(previous: hostCpu, next: next)
        hostCpu = next
        var out: [String: Any] = ["state": "ready"]
        if let cpuPercent { out["cpuPercent"] = cpuPercent }
        out.merge(readHostMemoryMetrics()) { _, new in new }
        out.merge(readHostPowerMetrics()) { _, new in new }
        out["network"] = safeReadHostNetworkMetrics()
        out["disk"] = safeReadHostDiskMetrics()
        out["gpus"] = readHostGpuMetrics()
        return out
    }

    private func readHostCpuSnapshot() -> CpuSnapshot {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return CpuSnapshot(idle: 0, total: 0) }
        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return CpuSnapshot(idle: idle, total: user + system + idle + nice)
    }

    private func readHostMemoryMetrics() -> [String: Any] {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let pageSize = Int64(getpagesize())
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result != KERN_SUCCESS {
            return ["memoryTotalBytes": total, "memoryDetail": "Fallback memory estimate."]
        }
        let used = Int64(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count) * pageSize
        return [
            "memoryTotalBytes": total,
            "memoryUsedBytes": max(0, min(total, used)),
            "memoryAvailableBytes": max(0, total - used),
            "memoryDetail": "App + wired + compressed memory; file cache is excluded."
        ]
    }

    private func safeReadHostNetworkMetrics() -> [String: Any] {
        do { return try readHostNetworkMetrics() } catch { return ["detail": firstLine(String(describing: error))] }
    }

    private func safeReadHostDiskMetrics() -> [String: Any] {
        do { return try readHostDiskMetrics() } catch { return ["detail": firstLine(String(describing: error))] }
    }

    private func readHostPowerMetrics() -> [String: Any] {
        do {
            let output = try Process.runAndCapture("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "AppleSmartBattery"])
            let telemetry = capture(output, #"\"PowerTelemetryData\"\s*=\s*\{([^}]+)\}"#) ?? ""
            func telemetryMilliwatts(_ name: String) -> Double? {
                guard let raw = numberFromProperty(telemetry, name), raw > 0, raw < 1_000_000 else { return nil }
                return raw / 1_000
            }
            var powerW = telemetryMilliwatts("SystemPowerIn")
                ?? telemetryMilliwatts("SystemLoad")
                ?? telemetryMilliwatts("BatteryPower")
            let voltageMv = numberFromProperty(output, "AppleRawBatteryVoltage") ?? numberFromProperty(output, "Voltage")
            let amperageMa = numberFromProperty(output, "InstantAmperage") ?? numberFromProperty(output, "Amperage")
            if powerW == nil, let voltageMv, let amperageMa, amperageMa != 0 {
                powerW = abs(voltageMv * amperageMa) / 1_000_000
            }
            let adapterPowerW = adapterWatts(fromBatteryOutput: output)
            let source = output.range(of: #"\"ExternalConnected\"\s*=\s*Yes"#, options: .regularExpression) == nil ? "Battery" : "AC"
            let details = [
                powerW.map { _ in "\(source) system input from AppleSmartBattery telemetry" },
                adapterPowerW.map { "adapter \(Int($0.rounded())) W available" }
            ].compactMap { $0 }
            var out: [String: Any] = [
                "powerSource": source,
                "powerDetail": details.isEmpty ? "Mac power telemetry unavailable" : details.joined(separator: "; ")
            ]
            if let powerW {
                out["powerW"] = powerW
            }
            if let adapterPowerW {
                out["adapterPowerW"] = adapterPowerW
            }
            return out
        } catch {
            return [
                "powerDetail": "Mac power telemetry unavailable: \(firstLine(String(describing: error)))"
            ]
        }
    }

    private func readHostNetworkMetrics() throws -> [String: Any] {
        let output = try Process.runAndCapture("/usr/sbin/netstat", ["-ibn"])
        let next = selectHostNetworkCounters(parseHostNetworkCounters(output))
        let metrics = networkMetricsBetween(previous: hostNetwork, next: next)
        hostNetwork = next
        return metrics
    }

    private func readHostDiskMetrics() throws -> [String: Any] {
        let diskName = try resolveHostDiskName()
        let output = try Process.runAndCapture("/usr/sbin/iostat", ["-Id", diskName])
        let next = try parseHostDiskSnapshot(output, deviceName: diskName)
        let metrics = diskMetricsBetween(previous: hostDisk, next: next)
        hostDisk = next
        return metrics
    }

    private func resolveHostDiskName() throws -> String {
        if let hostDiskName {
            return hostDiskName
        }
        let output = try Process.runAndCapture("/usr/sbin/diskutil", ["info", "/"])
        let candidates = [
            capture(output, #"APFS Physical Store:\s*(disk[0-9]+(?:s[0-9]+)?)"#),
            capture(output, #"Part of Whole:\s*(disk[0-9]+)"#),
            capture(output, #"Device Identifier:\s*(disk[0-9]+(?:s[0-9]+)?)"#)
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let wholeDisk = capture(candidate, #"^(disk[0-9]+)"#) {
                hostDiskName = wholeDisk
                return wholeDisk
            }
        }
        throw RuntimeError.message("Host disk unavailable")
    }

    private func parseHostDiskSnapshot(_ output: String, deviceName: String) throws -> DiskSnapshot {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3, Double(parts[0]) != nil, Double(parts[1]) != nil, let totalMB = Double(parts[2]) else {
                continue
            }
            return DiskSnapshot(
                totalBytes: Int64(max(0, totalMB) * 1_048_576),
                busyMs: nil,
                sampledAtMs: nowMs(),
                deviceName: deviceName
            )
        }
        throw RuntimeError.message("Host disk counters unavailable")
    }

    private func parseHostNetworkCounters(_ output: String) -> [String: NetworkSnapshot] {
        var out: [String: NetworkSnapshot] = [:]
        let sampled = nowMs()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.count < 10 || parts[0] == "Name" || !parts[2].hasPrefix("<Link#") { continue }
            let name = parts[0].replacingOccurrences(of: "*", with: "")
            if name.isEmpty || parts[0].hasSuffix("*") || name == "lo0" { continue }
            guard let rx = Int64(parts[6]), let tx = Int64(parts[9]) else { continue }
            out[name] = NetworkSnapshot(receivedBytes: rx, transmittedBytes: tx, sampledAtMs: sampled, interfaceName: name)
        }
        return out
    }

    private func selectHostNetworkCounters(_ interfaces: [String: NetworkSnapshot]) -> NetworkSnapshot {
        if let vmnet = interfaces["bridge100"] ?? interfaces["vmenet0"] { return vmnet }
        var rx: Int64 = 0
        var tx: Int64 = 0
        var names: [String] = []
        for (name, counters) in interfaces where !name.hasPrefix("awdl") && !name.hasPrefix("llw") && !name.hasPrefix("utun") {
            rx += counters.receivedBytes
            tx += counters.transmittedBytes
            names.append(name)
        }
        return NetworkSnapshot(receivedBytes: rx, transmittedBytes: tx, sampledAtMs: nowMs(), interfaceName: names.joined(separator: "+"))
    }

    private func readGuestMetrics() async -> [String: Any] {
        guard machinePid() != nil else {
            guestCpu = nil
            guestNetwork = nil
            guestDisk = nil
            return ["state": "stopped", "detail": "VM stopped"]
        }
        do {
            let output = try await ssh.ssh([
                "read cpu user nice system idle iowait irq softirq steal rest < /proc/stat",
                "printf 'cpu %s %s %s %s %s %s %s %s\\n' \"$user\" \"$nice\" \"$system\" \"$idle\" \"$iowait\" \"$irq\" \"$softirq\" \"$steal\"",
                "awk '/^(MemTotal|MemAvailable):/ {print $1, $2}' /proc/meminfo",
                "iface=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5; exit}')",
                "if [ -z \"$iface\" ]; then for path in /sys/class/net/*; do name=${path##*/}; [ \"$name\" = lo ] && continue; iface=$name; break; done; fi",
                "if [ -n \"$iface\" ] && [ -r \"/sys/class/net/$iface/statistics/rx_bytes\" ]; then printf 'net %s %s %s\\n' \"$iface\" \"$(cat /sys/class/net/$iface/statistics/rx_bytes)\" \"$(cat /sys/class/net/$iface/statistics/tx_bytes)\"; fi",
                "rootdev=$(findmnt -n -o SOURCE / 2>/dev/null || true)",
                "disk=$(lsblk -no PKNAME \"$rootdev\" 2>/dev/null | head -n1)",
                "if [ -z \"$disk\" ]; then disk=$(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2==\"disk\" {print $1; exit}'); fi",
                "if [ -n \"$disk\" ]; then awk -v d=\"$disk\" '$3==d {print \"disk\", $3, $6, $10, $13}' /proc/diskstats; fi"
            ].joined(separator: "; "), timeout: 1)
            let parsed = parseGuestMetrics(output)
            let cpuPercent = percentBetween(previous: guestCpu, next: parsed.cpu)
            guestCpu = parsed.cpu
            var out: [String: Any] = [
                "state": "ready",
                "sampledAtMs": nowMs(),
                "memoryTotalBytes": parsed.memoryTotalBytes,
                "memoryAvailableBytes": parsed.memoryAvailableBytes,
                "memoryUsedBytes": max(0, parsed.memoryTotalBytes - parsed.memoryAvailableBytes)
            ]
            if let cpuPercent { out["cpuPercent"] = cpuPercent }
            if let network = parsed.network {
                out["network"] = networkMetricsBetween(previous: guestNetwork, next: network)
                guestNetwork = network
            }
            if let disk = parsed.disk {
                out["disk"] = diskMetricsBetween(previous: guestDisk, next: disk)
                guestDisk = disk
            }
            return out
        } catch {
            guestNetwork = nil
            guestDisk = nil
            return ["state": "unavailable", "detail": firstLine(String(describing: error))]
        }
    }

    private func parseGuestMetrics(_ output: String) -> (cpu: CpuSnapshot, memoryTotalBytes: Int64, memoryAvailableBytes: Int64, network: NetworkSnapshot?, disk: DiskSnapshot?) {
        var cpu = CpuSnapshot(idle: 0, total: 0)
        var total: Int64 = 0
        var available: Int64 = 0
        var network: NetworkSnapshot?
        var disk: DiskSnapshot?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if parts.first == "cpu" {
                let values = parts.dropFirst().map { UInt64($0) ?? 0 }
                let idle = values[safe: 3, default: 0] + values[safe: 4, default: 0]
                cpu = CpuSnapshot(idle: idle, total: values.reduce(0, +))
            } else if parts.first == "MemTotal:" {
                total = (Int64(parts[safe: 1] ?? "0") ?? 0) * 1024
            } else if parts.first == "MemAvailable:" {
                available = (Int64(parts[safe: 1] ?? "0") ?? 0) * 1024
            } else if parts.first == "net", parts.count >= 4, let rx = Int64(parts[2]), let tx = Int64(parts[3]) {
                network = NetworkSnapshot(receivedBytes: rx, transmittedBytes: tx, sampledAtMs: nowMs(), interfaceName: parts[1])
            } else if parts.first == "disk", parts.count >= 5, let sectorsRead = Int64(parts[2]), let sectorsWritten = Int64(parts[3]), let busyMs = Int64(parts[4]) {
                disk = DiskSnapshot(
                    totalBytes: max(0, sectorsRead + sectorsWritten) * 512,
                    busyMs: busyMs,
                    sampledAtMs: nowMs(),
                    deviceName: parts[1]
                )
            }
        }
        return (cpu, total, available, network, disk)
    }

    private func networkMetricsBetween(previous: NetworkSnapshot?, next: NetworkSnapshot) -> [String: Any] {
        let elapsed = previous.map { max(0, Double(next.sampledAtMs - $0.sampledAtMs) / 1000) } ?? 0
        let rxDelta = previous.map { max(0, next.receivedBytes - $0.receivedBytes) } ?? 0
        let txDelta = previous.map { max(0, next.transmittedBytes - $0.transmittedBytes) } ?? 0
        return [
            "interfaceName": next.interfaceName ?? "network",
            "receivedBytes": next.receivedBytes,
            "transmittedBytes": next.transmittedBytes,
            "receiveBytesPerSecond": elapsed > 0 ? Double(rxDelta) / elapsed : 0,
            "transmitBytesPerSecond": elapsed > 0 ? Double(txDelta) / elapsed : 0
        ]
    }

    private func diskMetricsBetween(previous: DiskSnapshot?, next: DiskSnapshot) -> [String: Any] {
        let elapsedMs = previous.map { max(0, next.sampledAtMs - $0.sampledAtMs) } ?? 0
        let byteDelta = previous.map { max(0, next.totalBytes - $0.totalBytes) } ?? 0
        let busyDelta = if let previousBusy = previous?.busyMs, let nextBusy = next.busyMs {
            max(0, nextBusy - previousBusy)
        } else {
            nil as Int64?
        }
        var out: [String: Any] = [
            "deviceName": next.deviceName ?? "disk",
            "totalBytes": next.totalBytes,
            "bytesPerSecond": elapsedMs > 0 ? Double(byteDelta) / (Double(elapsedMs) / 1000) : 0
        ]
        if let busyDelta, elapsedMs > 0 {
            out["loadPercent"] = max(0, min(100, (Double(busyDelta) / Double(elapsedMs)) * 100))
        }
        return out
    }

    private func percentBetween(previous: CpuSnapshot?, next: CpuSnapshot) -> Double? {
        guard let previous, next.total > previous.total else { return nil }
        let totalDelta = Double(next.total - previous.total)
        let idleDelta = Double(next.idle - previous.idle)
        guard totalDelta > 0 else { return nil }
        return max(0, min(100, ((totalDelta - idleDelta) / totalDelta) * 100))
    }

    private func readHostGpuMetrics() -> [[String: Any]] {
        guard let output = try? Process.runAndCapture("/usr/sbin/ioreg", ["-r", "-d", "1", "-c", "IOAccelerator"]) else { return [] }
        return output.components(separatedBy: "\n+-o ")
            .filter { $0.contains("PerformanceStatistics") }
            .map { block in
                [
                    "name": capture(block, #"\"model\" = \"([^\"]+)\""#) ?? capture(block, #"^([^\s<]+)"#) ?? "Mac GPU",
                    "utilizationPercent": numberMatch(block, #"\"Device Utilization %\"=([0-9]+)"#) as Any,
                    "rendererPercent": numberMatch(block, #"\"Renderer Utilization %\"=([0-9]+)"#) as Any,
                    "tilerPercent": numberMatch(block, #"\"Tiler Utilization %\"=([0-9]+)"#) as Any,
                    "memoryUsedBytes": numberMatch(block, #"\"In use system memory\"=([0-9]+)"#) as Any,
                    "memoryAllocatedBytes": numberMatch(block, #"\"Alloc system memory\"=([0-9]+)"#) as Any,
                    "coreCount": numberMatch(block, #"\"gpu-core-count\" = ([0-9]+)"#) as Any
                ]
            }
    }

    private func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func numberMatch(_ text: String, _ pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    private func numberFromProperty(_ text: String, _ name: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return numberMatch(text, #"\"\#(escaped)\"\s*=\s*(-?[0-9]+(?:\.[0-9]+)?)"#)
    }

    private func adapterWatts(fromBatteryOutput output: String) -> Double? {
        guard let adapter = capture(output, #"\"AdapterDetails\"\s*=\s*\{([^}]+)\}"#) else { return nil }
        return numberFromProperty(adapter, "Watts")
    }
}

private extension Array where Element == UInt64 {
    subscript(safe index: Int, default fallback: UInt64) -> UInt64 {
        indices.contains(index) ? self[index] : fallback
    }
}
