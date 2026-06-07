import SwiftUI
import PEGPUCore

struct RuntimeToolbarView: View {
    @ObservedObject var model: NativeAppModel
    @Binding var config: MachineConfig
    @Environment(\.colorScheme) private var colorScheme
    @State private var cpuText = ""
    @State private var memoryText = ""
    @State private var showResetConfirm = false

    var body: some View {
        WrappingHStackLayout(spacing: 10, rowSpacing: 8) {
            if model.showDeveloperOptions {
                modePicker
                if config.launchMode == .gui {
                    retinaToggle
                }
            }
            configControls
            Divider()
                .frame(width: 1, height: 24)
            if model.showDeveloperOptions {
                shareButton
                saveButton
            }
            startButton
            stopButton
            if model.showDeveloperOptions {
                doctorButton
            }
            resetButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppTheme.windowBackground(colorScheme))
        .onAppear(perform: syncTextFields)
        .onChange(of: config) { _, _ in syncTextFields() }
        .onChange(of: config.launchMode) { _, mode in
            model.runtimeLaunchMode = mode
        }
        .onChange(of: config.guiRetina) { _, enabled in
            model.guiRetina = enabled
        }
        .confirmationDialog(
            "Reset this VM?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Runtime", role: .destructive) {
                commitTextFields()
                model.resetRuntime(config: config)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This terminates QEMU, deletes the VM disk and state, then prepares a clean runtime disk.")
        }
    }

    private var configControls: some View {
        HStack(spacing: 10) {
            HeaderNumberField(title: "CPU", placeholder: "Auto", text: $cpuText, width: 64)
            HeaderNumberField(title: "RAM", placeholder: "8192", text: $memoryText, width: 82)
            Text("MiB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $config.launchMode) {
            ForEach(RuntimeLaunchMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 124)
        .help("Runtime launch mode. Changes apply on the next start.")
    }

    private var retinaToggle: some View {
        Toggle("Retina", isOn: Binding(
            get: { config.guiRetina },
            set: { enabled in
                config.guiRetina = enabled
                model.setGuiRetina(enabled)
            }
        ))
        .toggleStyle(.switch)
        .fixedSize()
        .help("GUI display resolution. On requests backing-pixel Retina resolution; off requests logical window size.")
    }

    private var shareButton: some View {
        Button {
            if let selected = model.chooseShareRoot(current: config.shareRoot) {
                commitTextFields()
                config.shareRoot = selected
                model.saveRuntimeConfig(config)
            }
        } label: {
            HitTargetLabel("Share", minWidth: 52)
        }
        .help("Share: \(config.shareRoot)")
    }

    private var saveButton: some View {
        Button {
            commitTextFields()
            model.saveRuntimeConfig(config)
        } label: {
            HitTargetLabel("Save", minWidth: 48)
        }
    }

    private var startButton: some View {
        Button {
            commitTextFields()
            model.startRuntime(config: config)
        } label: {
            HitTargetLabel("Start Server", minWidth: 94)
        }
        .keyboardShortcut(.return, modifiers: [.command])
    }

    private var stopButton: some View {
        Button {
            model.stopRuntime()
        } label: {
            HitTargetLabel("Stop Server", minWidth: 88)
        }
    }

    private var doctorButton: some View {
        Button {
            model.doctorRuntime()
        } label: {
            HitTargetLabel("Doctor", minWidth: 62)
        }
    }

    private var resetButton: some View {
        Button {
            showResetConfirm = true
        } label: {
            HitTargetLabel("Reset", minWidth: 56)
        }
        .buttonStyle(DangerButtonStyle())
    }

    private func syncTextFields() {
        cpuText = config.cpuMode == .auto ? "" : String(config.cpuCount)
        memoryText = String(config.memoryMiB)
    }

    private func commitTextFields() {
        config.guiAppearance = colorScheme == .dark ? .dark : .light
        let cpu = Int(cpuText.trimmingCharacters(in: .whitespacesAndNewlines))
        config.cpuMode = cpu == nil ? .auto : .manual
        if let cpu {
            config.cpuCount = min(max(cpu, 1), ProcessInfo.processInfo.processorCount)
        }
        if let memory = Int(memoryText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            config.memoryMiB = min(max(memory, 1024), 262_144)
        }
    }
}

private struct HeaderNumberField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(width: width)
        }
    }
}
