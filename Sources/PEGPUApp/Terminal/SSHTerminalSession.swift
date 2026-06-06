import SwiftTerm
import SwiftUI
import PEGPUCore

struct SSHTerminalSession: NSViewRepresentable {
    let paths: AppPaths
    let input: TerminalInput?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = LocalProcessTerminalView(frame: .zero)
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, role: .human)
        terminal.startProcess(
            executable: "/usr/bin/ssh",
            args: ssh.args(command: "cd ~; exec bash -l", tty: true),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
        )
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        guard let input, context.coordinator.lastInputID != input.id else { return }
        context.coordinator.lastInputID = input.id
        nsView.send(txt: input.text)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
        nsView.terminate()
    }

    final class Coordinator {
        var lastInputID: UUID?
    }
}
