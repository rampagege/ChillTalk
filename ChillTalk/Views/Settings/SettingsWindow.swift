import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, asr, polish, hotkey, history, vocabulary, sync, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return String(localized: "概览")
        case .asr: return String(localized: "语音识别")
        case .polish: return String(localized: "文字润色")
        case .hotkey: return String(localized: "快捷键")
        case .history: return String(localized: "历史")
        case .vocabulary: return String(localized: "词库")
        case .sync: return String(localized: "同步")
        case .permissions: return String(localized: "权限")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .asr: return "waveform"
        case .polish: return "wand.and.stars"
        case .hotkey: return "command"
        case .history: return "clock.arrow.circlepath"
        case .vocabulary: return "character.book.closed"
        case .sync: return "icloud"
        case .permissions: return "lock.shield"
        }
    }
}

/// Owns the branded settings window (replaces SwiftUI's native `Settings` scene).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var appState: AppState?
    private let model = SettingsModel()
    private let navigation = SettingsNavigation()

    func configure(appState: AppState) {
        self.appState = appState
    }

    func show(page: SettingsPage? = nil) {
        if let page = page { navigation.page = page }
        if window == nil { createWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func createWindow() {
        guard let appState = appState else { return }
        let root = SettingsRootView()
            .environmentObject(model)
            .environmentObject(navigation)
            .environmentObject(appState)
            .environmentObject(HistoryStore.shared)
            .environmentObject(VocabularyStore.shared)
            .environmentObject(SyncService.shared)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.title = String(localized: "ChillTalk 设置")
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ChillTalkSettings")
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        model.flushPendingSaves()
        // Drop the whole SwiftUI hierarchy instead of keeping it alive while hidden; the
        // window is rebuilt (quickly) the next time settings are opened.
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentView = nil
            self?.window = nil
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .overview
}

struct SettingsRootView: View {
    @EnvironmentObject private var navigation: SettingsNavigation

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 200)
            Rectangle()
                .fill(Brand.hairline)
                .frame(width: 1)
            Group {
                switch navigation.page {
                case .overview: OverviewPage()
                case .asr: ASRPage()
                case .polish: PolishPage()
                case .hotkey: HotkeyPage()
                case .history: HistoryPage()
                case .vocabulary: VocabularyPage()
                case .sync: SyncPage()
                case .permissions: PermissionsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Brand.content)
        }
        .tint(Brand.mint)
        .ignoresSafeArea()
    }
}

struct SettingsSidebar: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @EnvironmentObject private var appState: AppState
    @StateObject private var permissions = PermissionStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear the traffic-light buttons.
            Color.clear.frame(height: 44)

            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Brand.mint)
                        .frame(width: 30, height: 30)
                    ChillWave()
                        .stroke(Brand.onMint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .frame(width: 17, height: 7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChillTalk")
                        .font(.system(size: 14, weight: .semibold))
                    HStack(spacing: 5) {
                        StatusDot(color: statusColor)
                        Text(appState.recordingState.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)

            VStack(spacing: 2) {
                ForEach(SettingsPage.allCases) { page in
                    SidebarItem(page: page, isSelected: navigation.page == page) {
                        navigation.page = page
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            if permissions.missingCount > 0 {
                Button {
                    navigation.page = .permissions
                } label: {
                    Label("缺少 \(permissions.missingCount) 项权限", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Brand.warning)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Brand.sidebar)
    }

    private var statusColor: Color {
        switch appState.recordingState {
        case .idle: return Brand.mint
        case .recording: return Brand.danger
        case .processing: return Brand.warning
        case .error: return Brand.danger
        }
    }
}

private struct SidebarItem: View {
    let page: SettingsPage
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Brand.mint : .secondary)
                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Brand.mintSoft : (isHovered ? Brand.hairline : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Live permission state; refreshes whenever the app becomes active (e.g. after the user
/// returns from System Settings).
@MainActor
final class PermissionStatus: ObservableObject {
    @Published private(set) var microphone = false
    @Published private(set) var accessibility = false
    private var observer: NSObjectProtocol?

    var missingCount: Int { [microphone, accessibility].filter { !$0 }.count }

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let pm = PermissionManager.shared
        microphone = pm.hasMicrophonePermission()
        accessibility = pm.hasAccessibilityPermission()
    }
}
