import SwiftUI

struct DisplayControlMenuItems: View {
    @ObservedObject var model: DisplayControlMenuModel
    var beforeAction: (() -> Void)?
    var deferAfterBeforeAction = false

    var body: some View {
        Group {
            Button("Reconnect") {
                perform {
                    NotificationCenter.default.post(name: .pegpuReconnectDisplay, object: nil)
                }
            }

            Button("Reload") {
                perform {
                    model.reload()
                }
            }
            .disabled(model.embeddedBusy)

            Button("Microphone: \(model.microphonePassthroughEnabled ? "ON" : "OFF")") {
                perform {
                    model.toggleMicrophonePassthrough()
                }
            }
            .disabled(model.audioBusy)

            Divider()
            gpuControls
        }
        .onAppear {
            model.refresh()
            model.refreshAudioBridgeStatus()
        }
    }

    @ViewBuilder
    private var gpuControls: some View {
        if model.sessions.isEmpty {
            Button(model.busy ? "Loading GPUs..." : "No PCIe GPUs found") {}
                .disabled(true)
        } else {
            ForEach(Array(model.sessions.enumerated()), id: \.element.id) { offset, session in
                if session.running {
                    Button("Enter \(session.title) (Option-Cmd-\(offset + 2))") {
                        perform {
                            model.enterSession(session)
                        }
                    }
                    .disabled(model.busy)

                    Button("Stop \(session.title)") {
                        perform {
                            model.stopSession(session)
                        }
                    }
                    .disabled(model.busy)

                    Button("Reload \(session.title)") {
                        perform {
                            model.reloadSession(session)
                        }
                    }
                    .disabled(model.busy)
                } else {
                    Button("Start \(session.title) (Option-Cmd-\(offset + 2))") {
                        perform {
                            model.startSession(session)
                        }
                    }
                    .disabled(model.busy)
                }
            }
        }
    }

    private func perform(_ action: @escaping () -> Void) {
        beforeAction?()
        if deferAfterBeforeAction {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                action()
            }
        } else {
            action()
        }
    }
}
