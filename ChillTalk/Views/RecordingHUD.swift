import SwiftUI
import AppKit

/// Floating HUD on the screen being typed on, bottom center by default. The user can drag it
/// while it's up; each screen remembers where it was dragged to. All methods except the two high-frequency updaters must be
/// called on the main thread.
class RecordingHUDController: ObservableObject {
    enum Mode {
        case recording
        case processing
        case message(isError: Bool)
    }

    /// The panel never resizes (a SwiftUI-driven resize anchors at the top-left and pushed
    /// the HUD into the Dock on first show). The pill is drawn at its bottom and the
    /// rest of the panel is transparent, so clicks there fall through to the apps below.
    private static let panelSize = NSSize(width: 680, height: 180)
    private static let bottomMargin: CGFloat = 16
    /// Space the pill can take inside the panel, including two lines of live text.
    private static let pillZone = NSSize(width: 600, height: 110)
    private static let shadowInset: CGFloat = 12

    private var window: NSWindow?
    /// Set while the HUD positions itself, so only the user's drags are remembered.
    private var isPositioning = false
    private var hideWorkItem: DispatchWorkItem?
    @Published var isVisible: Bool = false
    @Published var mode: Mode = .recording
    @Published var message: String = ""
    @Published var liveTranscript: String = ""
    @Published var audioLevel: Double = 0.0
    /// The dictation is a spoken correction of the last insertion.
    @Published var isCorrecting = false

    static let shared = RecordingHUDController()

    private init() {}

    func show(state: RecordingState) {
        switch state {
        case .recording:
            mode = .recording
            liveTranscript = ""
        case .processing:
            // Keep the transcript on screen while the final result is prepared.
            mode = .processing
            audioLevel = 0.0
        case .error:
            mode = .message(isError: true)
        case .idle:
            hide()
            return
        }
        present()
    }

    /// Shows a transient message (error or notice) that hides itself.
    func flash(_ message: String, isError: Bool, duration: TimeInterval = 2.5) {
        self.message = message
        mode = .message(isError: isError)
        liveTranscript = ""
        audioLevel = 0.0
        present()

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func updateLiveTranscript(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }
            switch self.mode {
            case .recording, .processing: self.liveTranscript = text
            case .message: break
            }
        }
    }

    func updateAudioLevel(_ level: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, case .recording = self.mode, self.isVisible else { return }
            self.audioLevel = level
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isVisible = false
        liveTranscript = ""
        audioLevel = 0.0
        window?.orderOut(nil)
    }

    private func present() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        if window == nil {
            createWindow()
        }
        // Keep the position while a dictation's HUD is already up.
        if !isVisible { positionOnActiveScreen() }
        isVisible = true
        window?.orderFrontRegardless()
    }

    private func createWindow() {
        let hostingView = DraggableHostingView(rootView: RecordingHUDView().environmentObject(self))
        hostingView.frame = NSRect(origin: .zero, size: Self.panelSize)
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hasShadow = false  // The pill draws its own shadow; a window shadow outlines the whole panel
        // ignoresMouseEvents stays at its default: clicks on the pill drag it, clicks on the
        // transparent rest pass through (setting it to false would capture those too). A
        // non-activating panel never takes focus from the app being typed in.

        // performDrag returns before the drag ends, so remember the position as it moves.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self, !self.isPositioning else { return }
            self.saveDraggedPosition(panel.frame.origin)
        }

        self.window = panel
    }

    /// Where the pill is drawn for a panel at `origin`.
    private static func pillRect(origin: NSPoint) -> NSRect {
        NSRect(x: origin.x + (panelSize.width - pillZone.width) / 2, y: origin.y + shadowInset,
               width: pillZone.width, height: pillZone.height)
    }

    /// The screen being typed on: the one with the frontmost app's front window, else the
    /// one with the mouse.
    private static func activeScreen() -> NSScreen? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let front = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let boundsDict = front[kCGWindowBounds as String] as? NSDictionary,
           let bounds = CGRect(dictionaryRepresentation: boundsDict),
           let primaryHeight = NSScreen.screens.first?.frame.maxY {
            // Window bounds use a top-left origin on the primary screen.
            let center = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) { return screen }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// The spot the user dragged it to on this screen, otherwise bottom center, just above the Dock.
    private func positionOnActiveScreen() {
        guard let window = window, let screen = Self.activeScreen() else { return }
        let visible = screen.visibleFrame
        let origin: NSPoint
        if let id = screen.displayUUID, let saved = SettingsManager.shared.hudPosition(onScreen: id),
           visible.intersects(Self.pillRect(origin: saved)) {
            origin = saved
        } else {
            origin = NSPoint(x: (visible.midX - Self.panelSize.width / 2).rounded(),
                             y: (visible.minY + Self.bottomMargin).rounded())
        }
        isPositioning = true
        window.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
        isPositioning = false
    }

    /// Remembers a dragged position for the screen the pill ended up on.
    private func saveDraggedPosition(_ origin: NSPoint) {
        let pill = Self.pillRect(origin: origin)
        let center = NSPoint(x: pill.midX, y: pill.midY)
        guard let id = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })?.displayUUID else { return }
        SettingsManager.shared.setHUDPosition(origin, onScreen: id)
    }
}

private extension NSScreen {
    /// Stable across reboots and reconnects, unlike the display number.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Dragging the pill moves the HUD panel.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct RecordingHUDView: View {
    @EnvironmentObject var controller: RecordingHUDController

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if controller.isVisible {
                pill
                    .transition(.opacity)
            }
        }
        // The pill hugs its content; this padding caps its width at panel width - 80.
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.15), value: controller.isVisible)
    }

    private var pill: some View {
        HStack(alignment: .center, spacing: 12) {
            leadingIndicator
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.system(size: 14))
                    .foregroundColor(primaryIsPlaceholder ? .white.opacity(0.5) : .white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = hintText {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.88))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        )
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch controller.mode {
        case .recording:
            HStack(spacing: 2.5) {
                ForEach(0..<5) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 3, height: barHeight(for: index))
                }
            }
            .animation(.easeOut(duration: 0.1), value: controller.audioLevel)
        case .processing:
            ProgressView()
                .controlSize(.small)
                .colorScheme(.dark)
        case .message(let isError):
            Image(systemName: isError ? "exclamationmark.circle.fill" : "info.circle.fill")
                .font(.system(size: 18))
                .foregroundColor(isError ? .orange : .white.opacity(0.85))
        }
    }

    private var primaryIsPlaceholder: Bool {
        if case .message = controller.mode { return false }
        return controller.liveTranscript.isEmpty
    }

    private var primaryText: String {
        switch controller.mode {
        case .recording:
            let placeholder = controller.isCorrecting ? String(localized: "说说上一句要怎么改…") : String(localized: "请说话…")
            return controller.liveTranscript.isEmpty ? placeholder : Self.tail(controller.liveTranscript)
        case .processing:
            let placeholder = controller.isCorrecting ? String(localized: "正在修改上一句…") : String(localized: "处理中…")
            return controller.liveTranscript.isEmpty ? placeholder : Self.tail(controller.liveTranscript)
        case .message:
            return controller.message
        }
    }

    private var hintText: String? {
        switch controller.mode {
        case .recording:
            return controller.isCorrecting ? String(localized: "纠正上一句 · 再按快捷键结束 · Esc 取消") : String(localized: "再按快捷键结束 · Esc 取消")
        case .processing:
            guard !controller.liveTranscript.isEmpty else { return nil }
            return controller.isCorrecting ? String(localized: "正在修改上一句… · Esc 取消") : String(localized: "处理中… · Esc 取消")
        case .message: return nil
        }
    }

    /// Long dictation: show only the latest words (about two lines). SwiftUI's
    /// `.truncationMode(.head)` only applies to the last line of multi-line text.
    private static func tail(_ text: String, maxCharacters: Int = 72) -> String {
        guard text.count > maxCharacters else { return text }
        return "…" + text.suffix(maxCharacters)
    }
    
    /// VU-meter bars, tallest in the middle.
    private func barHeight(for index: Int) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 22
        guard controller.audioLevel >= 0.02 else { return minHeight }
        let weight = 1.0 - abs(Double(index - 2)) * 0.22
        return minHeight + (maxHeight - minHeight) * CGFloat(controller.audioLevel * weight)
    }
}
