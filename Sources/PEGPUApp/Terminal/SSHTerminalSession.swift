import AppKit
import SwiftTerm
import SwiftUI
import PEGPUCore

struct SSHTerminalSession: NSViewRepresentable {
    let paths: AppPaths
    let input: TerminalInput?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView(frame: .zero)
        let networkStore = NetworkStateStore(paths: paths)
        let ssh = SSHClient(paths: paths, networkStore: networkStore, role: .human)
        container.terminal.startProcess(
            executable: "/usr/bin/ssh",
            args: ssh.args(command: "cd ~; exec bash -l", tty: true),
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
        )
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        guard let input, context.coordinator.lastInputID != input.id else { return }
        context.coordinator.lastInputID = input.id
        nsView.terminal.send(txt: input.text)
    }

    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: Coordinator) {
        nsView.terminal.terminate()
    }

    final class Coordinator {
        var lastInputID: UUID?
    }
}

final class TerminalContainerView: NSView {
    let terminal = LocalProcessTerminalView(frame: .zero)

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(terminal)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(terminal)
    }

    override func layout() {
        super.layout()
        terminal.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTerminal()
    }

    override func mouseDown(with event: NSEvent) {
        focusTerminal()
        super.mouseDown(with: event)
    }

    private func focusTerminal() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.window?.makeFirstResponder(self.terminal)
        }
    }
}
