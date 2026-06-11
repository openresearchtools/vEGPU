import SwiftUI
import PEGPUCore

struct ManageMachinesView: View {
    @ObservedObject var model: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var removalProfile: MachineProfile?

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

            if let message = model.machineProfileMessage,
               message != "VM is running. Stop VM first." {
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
                        Button("Remove...") {
                            removalProfile = profile
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
                    Button("New in App Support") {
                        model.createDefaultMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .help("Create a fresh VM profile under ~/Library/Application Support/PEGPU/Machines.")
                    Button("New at Folder") {
                        model.createCustomMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .help("Create a fresh VM profile in an empty folder you choose.")
                    Button("Add Existing") {
                        model.addExistingMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .help("Register an existing PEGPU VM profile folder.")
                    Button("Copy") {
                        model.copySelectedMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .disabled(selectedID == nil)
                    .help("Copy the selected VM profile folder and register the copy.")
                    Button("Move") {
                        model.moveSelectedMachineProfile()
                        selectedID = model.pendingMachineID
                    }
                    .disabled(selectedID == nil)
                    .help("Move the selected VM profile folder and update its registered path.")
                }
                .disabled(model.machineProfileLocked)
                Spacer()
                Button("Reveal") {
                    if let profile = selectedProfile {
                        model.revealMachineProfile(profile)
                    }
                }
                .disabled(selectedProfile == nil)
                .help("Show the selected VM profile folder in Finder.")
                Button("Remove") {
                    if let profile = selectedProfile {
                        removalProfile = profile
                    }
                }
                .disabled(selectedProfile == nil)
                .help("Choose whether to remove this VM from the list or delete its files and settings.")
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 420)
        .sheet(item: $removalProfile) { profile in
            MachineProfileRemovalView(
                profile: profile,
                cancel: {
                    removalProfile = nil
                },
                confirm: { deleteFiles in
                    if model.removeMachineProfile(profile, deleteFiles: deleteFiles) {
                        selectedID = model.pendingMachineID
                        removalProfile = nil
                    }
                }
            )
        }
    }

    private var selectedProfile: MachineProfile? {
        let id = selectedID ?? model.pendingMachineID
        return model.machineProfiles.first { $0.id == id }
    }
}

private struct MachineProfileRemovalView: View {
    let profile: MachineProfile
    let cancel: () -> Void
    let confirm: (Bool) -> Void
    @State private var deleteFiles = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(profile.name)?")
                .font(.title3.weight(.semibold))

            Text("Removing from the list keeps the VM folder on disk so it can be added again later.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("VM folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(profile.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .textColor))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.cardBackground(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border(colorScheme, opacity: 0.7), lineWidth: 1))
            }

            Toggle("Also delete this VM and its settings from disk", isOn: $deleteFiles)
                .toggleStyle(.checkbox)

            if deleteFiles {
                Text("This permanently deletes the VM folder, disk image, saved settings, secrets, and host runtime state. This does not move files to Trash.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    cancel()
                }
                Button("Remove from List") {
                    confirm(false)
                }
                Button("Delete VM and Settings") {
                    confirm(true)
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(!deleteFiles)
            }
        }
        .padding(20)
        .frame(width: 520)
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
