import Combine
import Foundation

/// Backing state for the settings window. Every change is saved automatically:
/// switches and pickers immediately, text fields after a short pause in typing.
@MainActor
final class SettingsModel: ObservableObject {
    private let settings = SettingsManager.shared
    private var pendingSaves: [String: DispatchWorkItem] = [:]
    private var savedResetWork: DispatchWorkItem?
    private static let typingDelay: TimeInterval = 0.5

    /// Key of the field saved most recently, for the "已保存" flash. Cleared after ~1.5s.
    @Published private(set) var recentlySaved: String?

    // MARK: Speech recognition

    @Published var asrProvider: ASRProviderType {
        didSet { settings.setASRProvider(asrProvider); markSaved("asrProvider") }
    }
    @Published var dashScopeKey: String {
        didSet { saveLater("dashScopeKey") { [settings, dashScopeKey] in settings.setDashScopeAPIKey(Self.clean(dashScopeKey)) } }
    }
    @Published var dashScopeASRModel: String {
        didSet { saveLater("dashScopeASRModel") { [settings, dashScopeASRModel] in settings.setDashScopeASRModel(Self.clean(dashScopeASRModel)) } }
    }
    @Published var dashScopeBatchModel: String {
        didSet { saveLater("dashScopeBatchASRModel") { [settings, dashScopeBatchModel] in settings.setDashScopeBatchModel(Self.clean(dashScopeBatchModel)) } }
    }
    @Published var deepgramKey: String {
        didSet { saveLater("deepgramKey") { [settings, deepgramKey] in settings.setDeepgramAPIKey(Self.clean(deepgramKey)) } }
    }
    @Published var openAIKey: String {
        didSet { saveLater("openAIKey") { [settings, openAIKey] in settings.setOpenAIAPIKey(Self.clean(openAIKey)) } }
    }
    @Published var sonioxKey: String {
        didSet { saveLater("sonioxKey") { [settings, sonioxKey] in settings.setSonioxAPIKey(Self.clean(sonioxKey)) } }
    }
    @Published var assemblyAIKey: String {
        didSet { saveLater("assemblyAIKey") { [settings, assemblyAIKey] in settings.setAssemblyAIAPIKey(Self.clean(assemblyAIKey)) } }
    }
    @Published var openRouterKey: String {
        didSet { saveLater("openRouterKey") { [settings, openRouterKey] in settings.setOpenRouterAPIKey(Self.clean(openRouterKey)) } }
    }

    // MARK: Polish

    @Published var polishEnabled: Bool {
        didSet { settings.setPolishEnabled(polishEnabled); markSaved("polishEnabled") }
    }
    @Published var polishProvider: PolishProvider {
        didSet { settings.setPolishProvider(polishProvider); markSaved("polishProvider") }
    }
    @Published var dashScopePolishModel: String {
        didSet { saveLater("dashScopePolishModel") { [settings, dashScopePolishModel] in settings.setDashScopePolishModel(Self.clean(dashScopePolishModel)) } }
    }
    @Published var openRouterModel: String {
        didSet { saveLater("openRouterModel") { [settings, openRouterModel] in settings.setOpenRouterModel(Self.clean(openRouterModel)) } }
    }

    // MARK: Vocabulary context

    @Published var recognitionContext: String {
        didSet { saveLater("recognitionContext") { [settings, recognitionContext] in settings.setRecognitionContext(recognitionContext) } }
    }

    @Published var phoneticCorrection: Bool {
        didSet { settings.setPhoneticCorrectionEnabled(phoneticCorrection); markSaved("phoneticCorrection") }
    }

    // MARK: Language

    @Published var dictationLanguage: DictationLanguage {
        didSet { settings.setDictationLanguage(dictationLanguage); markSaved("dictationLanguage") }
    }
    @Published var mixEnglish: Bool {
        didSet { settings.setMixesEnglish(mixEnglish); markSaved("mixEnglish") }
    }
    @Published var recognitionMode: RecognitionMode {
        didSet { settings.setRecognitionMode(recognitionMode); markSaved("recognitionMode") }
    }
    @Published var voiceProcessing: Bool {
        didSet { settings.setVoiceProcessingEnabled(voiceProcessing); markSaved("voiceProcessing") }
    }

    // MARK: Output

    @Published var keepsTrailingPeriod: Bool {
        didSet { settings.setKeepsTrailingPeriod(keepsTrailingPeriod); markSaved("keepsTrailingPeriod") }
    }

    // MARK: Hotkey

    @Published var hotkeyPreset: HotkeyPreset {
        didSet {
            guard hotkeyPreset != oldValue else { return }
            settings.setHotkeyPreset(hotkeyPreset)
            // One key can't do both.
            if correctionHotkeyPreset == hotkeyPreset { correctionHotkeyPreset = nil }
            NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
            markSaved("hotkeyPreset")
        }
    }
    @Published var correctionHotkeyPreset: HotkeyPreset? {
        didSet {
            guard correctionHotkeyPreset != oldValue else { return }
            settings.setCorrectionHotkeyPreset(correctionHotkeyPreset)
            NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
            markSaved("correctionHotkeyPreset")
        }
    }

    /// Set while copying values in from UserDefaults, so it isn't treated as a user edit.
    private var isReloading = false
    private var syncObserver: NSObjectProtocol?

    init() {
        asrProvider = settings.getASRProvider()
        dashScopeKey = settings.getDashScopeAPIKey()
        dashScopeASRModel = settings.getDashScopeASRModel()
        dashScopeBatchModel = settings.getDashScopeBatchModel()
        deepgramKey = settings.getDeepgramAPIKey()
        openAIKey = settings.getOpenAIAPIKey()
        openRouterKey = settings.getOpenRouterAPIKey()
        sonioxKey = settings.getSonioxAPIKey()
        assemblyAIKey = settings.getAssemblyAIAPIKey()
        polishEnabled = settings.isPolishEnabled()
        polishProvider = settings.getPolishProvider()
        dashScopePolishModel = settings.getDashScopePolishModel()
        openRouterModel = settings.getOpenRouterModel()
        hotkeyPreset = settings.getHotkeyPreset()
        correctionHotkeyPreset = settings.getCorrectionHotkeyPreset()
        keepsTrailingPeriod = settings.keepsTrailingPeriod()
        recognitionContext = settings.getRecognitionContext()
        phoneticCorrection = settings.isPhoneticCorrectionEnabled()
        dictationLanguage = settings.getDictationLanguage()
        mixEnglish = settings.mixesEnglish()
        voiceProcessing = settings.isVoiceProcessingEnabled()
        recognitionMode = settings.getRecognitionMode()
        syncObserver = NotificationCenter.default.addObserver(
            forName: .settingsSyncedFromCloud, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSyncedValues() }
        }
    }

    /// Key for the currently selected ASR provider (the field shown on the ASR page).
    var asrKeyBinding: ReferenceWritableKeyPath<SettingsModel, String> {
        switch asrProvider {
        case .dashScope: return \.dashScopeKey
        case .deepgram: return \.deepgramKey
        case .openAIWhisper: return \.openAIKey
        case .openRouter: return \.openRouterKey
        case .soniox: return \.sonioxKey
        case .assemblyAI: return \.assemblyAIKey
        }
    }

    var polishKeyBinding: ReferenceWritableKeyPath<SettingsModel, String> {
        switch polishProvider {
        case .dashScope: return \.dashScopeKey
        case .openRouter: return \.openRouterKey
        }
    }

    var polishModel: String {
        switch polishProvider {
        case .dashScope: return dashScopePolishModel.isEmpty ? PolishProvider.dashScope.defaultModel : dashScopePolishModel
        case .openRouter: return openRouterModel.isEmpty ? PolishProvider.openRouter.defaultModel : openRouterModel
        }
    }

    /// Picks up settings another Mac changed.
    private func reloadSyncedValues() {
        isReloading = true
        defer { isReloading = false }
        if asrProvider != settings.getASRProvider() { asrProvider = settings.getASRProvider() }
        if dashScopeASRModel != settings.getDashScopeASRModel() { dashScopeASRModel = settings.getDashScopeASRModel() }
        if dashScopeBatchModel != settings.getDashScopeBatchModel() { dashScopeBatchModel = settings.getDashScopeBatchModel() }
        if polishEnabled != settings.isPolishEnabled() { polishEnabled = settings.isPolishEnabled() }
        if polishProvider != settings.getPolishProvider() { polishProvider = settings.getPolishProvider() }
        if dashScopePolishModel != settings.getDashScopePolishModel() { dashScopePolishModel = settings.getDashScopePolishModel() }
        if openRouterModel != settings.getOpenRouterModel() { openRouterModel = settings.getOpenRouterModel() }
        if hotkeyPreset != settings.getHotkeyPreset() { hotkeyPreset = settings.getHotkeyPreset() }
        if correctionHotkeyPreset != settings.getCorrectionHotkeyPreset() { correctionHotkeyPreset = settings.getCorrectionHotkeyPreset() }
        if keepsTrailingPeriod != settings.keepsTrailingPeriod() { keepsTrailingPeriod = settings.keepsTrailingPeriod() }
        if phoneticCorrection != settings.isPhoneticCorrectionEnabled() { phoneticCorrection = settings.isPhoneticCorrectionEnabled() }
        if recognitionContext != settings.getRecognitionContext() { recognitionContext = settings.getRecognitionContext() }
        if dictationLanguage != settings.getDictationLanguage() { dictationLanguage = settings.getDictationLanguage() }
        if mixEnglish != settings.mixesEnglish() { mixEnglish = settings.mixesEnglish() }
        if voiceProcessing != settings.isVoiceProcessingEnabled() { voiceProcessing = settings.isVoiceProcessingEnabled() }
        if recognitionMode != settings.getRecognitionMode() { recognitionMode = settings.getRecognitionMode() }
        pendingSaves.values.forEach { $0.cancel() }
        pendingSaves.removeAll()
    }

    /// Writes any text field still waiting for its typing pause (e.g. when the window closes).
    func flushPendingSaves() {
        let work = pendingSaves.values
        pendingSaves.removeAll()
        work.forEach {
            $0.perform()
            $0.cancel()  // don't run again when its scheduled time comes
        }
    }

    // MARK: - Private

    private func saveLater(_ key: String, _ save: @escaping () -> Void) {
        guard !isReloading else { return }
        pendingSaves[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            save()
            self?.pendingSaves[key] = nil
            self?.markSaved(key)
        }
        pendingSaves[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.typingDelay, execute: work)
    }

    private func markSaved(_ key: String) {
        guard !isReloading else { return }
        SyncService.shared.syncSoon()
        recentlySaved = key
        savedResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if self?.recentlySaved == key { self?.recentlySaved = nil }
        }
        savedResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private nonisolated static func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
