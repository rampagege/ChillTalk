import AppKit
import SwiftUI

/// ChillTalk's own look for the settings window. Colors adapt to light/dark mode;
/// mint is the only accent and is reserved for selection, switches, primary actions
/// and status.
enum Brand {
    static let mint = dynamic(light: (0.07, 0.62, 0.49), dark: (0.36, 0.87, 0.71))
    /// Text on a mint fill: white on the deeper light-mode mint, near-black on the bright dark-mode mint.
    static let onMint = dynamic(light: (1, 1, 1), dark: (0.04, 0.16, 0.12))
    static let mintSoft = dynamic(light: (0.07, 0.62, 0.49, 0.12), dark: (0.36, 0.87, 0.71, 0.16))
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)

    static let sidebar = dynamic(light: (0.925, 0.933, 0.941), dark: (0.082, 0.086, 0.094))
    static let content = dynamic(light: (0.965, 0.969, 0.973), dark: (0.110, 0.114, 0.122))
    static let card = dynamic(light: (1, 1, 1), dark: (0.149, 0.157, 0.169))
    static let field = dynamic(light: (0.955, 0.958, 0.962), dark: (0.192, 0.200, 0.212))
    static let hairline = dynamic(light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.07))

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        dynamic(light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }

    private static func dynamic(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
    }
}

// MARK: - Page & card layout

struct SettingsPageView<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Brand.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 1)
            )
        }
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Brand.hairline)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

/// Label on the left, control on the right; shows a brief "已保存" when `savedKey`
/// matches the model's most recent save.
struct CardRow<Control: View>: View {
    let label: String
    var detail: String? = nil
    var savedKey: String? = nil
    @ViewBuilder var control: Control
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                    if let key = savedKey, model.recentlySaved == key {
                        SavedBadge()
                    }
                }
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.2), value: model.recentlySaved)
    }
}

struct SavedBadge: View {
    var body: some View {
        Label("已保存", systemImage: "checkmark")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Brand.mint)
            .transition(.opacity)
    }
}

// MARK: - Controls

struct BrandTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 260

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.hairline))
    }
}

/// API key field with a show/hide toggle.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 260
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? String(localized: "隐藏") : String(localized: "显示"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.field))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.hairline))
    }
}

struct BrandButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Brand.onMint : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Brand.mint : Brand.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : Brand.hairline)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct Keycap: View {
    let label: String
    var large = false

    var body: some View {
        Text(label)
            .font(.system(size: large ? 20 : 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, large ? 14 : 7)
            .padding(.vertical, large ? 9 : 3)
            .frame(minWidth: large ? 48 : 22)
            .background(
                RoundedRectangle(cornerRadius: large ? 10 : 5, style: .continuous)
                    .fill(Brand.field)
                    .shadow(color: .black.opacity(0.12), radius: 0, y: large ? 2 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: large ? 10 : 5, style: .continuous)
                    .strokeBorder(Brand.hairline)
            )
    }
}

struct KeycapRow: View {
    let preset: HotkeyPreset
    var large = false

    var body: some View {
        HStack(spacing: large ? 8 : 4) {
            ForEach(Array(preset.keycaps.enumerated()), id: \.offset) { index, key in
                if index > 0 {
                    Text("+")
                        .font(.system(size: large ? 14 : 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Keycap(label: key, large: large)
            }
        }
    }
}

/// "测试连接" button with inline result.
struct TestConnectionRow: View {
    let detail: String
    let run: () async -> ConnectionTestResult
    @State private var isRunning = false
    @State private var result: ConnectionTestResult?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                statusLine
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                Task {
                    isRunning = true
                    result = nil
                    result = await run()
                    isRunning = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView().controlSize(.mini)
                    }
                    Text(isRunning ? String(localized: "测试中…") : String(localized: "测试连接"))
                }
            }
            .buttonStyle(BrandButtonStyle(prominent: false))
            .disabled(isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch result {
        case .none:
            Label("尚未测试", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
        case .success(let ms):
            Label("连接正常 · \(ms)ms", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Brand.mint)
                .font(.system(size: 13, weight: .medium))
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Brand.danger)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
