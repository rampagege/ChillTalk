import SwiftUI
import Combine
import Speech

@main
struct ChillTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarExtraContent()
                .environmentObject(appDelegate.appState)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: appDelegate.appState.recordingState))
        }
    }
}

struct MenuBarExtraContent: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("hotkeyPreset") private var hotkeyPresetRaw = HotkeyPreset.defaultPreset.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("状态: \(appState.recordingState.displayName)")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Text("快捷键: \((HotkeyPreset(rawValue: hotkeyPresetRaw) ?? .defaultPreset).displayName)")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            Button("复制上次结果") {
                if let text = appState.lastTranscript {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .disabled(appState.lastTranscript == nil)

            Button("设置...") {
                SettingsWindowController.shared.show()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("历史记录...") {
                SettingsWindowController.shared.show(page: .history)
            }

            Button("权限...") {
                SettingsWindowController.shared.show(page: .permissions)
            }

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.vertical, 4)
    }
}

/// Owns the dictation pipeline:
/// idle → recording (audio streams to ASR) → processing (final ASR, polish, paste) → idle.
///
/// Every dictation gets a fresh `dictationID`; async callbacks from a cancelled or older
/// dictation compare their captured ID and drop themselves.
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    private var hotkeyManager: HotkeyManager!
    private let audioCapture = AudioCapture()
    private let textInserter = TextInserter()
    private let liveTranscription = LiveTranscription()
    private var cancellables = Set<AnyCancellable>()

    private var dictationID = UUID()
    private var asrSession: ASRSession?
    /// Frontmost app when recording stopped; text is only pasted if it's still frontmost.
    private var targetAppPID: pid_t?
    /// Recorded in history once the final text is ready.
    private var currentRawText = ""
    private var currentAudioSeconds: TimeInterval = 0
    private var currentProvider: ASRProviderType = .dashScope
    private var errorResetWork: DispatchWorkItem?

    override init() {
        super.init()
        // Nested ObservableObject changes don't propagate on their own; forward them so the
        // menu bar icon (read through appDelegate.appState) updates.
        appState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        terminateOtherInstances()
        MainActor.assumeIsolated {
            SettingsWindowController.shared.configure(appState: appState)
            SyncService.shared.start()
        }

        liveTranscription.onPartialResult = { transcript in
            RecordingHUDController.shared.updateLiveTranscript(transcript)
        }
        liveTranscription.onError = { error in
            print("⚠️ Live transcription error: \(error.localizedDescription)")
        }

        audioCapture.onAudioBuffer = { [weak self] buffer in
            self?.liveTranscription.appendAudioBuffer(buffer)
        }
        audioCapture.onAudioLevel = { level in
            RecordingHUDController.shared.updateAudioLevel(level)
        }
        audioCapture.onError = { [weak self] error in
            guard let self = self, self.appState.recordingState == .recording else { return }
            self.cancelDictation()
            self.showError(String(localized: "录音中断：\(error.localizedDescription)"))
        }

        hotkeyManager = HotkeyManager()
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.handleHotkey()
        }
        hotkeyManager.onEscapePressed = { [weak self] in
            self?.handleEscape()
        }

        PermissionManager.shared.checkAllPermissions()

        registerHotkey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyConfigChanged),
            name: .hotkeyConfigChanged,
            object: nil
        )
        // Another Mac may have changed the hotkey.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHotkeyConfigChanged),
            name: .settingsSyncedFromCloud,
            object: nil
        )

        appState.$recordingState
            .sink { [weak self] state in self?.updateHUD(state: state) }
            .store(in: &cancellables)
    }

    /// Two running copies (e.g. an old build left behind when Xcode relaunches) would both
    /// react to the hotkey and paste every dictation twice. The newest launch wins.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me.processIdentifier }
        guard !others.isEmpty else { return }
        print("⚠️ Quitting \(others.count) older ChillTalk instance(s)")
        others.forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
    }

    private func registerHotkey() {
        let preset = SettingsManager.shared.getHotkeyPreset()
        if !hotkeyManager.registerHotkey(preset.config) {
            showError(String(localized: "快捷键 \(preset.displayName) 注册失败，可能已被其他应用占用，请在设置中换一个。"))
        }
    }

    @objc private func handleHotkeyConfigChanged() {
        registerHotkey()
    }

    private func updateHUD(state: RecordingState) {
        switch state {
        case .idle:
            RecordingHUDController.shared.hide()
        case .recording, .processing:
            RecordingHUDController.shared.show(state: state)
        case .error:
            RecordingHUDController.shared.flash(appState.lastError ?? String(localized: "出错了"), isError: true)
        }
    }

    // MARK: - Hotkey handling

    private func handleHotkey() {
        switch appState.recordingState {
        case .idle, .error:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            // Don't start a new dictation over one that hasn't been inserted yet.
            print("⏳ Still processing, hotkey ignored (Esc cancels)")
        }
    }

    private func handleEscape() {
        switch appState.recordingState {
        case .recording, .processing:
            cancelDictation()
            appState.recordingState = .idle
            RecordingHUDController.shared.flash(String(localized: "已取消"), isError: false, duration: 1.0)
        case .idle, .error:
            break
        }
    }

    // MARK: - Pipeline

    private func startRecording() {
        guard PermissionManager.shared.hasMicrophonePermission() else {
            PermissionManager.shared.checkMicrophonePermission()
            showError(String(localized: "需要麦克风权限"))
            return
        }

        let settings = SettingsManager.shared
        let provider = settings.getASRProvider()
        let apiKey = settings.getASRAPIKey()
        guard !apiKey.isEmpty else {
            showError(String(localized: "请先在设置中配置 \(provider.shortName) API 密钥"))
            return
        }

        let id = UUID()
        dictationID = id
        currentProvider = provider
        errorResetWork?.cancel()

        let hints = MainActor.assumeIsolated { VocabularyStore.shared.recognitionHints() }
        let session = provider.makeSession(apiKey: apiKey, hints: hints)
        session.onError = { [weak self] error in
            // Streaming ASR failed mid-recording: stop now instead of after the user finishes.
            guard let self = self, self.dictationID == id else { return }
            self.cancelDictation()
            self.showError(String(localized: "转录失败：\(error.localizedDescription)"))
        }
        if provider.streamsPartials {
            let language = hints.language
            session.onPartialTranscript = { [weak self] text in
                guard let self = self, self.dictationID == id else { return }
                RecordingHUDController.shared.updateLiveTranscript(language.normalizeScript(text))
            }
        }
        session.start()

        audioCapture.voiceProcessingEnabled = settings.isVoiceProcessingEnabled()
        do {
            try audioCapture.startRecording { [weak session] pcm in
                session?.append(pcm)
            }
        } catch {
            session.cancel()
            showError(String(localized: "录音失败：\(error.localizedDescription)"))
            return
        }

        asrSession = session
        appState.recordingState = .recording
        // Streaming providers show their own text, which is also what gets inserted.
        // Apple captions are only a preview for upload-only providers.
        if !provider.streamsPartials {
            startLiveCaptions(for: id)
        }
    }

    private func startLiveCaptions(for id: UUID) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            liveTranscription.setLocale(SettingsManager.shared.getDictationLanguage().appleLocale)
            liveTranscription.startRecognition()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                DispatchQueue.main.async {
                    guard let self = self, status == .authorized,
                          self.dictationID == id, self.appState.recordingState == .recording else { return }
                    self.liveTranscription.setLocale(SettingsManager.shared.getDictationLanguage().appleLocale)
                    self.liveTranscription.startRecognition()
                }
            }
        default:
            // Live captions are optional; don't nag on every recording.
            break
        }
    }

    private func stopRecording() {
        let duration = audioCapture.stopRecording()
        liveTranscription.stopRecognition()

        guard let session = asrSession else {
            appState.recordingState = .idle
            return
        }

        if duration < 0.3 {
            print("⚠️ Recording too short (\(String(format: "%.2f", duration))s), ignoring")
            session.cancel()
            asrSession = nil
            appState.recordingState = .idle
            return
        }

        targetAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        currentAudioSeconds = duration
        appState.recordingState = .processing

        let id = dictationID
        session.finish { [weak self] result in
            guard let self = self, self.dictationID == id else { return }
            self.asrSession = nil
            switch result {
            case .success(let transcript):
                print("📝 Transcript received (\(transcript.count) chars)")
                self.currentRawText = transcript
                // Traditional output first (ASR mostly emits Simplified), then fix known
                // misrecognitions before polish sees the text.
                let scripted = SettingsManager.shared.getDictationLanguage().normalizeScript(transcript)
                let fixed = MainActor.assumeIsolated { VocabularyStore.shared.applyReplacements(to: scripted) }
                self.polishAndInsert(fixed, id: id)
            case .failure(let error):
                self.showError(String(localized: "转录失败：\(error.localizedDescription)"))
            }
        }
    }

    /// Stops whatever is in flight. Callbacks from the cancelled dictation are ignored.
    private func cancelDictation() {
        dictationID = UUID()
        audioCapture.stopRecording()
        liveTranscription.stopRecognition()
        asrSession?.cancel()
        asrSession = nil
    }

    private func polishAndInsert(_ text: String, id: UUID) {
        let settings = SettingsManager.shared
        guard settings.isPolishEnabled() else {
            insertText(text, id: id)
            return
        }

        let provider = settings.getPolishProvider()
        let polishKey = settings.getPolishAPIKey()
        guard !polishKey.isEmpty else {
            insertText(text, id: id, notice: String(localized: "润色已开启但未配置\(provider.displayName)密钥，已插入原文"))
            return
        }
        let language = settings.getDictationLanguage()
        let polish = LLMPolish(provider: provider, apiKey: polishKey, model: settings.getPolishModel(), language: language)
        
        runPolish(text, with: polish, id: id)
    }
    
    private func runPolish(_ text: String, with polish: LLMPolish, id: UUID) {
        let glossary = MainActor.assumeIsolated { VocabularyStore.shared.glossary() }
        polish.polish(text: text, glossary: glossary) { [weak self] result in
            guard let self = self, self.dictationID == id else { return }
            switch result {
            case .success(let polished):
                // The model may slip back into Simplified characters.
                let language = SettingsManager.shared.getDictationLanguage()
                self.insertText(language.normalizeScript(polished), id: id, polishedWith: polish.provider)
            case .failure(let error):
                print("⚠️ Polish failed: \(error.localizedDescription)")
                self.insertText(text, id: id, notice: String(localized: "润色失败，已插入原文"))
            }
        }
    }
    
    private func insertText(_ rawText: String, id: UUID, notice: String? = nil, polishedWith: PolishProvider? = nil) {
        guard dictationID == id else { return }
        let text = SettingsManager.shared.keepsTrailingPeriod() ? rawText : Self.removingTrailingPeriod(rawText)
        appState.lastTranscript = text
        recordHistory(finalText: text, polishedWith: polishedWith)

        textInserter.insert(text, expectedPID: targetAppPID) { [weak self] result in
            guard let self = self, self.dictationID == id else { return }
            switch result {
            case .success(.pasted):
                self.appState.recordingState = .idle
                if let notice = notice {
                    RecordingHUDController.shared.flash(notice, isError: false)
                }
            case .success(.pastedAndKeptOnClipboard):
                self.appState.recordingState = .idle
                RecordingHUDController.shared.flash(String(localized: "未检测到输入框，文字已复制到剪贴板"), isError: false)
            case .success(.copiedOnly):
                self.appState.recordingState = .idle
                RecordingHUDController.shared.flash(String(localized: "窗口已切换，结果已复制到剪贴板"), isError: false)
            case .failure(let error):
                self.showError(String(localized: "\(error.localizedDescription)，结果已复制到剪贴板"))
            }
        }
    }

    /// Drops one final "。" or "." (not "…" / "..."); question and exclamation marks stay.
    static func removingTrailingPeriod(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last == "。" || last == "." else { return trimmed }
        if trimmed.hasSuffix("..") { return trimmed }
        trimmed.removeLast()
        return trimmed
    }
    
    private func recordHistory(finalText: String, polishedWith: PolishProvider?) {
        let cost = currentAudioSeconds * currentProvider.estimatedYuanPerSecond
            + (polishedWith?.estimatedYuan(characters: currentRawText.count) ?? 0)
        let raw = currentRawText, seconds = currentAudioSeconds, provider = currentProvider.shortName
        // The pipeline always runs on the main thread.
        MainActor.assumeIsolated {
            HistoryStore.shared.record(
                rawText: raw,
                finalText: finalText,
                audioSeconds: seconds,
                asrProvider: provider,
                polished: polishedWith != nil,
                estimatedCostYuan: cost
            )
        }
    }
    
    /// Shows the error in the HUD (non-blocking) and returns to idle shortly after.
    private func showError(_ message: String) {
        print("❌ Error: \(message)")
        appState.lastError = message
        appState.recordingState = .error

        errorResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.appState.recordingState == .error else { return }
            self.appState.recordingState = .idle
        }
        errorResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}
