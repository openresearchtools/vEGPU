import SwiftUI

struct RuntimeTerminalView: View {
    let model: NativeAppModel
    @ObservedObject var terminal: RuntimeTerminalState

    var body: some View {
        ZStack(alignment: .topLeading) {
            if terminal.terminalConnected {
                SSHTerminalSession(paths: model.paths, input: terminal.terminalInput)
                    .id(terminal.terminalSessionID)
            } else {
                TerminalPlaceholderView()
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: RuntimePaneSizing.minHeight,
            idealHeight: RuntimePaneSizing.idealHeight,
            maxHeight: RuntimePaneSizing.maxHeight
        )
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
    }
}

private struct TerminalPlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SSH terminal closed")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(.white)
            Text("Open Terminal after the runtime is running.")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.gray)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
