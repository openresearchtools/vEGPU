import SwiftUI

struct NvidiaInstallConfirmView: View {
    let model: NativeAppModel
    @Binding var isPresented: Bool
    @State private var confirmed = false
    @State private var showInfo = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(NvidiaInstallCopy.modalTitle)
                    .font(.title3.weight(.semibold))
                Button {
                    showInfo.toggle()
                } label: {
                    CircleHitTargetLabel("i", size: 22)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showInfo) {
                    Text(NvidiaInstallCopy.modalInfo)
                        .font(.caption)
                        .padding(12)
                        .frame(width: 280)
                }
                Spacer()
            }

            Text(NvidiaInstallCopy.ownershipNotice)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(NvidiaInstallCopy.installNotice)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Debian command preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Text(NvidiaInstallCopy.commandPreview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .textColor))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 116)
            .background(AppTheme.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border(colorScheme, opacity: 0.7), lineWidth: 1))

            Toggle(NvidiaInstallCopy.acknowledgement, isOn: $confirmed)
                .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                Button("Install Driver") {
                    isPresented = false
                    model.installNvidiaStack()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmed)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
