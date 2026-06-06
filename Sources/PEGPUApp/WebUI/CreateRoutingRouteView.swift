import SwiftUI
import PEGPUCore

struct CreateRoutingRouteView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var direction: PortForwardDirection = .vmToMac
    @State private var vmPort = ""
    @State private var localPort = ""
    @State private var exposeWebUI = false
    @State private var webUITitle = ""
    @State private var useUDP = false
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Create Routing Route")
                    .font(.title3.weight(.semibold))
                Text(headerDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Direction", selection: $direction) {
                Text("VM to Mac").tag(PortForwardDirection.vmToMac)
                Text("Mac to VM").tag(PortForwardDirection.macToVM)
            }
            .pickerStyle(.segmented)

            inputBlock(
                title: vmPortTitle,
                detail: vmPortDetail,
                text: $vmPort,
                placeholder: vmPortPlaceholder
            )

            inputBlock(
                title: localPortTitle,
                detail: localPortDetail,
                text: $localPort,
                placeholder: localPortPlaceholder
            )

            VStack(alignment: .leading, spacing: 10) {
                if direction == .vmToMac {
                    Toggle("Web UI tab", isOn: $exposeWebUI)
                        .disabled(useUDP)
                        .help("Adds this route as a sidebar Web UI tab using http://127.0.0.1:<PORT>.")
                    if exposeWebUI {
                        inputBlock(
                            title: "Name",
                            detail: "This becomes the sidebar tab name, for example ComfyUI or Dashboard.",
                            text: $webUITitle,
                            placeholder: "Example: ComfyUI"
                        )
                        Text(previewURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(previewURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("UDP route", isOn: $useUDP)
                    .help("Use UDP instead of TCP for this route.")
                if useUDP {
                    Text(udpDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Creating..." : "Create Route") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onChange(of: direction) { _, value in
            if value == .macToVM {
                exposeWebUI = false
            }
        }
        .onChange(of: useUDP) { _, value in
            if value {
                exposeWebUI = false
            }
        }
    }

    private var headerDetail: String {
        switch direction {
        case .vmToMac:
            return "Expose a service running inside the VM on a private localhost port on this Mac."
        case .macToVM:
            return "Expose a Mac localhost service to the VM through the private vmnet gateway."
        }
    }

    private var vmPortTitle: String {
        switch direction {
        case .vmToMac: return "VM service port"
        case .macToVM: return "VM gateway port"
        }
    }

    private var vmPortDetail: String {
        switch direction {
        case .vmToMac:
            return "Type the port the Linux/VM service is listening on, for example 8188."
        case .macToVM:
            return "Type the port the VM will connect to at 172.29.253.1."
        }
    }

    private var vmPortPlaceholder: String {
        switch direction {
        case .vmToMac: return "Example: 8188"
        case .macToVM: return "Example: 18080"
        }
    }

    private var localPortTitle: String {
        switch direction {
        case .vmToMac: return "Mac localhost port (127.0.0.1)"
        case .macToVM: return "Mac localhost service port"
        }
    }

    private var localPortDetail: String {
        switch direction {
        case .vmToMac:
            return "Type the Mac port you want to open locally. You will connect to 127.0.0.1 on this port."
        case .macToVM:
            return "Type the Mac service port already listening on 127.0.0.1."
        }
    }

    private var localPortPlaceholder: String {
        switch direction {
        case .vmToMac: return "Example: 18188"
        case .macToVM: return "Example: 8080"
        }
    }

    private var previewURL: String {
        let port = (direction == .vmToMac ? localPort : vmPort).trimmingCharacters(in: .whitespacesAndNewlines)
        if port.isEmpty {
            switch direction {
            case .vmToMac:
                return "Web UI opens at http://127.0.0.1:<PORT>/"
            case .macToVM:
                return useUDP ? "Inside VM send UDP to 172.29.253.1:<PORT>/udp." : "Inside VM use http://172.29.253.1:<PORT>/"
            }
        }
        switch direction {
        case .vmToMac:
            return "Web UI opens at http://127.0.0.1:\(port)/"
        case .macToVM:
            return useUDP ? "Inside VM send UDP to 172.29.253.1:\(port)/udp." : "Inside VM use http://172.29.253.1:\(port)/"
        }
    }

    private var udpDetail: String {
        switch direction {
        case .vmToMac:
            return "UDP is for UDP services. Browser Web UI tabs use TCP, so the Web UI option is off."
        case .macToVM:
            return "UDP uses the same VM gateway address. Inside the VM, send UDP traffic to 172.29.253.1 on the VM gateway port."
        }
    }

    private func inputBlock(title: String, detail: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.callout.weight(.semibold))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        guard !isSaving else { return }
        do {
            let parsedVMPort = try parsePort(vmPort, field: vmPortTitle, allowPrivileged: direction == .vmToMac)
            let parsedLocalPort = try parsePort(localPort, field: localPortTitle, allowPrivileged: direction == .macToVM)
            let title = try webUITitleForSubmission()
            errorText = nil
            isSaving = true
            Task { @MainActor in
                defer { isSaving = false }
                do {
                    try await model.createRoutingRoute(
                        direction: direction,
                        vmPort: parsedVMPort,
                        localPort: parsedLocalPort,
                        useUDP: useUDP,
                        webUITitle: title
                    )
                    dismiss()
                } catch {
                    errorText = firstLine(String(describing: error))
                }
            }
        } catch {
            errorText = firstLine(String(describing: error))
        }
    }

    private func parsePort(_ raw: String, field: String, allowPrivileged: Bool) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), port > 0, port < 65_536 else {
            throw RuntimeError.message("\(field) must be a number from 1 to 65535.")
        }
        if !allowPrivileged, port < 1_024 {
            throw RuntimeError.message("\(field) must be 1024 or higher because the helper binds localhost without administrator privileges.")
        }
        return port
    }

    private func webUITitleForSubmission() throws -> String? {
        guard exposeWebUI, direction == .vmToMac else { return nil }
        let title = webUITitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw RuntimeError.message("Type a Web UI tab name.")
        }
        return title
    }
}
