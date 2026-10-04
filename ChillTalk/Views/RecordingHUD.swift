import SwiftUI
import AppKit

/// Bottom-center floating HUD. All methods except the two high-frequency updaters must be
/// called on the main thread.
class RecordingHUDController: ObservableObject {
    enum Mode {
        case recording
        case processing
        case message(isError: Bool)
    }

    /// The panel never resizes (a SwiftUI-driven resize anchors at the top-left and pushed
    /// the HUD into the Dock on first show). The pill is drawn bottom-aligned inside it and
    /// the rest of the panel is transparent and click-through.
    private static let panelSize = NSSize(width: 680, height: 180)
    private static let bottomMargin: CGFloat = 16

    private var window: NSWindow?
    private var hideWorkItem: DispatchWorkItem?
    @Published var isVisible: Bool = false
    @Published var mode: Mode = .recording
    @Published var message: String = ""
    @Published var liveTranscript: String = ""
    @Published var audioLevel: Double = 0.0

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
        positionOnActiveScreen()
        isVisible = true
        window?.orderFrontRegardless()
    }

    private func createWindow() {
        let hostingView = NSHostingView(rootView: RecordingHUDView().environmentObject(self))
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
        panel.isMovableByWindowBackground = false
        panel.hasShadow = false  // The pill draws its own shadow; a window shadow outlines the whole panel
        panel.ignoresMouseEvents = true

        self.window = panel
    }

    /// Bottom-center of the screen the mouse is on, just above the Dock.
    private func positionOnActiveScreen() {
        guard let window = window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: (visible.midX - Self.panelSize.width / 2).rounded(),
                             y: (visible.minY + Self.bottomMargin).rounded())
        window.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
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
            return controller.liveTranscript.isEmpty ? String(localized: "请说话…") : Self.tail(controller.liveTranscript)
        case .processing:
            return controller.liveTranscript.isEmpty ? String(localized: "处理中…") : Self.tail(controller.liveTranscript)
        case .message:
            return controller.message
        }
    }

    private var hintText: String? {
        switch controller.mode {
        case .recording: return String(localized: "再按快捷键结束 · Esc 取消")
        case .processing: return controller.liveTranscript.isEmpty ? nil : String(localized: "处理中… · Esc 取消")
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
