import SwiftUI

struct SyncPage: View {
    @EnvironmentObject private var sync: SyncService

    var body: some View {
        SettingsPageView(title: String(localized: "同步"), subtitle: String(localized: "通过 iCloud 云盘在你的多台 Mac 之间同步。API 密钥不会同步，需在每台 Mac 上分别填写。")) {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 18))
                        .foregroundStyle(statusColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .medium))
                        Text(statusDetail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("立即同步") { sync.syncNow() }
                        .buttonStyle(BrandButtonStyle(prominent: false))
                        .disabled(!sync.isAvailable || !sync.isAnyEnabled || sync.status == .syncing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Card(title: String(localized: "同步内容")) {
                toggleRow(.vocabulary, label: String(localized: "词库"), detail: String(localized: "词条、错误写法、重点词、背景说明；以最后修改为准，删除也会同步"))
                CardDivider()
                toggleRow(.settings, label: String(localized: "设置"), detail: String(localized: "服务商、模型、快捷键、润色和输出选项；不含 API 密钥"))
                CardDivider()
                toggleRow(.usage, label: String(localized: "用量统计"), detail: String(localized: "各台 Mac 的次数、字数、费用合计显示"))
                CardDivider()
                toggleRow(.history, label: String(localized: "历史记录"), detail: String(localized: "本机记录同步到 iCloud；其他 Mac 的记录在本机只读"))
                if sync.enabled[.history] == true {
                    CardDivider()
                    CardRow(label: String(localized: "合并显示其他 Mac 的记录"), detail: String(localized: "关闭后历史里只显示本机记录，本机记录仍会同步")) {
                        Toggle("", isOn: $sync.mergeHistory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    .padding(.leading, 20)
                }
            }
            .disabled(!sync.isAvailable)
            .opacity(sync.isAvailable ? 1 : 0.5)

            if !sync.otherDevices.isEmpty {
                Card(title: String(localized: "其他 Mac")) {
                    ForEach(Array(sync.otherDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { CardDivider() }
                        HStack(spacing: 12) {
                            Image(systemName: "laptopcomputer")
                                .foregroundStyle(.secondary)
                            Text(device.name)
                                .font(.system(size: 13))
                            Spacer()
                            Text("上次同步 ") + Text(device.updatedAt, style: .relative) + Text("前")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func toggleRow(_ kind: SyncService.Kind, label: String, detail: String) -> some View {
        CardRow(label: label, detail: detail) {
            Toggle("", isOn: Binding(
                get: { sync.enabled[kind] == true },
                set: { sync.enabled[kind] = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var statusIcon: String {
        switch sync.status {
        case .unavailable: return "icloud.slash"
        case .off: return "icloud"
        case .idle: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .failed: return "exclamationmark.icloud"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .unavailable, .failed: return Brand.warning
        case .off: return .secondary
        case .idle, .syncing: return Brand.mint
        }
    }

    private var statusTitle: String {
        switch sync.status {
        case .unavailable: return String(localized: "未开启 iCloud 云盘")
        case .off: return String(localized: "同步已关闭")
        case .idle: return String(localized: "已同步")
        case .syncing: return String(localized: "正在同步…")
        case .failed: return String(localized: "同步失败")
        }
    }

    private var statusDetail: String {
        switch sync.status {
        case .unavailable:
            return String(localized: "在 系统设置 → Apple 账户 → iCloud 中打开「iCloud 云盘」后即可使用。")
        case .off:
            return String(localized: "打开下面任意一项即开始同步。数据存放在 iCloud 云盘的 ChillTalk 文件夹。")
        case .idle(let date):
            let time = date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—"
            return String(localized: "本机：\(sync.deviceName) · 上次同步 \(time) · 已发现 \(sync.otherDevices.count) 台其他 Mac")
        case .syncing:
            return String(localized: "本机：\(sync.deviceName)")
        case .failed(let message):
            return message
        }
    }
}
