import SwiftUI
import vEGPUCore

struct AddWebUIView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var host = VMNet.guestIP
    @State private var port = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Web UI")
                    .font(.title3.weight(.semibold))
                Text("Create a sidebar tab that opens a VM Web UI directly in WebKit. No localhost route or proxy is created.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputBlock(
                title: "Name",
                detail: "This becomes the sidebar tab name, for example ComfyUI or Dashboard.",
                text: $title,
                placeholder: "Example: ComfyUI"
            )

            inputBlock(
                title: "VM address",
                detail: "Type only the VM IP address. The default vEGPU address is \(VMNet.guestIP).",
                text: $host,
                placeholder: VMNet.guestIP
            )

            inputBlock(
                title: "PORT inside VM",
                detail: "Type the port the VM Web UI is listening on, for example 8188.",
                text: $port,
                placeholder: "Example: 8188"
            )

            Text(previewURL)
                .font(.caption)
                .foregroundStyle(.secondary)

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
                Button("Add Web UI") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            host = model.defaultWebUIHost()
        }
    }

    private var previewURL: String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty || cleanPort.isEmpty {
            return "Web UI opens at http://\(VMNet.guestIP):<PORT>/"
        }
        return "Web UI opens at http://\(cleanHost):\(cleanPort)/"
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
        do {
            let parsedPort = try parsePort(port)
            try model.addDirectWebUI(title: title, host: host, port: parsedPort)
            errorText = nil
            dismiss()
        } catch {
            errorText = firstLine(String(describing: error))
        }
    }

    private func parsePort(_ raw: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0, value < 65_536 else {
            throw RuntimeError.message("PORT inside VM must be a number from 1 to 65535.")
        }
        return value
    }
}
