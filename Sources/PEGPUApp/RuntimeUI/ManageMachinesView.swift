import SwiftUI
import PEGPUCore

struct ManageMachinesView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage VMs")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            if model.machineProfileLocked {
                Text("VM is running. Stop VM first.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if let message = model.machineProfileMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            List(selection: $selectedID) {
                ForEach(model.machineProfiles) { profile in
                    MachineProfileRow(
                        profile: profile,
                        selected: profile.id == model.pendingMachineID,
                        missing: !FileManager.default.fileExists(atPath: profile.path)
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            model.revealMachineProfile(profile)
                        }
                        Button("Remove from List") {
                            model.removeMachineProfileFromList(profile)
                        }
                    }
                }
            }
            .frame(minHeight: 240)
            .onAppear {
                selectedID = model.pendingMachineID
                model.refreshMachineProfiles()
            }
            .onChange(of: selectedID) { _, id in
                guard let id, id != model.pendingMachineID else { return }
                model.switchMachineProfile(id: id)
            }

            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button("Create Default") {
                        model.createDefaultMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    Button("Create Custom") {
                        model.createCustomMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    Button("Add Existing") {
                        model.addExistingMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    Button("Copy") {
                        model.copySelectedMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .disabled(selectedID == nil)
                    Button("Move") {
                        model.moveSelectedMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .disabled(selectedID == nil)
                }
                .disabled(model.machineProfileLocked)
                Spacer()
                Button("Reveal") {
                    if let profile = selectedProfile {
                        model.revealMachineProfile(profile)
                    }
                }
                .disabled(selectedProfile == nil)
                Button("Remove") {
                    if let profile = selectedProfile {
                        model.removeMachineProfileFromList(profile)
                        selectedID = model.pendingMachineID
                    }
                }
                .disabled(selectedProfile == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 420)
    }

    private var selectedProfile: MachineProfile? {
        let id = selectedID ?? model.pendingMachineID
        return model.machineProfiles.first { $0.id == id }
    }
}

private struct MachineProfileRow: View {
    let profile: MachineProfile
    let selected: Bool
    let missing: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.headline)
                    if selected {
                        Text("Selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if missing {
                        Text("Missing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                Text(profile.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
