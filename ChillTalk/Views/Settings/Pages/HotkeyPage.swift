import SwiftUI

struct HotkeyPage: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        SettingsPageView(title: String(localized: "快捷键"), subtitle: String(localized: "全局可用，在任何应用里都能开始说话。")) {
            Card {
                VStack(spacing: 14) {
                    KeycapRow(preset: model.hotkeyPreset, large: true)
                    Text("按一下开始 · 再按一下结束 · Esc 取消")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                CardDivider()
                CardRow(label: String(localized: "快捷键"), savedKey: "hotkeyPreset") {
                    Picker("", selection: $model.hotkeyPreset) {
                        ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 260)
                }
                if let note = model.hotkeyPreset.conflictNote {
                    CardDivider()
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }

            Card(title: String(localized: "提示")) {
                TipRow(icon: "hand.tap", text: String(localized: "单个修饰键（如右 ⌥）需要单独轻按才会触发：按住它再按其他键（⌥ 输入特殊字符、⌘C 等）不会开始录音。"))
                CardDivider()
                TipRow(icon: "doc.on.clipboard", text: String(localized: "没有选中输入框时，结果会保留在剪贴板；菜单栏「复制上次结果」也能找回。"))
                CardDivider()
                TipRow(icon: "arrow.uturn.backward", text: String(localized: "处理中再按快捷键不会开始新的录音，按 Esc 可以取消。"))
            }
        }
    }
}

private struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Brand.mint)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
