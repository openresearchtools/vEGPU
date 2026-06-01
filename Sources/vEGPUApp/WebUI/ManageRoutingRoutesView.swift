import SwiftUI
import vEGPUCore

struct ManageRoutingRoutesView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var routes: [HostForward] = []
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Routing Routes")
                    .font(.title3.weight(.semibold))
                Text("Delete private vmnet proxy routes between this Mac and the VM.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if routes.isEmpty {
                Text("No localhost routing routes are saved.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(routes, id: \.routeID) { route in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(route.title)
                                    .font(.callout.weight(.semibold))
                                Text(route.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete") {
                                delete(route)
                            }
                        }
                        .padding(.vertical, 9)
                        if route.routeID != routes.last?.routeID {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: reload)
    }

    private func reload() {
        routes = model.routingRoutes()
        errorText = nil
    }

    private func delete(_ route: HostForward) {
        do {
            try model.deleteRoutingRoute(route)
            reload()
        } catch {
            errorText = firstLine(String(describing: error))
        }
    }
}

private extension HostForward {
    var routeID: String {
        listenerKey
    }

    var suffix: String {
        self.protocol == "udp" ? "/udp" : ""
    }

    var title: String {
        switch direction {
        case .vmToMac:
            return "VM:\(vmPort)\(suffix) -> Mac 127.0.0.1:\(macPort)\(suffix)"
        case .macToVM:
            return "Mac 127.0.0.1:\(macPort)\(suffix) -> VM 172.29.253.1:\(vmPort)\(suffix)"
        }
    }

    var detail: String {
        let endpoint: String
        switch direction {
        case .vmToMac:
            endpoint = "Mac clients use 127.0.0.1:\(macPort)\(suffix)"
        case .macToVM:
            endpoint = "VM clients use 172.29.253.1:\(vmPort)\(suffix)"
        }
        return "\(self.protocol.uppercased()) route through vegpu-local-proxy - \(endpoint)"
    }
}
