import AppKit
import SwiftUI

@MainActor
final class SidebarMonitorState: ObservableObject {
    let logoImage: NSImage?

    private(set) var runtimeStatus = "Stopped"
    private(set) var runtimeDetail = "Backend VM is not running"
    private(set) var runtimeMetric = "Stopped"
    private(set) var runtimeState = "stopped"
    private(set) var hostMetrics = MetricGroup()
    private(set) var vmMetrics = MetricGroup(cpu: "CPU --%", ram: "RAM stopped", net: "NET stopped", gpu: "GPU stopped")
    private(set) var powerMetric = PowerMetric()
    private(set) var hostGpuWidgets: [GpuWidgetMetric] = []
    private(set) var nvidiaGpuWidgets: [GpuWidgetMetric] = []

    init(logoURL: URL?) {
        self.logoImage = logoURL.flatMap { NSImage(contentsOf: $0) }
    }

    func updateRuntime(status: String, detail: String, metric: String, state: String) {
        guard runtimeStatus != status || runtimeDetail != detail || runtimeMetric != metric || runtimeState != state else {
            return
        }
        objectWillChange.send()
        runtimeStatus = status
        runtimeDetail = detail
        runtimeMetric = metric
        runtimeState = state
    }

    func updateMetrics(host: MetricGroup, vm: MetricGroup, power: PowerMetric, hostGpus: [GpuWidgetMetric], nvidiaGpus: [GpuWidgetMetric]) {
        guard hostMetrics != host || vmMetrics != vm || powerMetric != power || hostGpuWidgets != hostGpus || nvidiaGpuWidgets != nvidiaGpus else {
            return
        }
        objectWillChange.send()
        hostMetrics = host
        vmMetrics = vm
        powerMetric = power
        hostGpuWidgets = hostGpus
        nvidiaGpuWidgets = nvidiaGpus
    }
}
