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
            Button("Refresh GUI Status") {
                perform {
                    model.refresh()
                }
            }
            .disabled(model.busy)

            Button("Reload vEGPU GUI Display") {
                perform {
                    model.reload()
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

            Button("Return to vEGPU GUI") {
                perform {
                    model.releaseSession()
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
