import SwiftUI

enum AppTheme {
    static func tint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.63, green: 0.59, blue: 0.52) : Color(red: 0.11, green: 0.105, blue: 0.095)
    }

    static func windowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.055, green: 0.052, blue: 0.048) : Color(nsColor: .windowBackgroundColor)
    }

    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.071, blue: 0.066) : Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    static func panelBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.105, green: 0.099, blue: 0.091) : Color(nsColor: .controlBackgroundColor)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.095, green: 0.09, blue: 0.083) : Color(nsColor: .windowBackgroundColor)
    }

    static func selectedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.19, green: 0.18, blue: 0.165) : Color.primary
    }

    static func selectedForeground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.94, green: 0.91, blue: 0.84) : Color(nsColor: .windowBackgroundColor)
    }

    static func border(_ scheme: ColorScheme, opacity: Double = 1) -> Color {
        let base = scheme == .dark ? Color(red: 0.29, green: 0.27, blue: 0.24) : Color(nsColor: .separatorColor)
        return base.opacity(opacity)
    }

    static func logoBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.15, green: 0.14, blue: 0.125) : Color(nsColor: .windowBackgroundColor)
    }

    static func dangerFill(_ scheme: ColorScheme, pressed: Bool) -> Color {
        if scheme == .dark {
            return pressed ? Color(red: 0.55, green: 0.08, blue: 0.06) : Color(red: 0.72, green: 0.10, blue: 0.075)
        }
        return pressed ? Color(red: 0.63, green: 0.12, blue: 0.08) : Color(red: 0.82, green: 0.14, blue: 0.10)
    }
}

struct DangerButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(AppTheme.dangerFill(colorScheme, pressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
