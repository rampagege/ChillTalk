import SwiftUI

struct PermissionsPage: View {
    @StateObject private var status = PermissionStatus()

    var body: some View {
        SettingsPageView(title: String(localized: "权限"), subtitle: String(localized: "在系统设置里授权后回到这里，状态会自动刷新。")) {
            Card {
                PermissionRow(
                    icon: "mic.fill",
                    title: String(localized: "麦克风"),
                    detail: String(localized: "录制你的语音。必需。"),
                    granted: status.microphone,
                    action: { PermissionManager.shared.checkMicrophonePermission() }
                )
                CardDivider()
                PermissionRow(
                    icon: "accessibility",
                    title: String(localized: "辅助功能"),
                    detail: String(localized: "把文字粘贴到当前输入框、监听快捷键。必需；授权后可能需要重启 ChillTalk。"),
                    granted: status.accessibility,
                    action: { PermissionManager.shared.checkAccessibilityPermission() }
                )
            }
        }
        .onAppear { status.refresh() }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(granted ? Brand.mintSoft : Brand.field)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(granted ? Brand.mint : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.mint)
            } else {
                Button("去授权", action: action)
                    .buttonStyle(BrandButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
