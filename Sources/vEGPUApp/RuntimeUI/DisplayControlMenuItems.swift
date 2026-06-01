import SwiftUI

struct DisplayControlMenuItems: View {
    @ObservedObject var model: DisplayControlMenuModel
    var beforeAction: (() -> Void)?
    var deferAfterBeforeAction = false

    var body: some View {
        Group {
            Button("Release Mouse (Option-Cmd-1)") {
                perform {
                    model.releaseSession()
                }
            }
            .disabled(model.busy)

            Divider()
            if model.sessions.isEmpty {
                Button(model.busy ? "Loading sessions..." : "No external GPUs found") {}
                    .disabled(true)
            } else {
                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { offset, session in
                    Button("\(session.running ? "Enter" : "Start") \(session.title) (Option-Cmd-\(offset + 2))") {
                        perform {
                            model.enterSession(session)
                        }
                    }
                    .disabled(model.busy)
                    if session.running {
                        Button("Stop \(session.display) \(session.name)") {
                            perform {
                                model.stopSession(session)
                            }
                        }
                        .disabled(model.busy)
                    }
                }
            }

            Divider()
            Button("Refresh Sessions") {
                perform {
                    model.refresh()
                }
            }
            .disabled(model.busy)

            Button("Pass Mic: \(model.microphonePassthroughEnabled ? "ON" : "OFF")") {
                perform {
                    model.toggleMicrophonePassthrough()
                }
            }
            .disabled(model.audioBusy)

            Button("Reconnect") {
                perform {
                    NotificationCenter.default.post(name: .vegpuReconnectDisplay, object: nil)
                }
            }

            Button("Fallback: Switch to SPICE") {
                perform {
                    model.switchToSpice()
                }
            }
            .disabled(model.busy)
        }
        .onAppear {
            model.refreshAudioBridgeStatus()
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
