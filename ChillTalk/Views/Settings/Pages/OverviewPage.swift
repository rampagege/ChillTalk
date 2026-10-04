import AppKit
import ServiceManagement
import SwiftUI

struct OverviewPage: View {
    @EnvironmentObject private var model: SettingsModel
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var navigation: SettingsNavigation
    @State private var interfaceLanguage = InterfaceLanguage.current
    @State private var needsRestart = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemNote: String?

    var body: some View {
        SettingsPageView(title: String(localized: "概览"), subtitle: String(localized: "按一下快捷键开始说话，再按一下结束，文字会出现在光标处。")) {
            Card {
                HStack(spacing: 20) {
                    KeycapRow(preset: model.hotkeyPreset, large: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("按一下开始说话")
                            .font(.system(size: 15, weight: .semibold))
                        Text("再按一下结束 · 录音或处理中按 Esc 取消")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("更换") { navigation.page = .hotkey }
                        .buttonStyle(BrandButtonStyle(prominent: false))
                }
                .padding(20)
            }

            HStack(spacing: 12) {
                let today = history.usage()
                let month = history.monthUsage()
                StatTile(title: String(localized: "今日次数"), value: "\(today.count)", unit: String(localized: "次"))
                StatTile(title: String(localized: "今日字数"), value: today.characters.formatted(), unit: String(localized: "字"))
                StatTile(title: String(localized: "本月费用"), value: String(format: "%.2f", month.estimatedCostYuan), unit: String(localized: "元 · 估算"))
            }

            Card(title: String(localized: "最近")) {
                let recent = Array(history.displayRecords.prefix(3))
                if recent.isEmpty {
                    Text(history.isHistoryEnabled ? String(localized: "还没有记录，试着说一句话吧。") : String(localized: "历史记录已关闭。"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { CardDivider() }
                        RecentRow(record: record)
                    }
                    CardDivider()
                    Button {
                        navigation.page = .history
                    } label: {
                        HStack {
                            Text("查看全部")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Brand.mint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Card {
                CardRow(label: String(localized: "登录时启动"),
                        detail: loginItemNote ?? String(localized: "开机登录后自动在菜单栏运行")) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                }
                CardDivider()
                CardRow(label: String(localized: "界面语言"),
                        detail: needsRestart ? String(localized: "重启 ChillTalk 后生效") : nil) {
                    HStack(spacing: 8) {
                        if needsRestart {
                            Button(String(localized: "立即重启")) { InterfaceLanguage.relaunch() }
                                .buttonStyle(BrandButtonStyle())
                        }
                        Picker("", selection: $interfaceLanguage) {
                            ForEach(InterfaceLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                        .onChange(of: interfaceLanguage) {
                            interfaceLanguage.apply()
                            needsRestart = true
                        }
                    }
                }
            }
        }
    }
}

extension OverviewPage {
    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            loginItemNote = error.localizedDescription
        }
        if service.status == .requiresApproval {
            // The user has to allow it once in System Settings → Login Items.
            loginItemNote = String(localized: "请在系统设置的「登录项」中允许 ChillTalk")
            SMAppService.openSystemSettingsLoginItems()
        }
        launchAtLogin = service.status == .enabled || service.status == .requiresApproval
    }
}

/// App UI language: follow macOS, or override it for ChillTalk only (applies on relaunch).
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case zhHans = "zh-Hans"
    case en
    case zhHant = "zh-Hant"
    case ja
    case ko

    var id: String { rawValue }

    /// Native names, so people can find their language whatever the UI is showing.
    var displayName: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    static var current: InterfaceLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let code = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return allCases.first { !$0.rawValue.isEmpty && code.hasPrefix($0.rawValue) } ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        // The new instance quits this one on launch (single-instance guard).
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.hairline))
    }
}

/// Single-line history entry; click copies the inserted text.
struct RecentRow: View {
    let record: DictationRecord
    @State private var isHovered = false
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(record.displayText)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 12) {
                Text(record.date, format: .dateTime.hour().minute())
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)
                Text(record.displayText)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Label(copied ? String(localized: "已复制") : String(localized: "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(copied ? Brand.mint : .secondary)
                    .opacity(isHovered || copied ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovered ? Brand.hairline : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
