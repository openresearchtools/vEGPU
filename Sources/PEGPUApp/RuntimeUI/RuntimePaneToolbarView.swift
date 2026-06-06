import SwiftUI
import PEGPUCore

struct RuntimePaneToolbarView: View {
    let model: NativeAppModel
    @ObservedObject var navigation: RuntimeNavigationState
    @ObservedObject var terminal: RuntimeTerminalState
    @Environment(\.colorScheme) private var colorScheme
    @State private var passwordVisible = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            compactLayout
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.panelBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border(colorScheme, opacity: 0.6), lineWidth: 1))
    }

    private var wideLayout: some View {
        HStack(spacing: 16) {
            RuntimePaneSelector(navigation: navigation)
            Divider()
                .frame(height: 28)
            linuxUserLabel
            PasswordControlsView(model: model, terminal: terminal, passwordVisible: $passwordVisible)
            Spacer(minLength: 10)
            terminalButtons
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RuntimePaneSelector(navigation: navigation)
                Spacer(minLength: 8)
                terminalButtons
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    linuxUserLabel
                    PasswordControlsView(model: model, terminal: terminal, passwordVisible: $passwordVisible)
                }
                .padding(.vertical, 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var linuxUserLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Linux user")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(SSHClient.user)
                .font(.subheadline.weight(.semibold))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var terminalButtons: some View {
        HStack(spacing: 10) {
            Button {
                model.openTerminal()
            } label: {
                HitTargetLabel("Open Terminal", minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            Button {
                model.closeTerminal()
            } label: {
                HitTargetLabel("Close", minWidth: 52)
            }
            .disabled(!terminal.terminalConnected)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RuntimePaneSelector: View {
    @ObservedObject var navigation: RuntimeNavigationState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(NativeAppModel.RuntimePane.allCases) { pane in
                Button {
                    navigation.runtimePane = pane
                } label: {
                    Text(pane.rawValue)
                        .frame(minWidth: 86, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(navigation.runtimePane == pane ? .semibold : .regular))
                .background(navigation.runtimePane == pane ? AppTheme.selectedBackground(colorScheme) : Color.clear)
                .foregroundStyle(navigation.runtimePane == pane ? AppTheme.selectedForeground(colorScheme) : .primary)
                .contentShape(Rectangle())
                if pane != NativeAppModel.RuntimePane.allCases.last {
                    Divider()
                        .frame(height: 18)
                }
            }
        }
        .background(AppTheme.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppTheme.border(colorScheme, opacity: 0.5), lineWidth: 1))
    }
}

private struct PasswordControlsView: View {
    let model: NativeAppModel
    @ObservedObject var terminal: RuntimeTerminalState
    @Binding var passwordVisible: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingChangePassword = false

    var body: some View {
        HStack(spacing: 8) {
            Text(passwordVisible ? terminal.linuxPassword : maskedPassword(terminal.linuxPassword))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AppTheme.cardBackground(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(AppTheme.border(colorScheme, opacity: 0.5), lineWidth: 1))
            Button {
                passwordVisible.toggle()
            } label: {
                HitTargetLabel(passwordVisible ? "Hide" : "Reveal", minWidth: 58)
            }
            Button {
                model.copyLinuxPassword()
            } label: {
                HitTargetLabel("Copy", minWidth: 52)
            }
            Button {
                showingChangePassword = true
            } label: {
                HitTargetLabel("Change", minWidth: 64)
            }
            Button {
                model.sendLinuxPassword()
            } label: {
                HitTargetLabel("Send", minWidth: 52)
            }
        }
        .sheet(isPresented: $showingChangePassword) {
            ChangeLinuxPasswordSheet(
                currentPassword: terminal.linuxPassword,
                onCancel: { showingChangePassword = false },
                onSave: { password in
                    passwordVisible = true
                    showingChangePassword = false
                    model.changeLinuxPassword(password)
                }
            )
        }
    }

    private func maskedPassword(_ password: String) -> String {
        password.isEmpty ? "••••••••••••••••" : String(repeating: "•", count: min(24, max(12, password.count)))
    }
}

private struct ChangeLinuxPasswordSheet: View {
    let currentPassword: String
    let onCancel: () -> Void
    let onSave: (String) -> Void
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change Linux Password")
                    .font(.title3.weight(.semibold))
                Text("Updates the saved Runtime password and, when the VM is running, the Linux \(SSHClient.user) account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                passwordField("New password", text: $newPassword)
                passwordField("Confirm password", text: $confirmPassword)
                Toggle("Show password", isOn: $showPassword)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Use Current") {
                    newPassword = currentPassword
                    confirmPassword = currentPassword
                }
                .disabled(currentPassword.isEmpty)
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                Button("Change Password") {
                    onSave(newPassword)
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(AppTheme.panelBackground(colorScheme))
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if showPassword {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(title, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var validationMessage: String? {
        if newPassword.isEmpty || confirmPassword.isEmpty { return "Enter and confirm the new password." }
        if newPassword.count < 8 { return "Password must be at least 8 characters." }
        if newPassword.contains(":") { return "Password cannot contain ':'." }
        if newPassword.rangeOfCharacter(from: .newlines) != nil { return "Password cannot contain line breaks." }
        if newPassword != confirmPassword { return "Passwords do not match." }
        return nil
    }
}
