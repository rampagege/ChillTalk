import Foundation
import Security
import Carbon

// Hotkey Presets
enum HotkeyPreset: String, CaseIterable {
    case rightOption = "right_option"
    case leftOption = "left_option"
    case rightCommand = "right_command"
    case rightControl = "right_control"
    case optionSpace = "option_space"
    case commandShiftSpace = "command_shift_space"
    case controlSpace = "control_space"

    var displayName: String {
        switch self {
        case .rightOption:
            return String(localized: "右 Option (右 ⌥)")
        case .leftOption:
            return String(localized: "左 Option (左 ⌥)")
        case .rightCommand:
            return String(localized: "右 Command (右 ⌘)")
        case .rightControl:
            return String(localized: "右 Control (右 ⌃)")
        case .optionSpace:
            return "Option + Space (⌥ + Space)"
        case .commandShiftSpace:
            return "Command + Shift + Space (⌘ + ⇧ + Space)"
        case .controlSpace:
            return "Control + Space (⌃ + Space)"
        }
    }

    /// Known conflicts shown under the picker.
    var conflictNote: String? {
        switch self {
        case .controlSpace:
            return String(localized: "⌃ + Space 是 macOS 默认的「切换输入法」快捷键，使用前请在 系统设置 → 键盘 → 键盘快捷键 → 输入法 中关闭或改掉它。")
        case .optionSpace:
            return String(localized: "部分输入法或启动器（如 Alfred）也使用 ⌥ + Space，冲突时请换一个。")
        default:
            return nil
        }
    }

    /// Keys as shown on keycaps in the settings window.
    var keycaps: [String] {
        switch self {
        case .rightOption: return [String(localized: "右 ⌥")]
        case .leftOption: return [String(localized: "左 ⌥")]
        case .rightCommand: return [String(localized: "右 ⌘")]
        case .rightControl: return [String(localized: "右 ⌃")]
        case .optionSpace: return ["⌥", "Space"]
        case .commandShiftSpace: return ["⌘", "⇧", "Space"]
        case .controlSpace: return ["⌃", "Space"]
        }
    }
    
    var config: HotkeyConfig {
        switch self {
        case .rightOption:
            return HotkeyConfig(keyCode: kVK_RightOption, modifiers: Int(optionKey))
        case .leftOption:
            return HotkeyConfig(keyCode: kVK_Option, modifiers: Int(optionKey))
        case .rightCommand:
            return HotkeyConfig(keyCode: kVK_RightCommand, modifiers: Int(cmdKey))
        case .rightControl:
            return HotkeyConfig(keyCode: kVK_RightControl, modifiers: Int(controlKey))
        case .optionSpace:
            return HotkeyConfig(keyCode: kVK_Space, modifiers: Int(optionKey))
        case .commandShiftSpace:
            return HotkeyConfig(keyCode: kVK_Space, modifiers: Int(cmdKey) | Int(shiftKey))
        case .controlSpace:
            return HotkeyConfig(keyCode: kVK_Space, modifiers: Int(controlKey))
        }
    }

    static var defaultPreset: HotkeyPreset {
        return .rightOption
    }
}

/// The language the user dictates in. Drives ASR language hints, polish rules,
/// Traditional-Chinese output and whether pinyin matching applies.
enum DictationLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case yue
    case en
    case ja
    case ko

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .yue: return "粵語"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    /// ISO code for DashScope / Soniox language hints.
    var hintCode: String {
        switch self {
        case .zhHans, .zhHant: return "zh"
        case .yue: return "yue"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        }
    }

    var deepgramCode: String {
        switch self {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .yue: return "zh-HK"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        }
    }

    /// Whisper-style ISO-639-1 code.
    var whisperCode: String {
        switch self {
        case .zhHans, .zhHant, .yue: return "zh"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        }
    }

    var appleLocale: String {
        switch self {
        case .zhHans: return "zh-CN"
        case .zhHant: return "zh-TW"
        case .yue: return "zh-HK"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        case .ko: return "ko-KR"
        }
    }

    /// Output should be Traditional characters (ASR models mostly emit Simplified).
    var wantsTraditional: Bool { self == .zhHant || self == .yue }

    /// Pinyin-based correction only makes sense for Chinese.
    var usesPinyin: Bool { self == .zhHans || self == .zhHant || self == .yue }

    /// Converts Simplified characters to Traditional when this language wants them.
    func normalizeScript(_ text: String) -> String {
        guard wantsTraditional else { return text }
        return text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }
}

/// Where transcript polish runs. Both use an OpenAI-compatible chat completions API.
enum PolishProvider: String, CaseIterable {
    case dashScope = "dashscope"
    case openRouter = "openrouter"
    
    var displayName: String {
        switch self {
        case .dashScope: return String(localized: "千问 / 阿里云百炼")
        case .openRouter: return "OpenRouter"
        }
    }
    
    var endpoint: String {
        switch self {
        case .dashScope: return "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        case .openRouter: return "https://openrouter.ai/api/v1/chat/completions"
        }
    }
    
    /// Rough CNY cost of polishing `characters` of text, for the usage estimate only.
    /// Assumes ~1.2k prompt tokens plus about one token per character in and out.
    func estimatedYuan(characters: Int) -> Double {
        let inputTokens = 1200 + Double(characters)
        let outputTokens = Double(characters)
        switch self {
        case .dashScope: return (inputTokens * 0.8 + outputTokens * 2.7) / 1_000_000        // qwen3.8-flash
        case .openRouter: return (inputTokens * 0.15 + outputTokens * 0.6) * 7.1 / 1_000_000 // gpt-4o-mini
        }
    }
    
    var defaultModel: String {
        switch self {
        case .dashScope: return "qwen3.8-flash"
        case .openRouter: return "openai/gpt-4o-mini"
        }
    }
}

extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("HotkeyConfigChanged")
}

class SettingsManager {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults.standard
    private let keychainService = "com.chilltalk.app"
    
    // Keys
    private enum Keys {
        static let asrProvider = "asrProvider"
        static let openRouterModel = "openRouterModel"
        static let dashScopePolishModel = "dashScopePolishModel"
        static let dashScopeASRModel = "dashScopeASRModel"
        static let dashScopeBatchModel = "dashScopeBatchASRModel"
        static let trailingPeriod = "trailingPeriod"
        static let recognitionContext = "recognitionContext"
        static let phoneticCorrection = "phoneticCorrection"
        static let dictationLanguage = "dictationLanguage"
        static let mixEnglish = "mixEnglish"
        static let voiceProcessing = "voiceProcessing"
        static let recognitionMode = "recognitionMode"
        static let polishProvider = "polishProvider"
        static let hotkeyPreset = "hotkeyPreset"
        static let polishEnabled = "polishEnabled"
    }
    
    private enum KeychainKeys {
        static let dashScopeAPIKey = "dashScopeAPIKey"
        static let deepgramAPIKey = "deepgramAPIKey"
        static let openAIAPIKey = "openAIAPIKey"
        static let openRouterAPIKey = "openRouterAPIKey"
        static let sonioxAPIKey = "sonioxAPIKey"
        static let assemblyAIAPIKey = "assemblyAIAPIKey"
    }
    
    private init() {}
    
    // MARK: - ASR Provider
    
    func getASRProvider() -> ASRProviderType {
        if let rawValue = defaults.string(forKey: Keys.asrProvider),
           let provider = ASRProviderType(rawValue: rawValue) {
            return provider
        }
        return .dashScope // Default
    }
    
    func setASRProvider(_ provider: ASRProviderType) {
        defaults.set(provider.rawValue, forKey: Keys.asrProvider)
    }
    
    // MARK: - API Keys (Keychain)
    
    func getASRAPIKey() -> String {
        let provider = getASRProvider()
        switch provider {
        case .dashScope:
            return getKeychainValue(key: KeychainKeys.dashScopeAPIKey) ?? ""
        case .deepgram:
            return getKeychainValue(key: KeychainKeys.deepgramAPIKey) ?? ""
        case .openAIWhisper:
            return getKeychainValue(key: KeychainKeys.openAIAPIKey) ?? ""
        case .openRouter:
            return getKeychainValue(key: KeychainKeys.openRouterAPIKey) ?? ""
        case .soniox:
            return getSonioxAPIKey()
        case .assemblyAI:
            return getAssemblyAIAPIKey()
        }
    }
    
    func getSonioxAPIKey() -> String {
        return getKeychainValue(key: KeychainKeys.sonioxAPIKey) ?? ""
    }
    
    func setSonioxAPIKey(_ key: String) {
        setKeychainValue(key: KeychainKeys.sonioxAPIKey, value: key)
    }
    
    func getAssemblyAIAPIKey() -> String {
        return getKeychainValue(key: KeychainKeys.assemblyAIAPIKey) ?? ""
    }
    
    func setAssemblyAIAPIKey(_ key: String) {
        setKeychainValue(key: KeychainKeys.assemblyAIAPIKey, value: key)
    }
    
    func getDashScopeAPIKey() -> String {
        return getKeychainValue(key: KeychainKeys.dashScopeAPIKey) ?? ""
    }
    
    func setDashScopeAPIKey(_ key: String) {
        setKeychainValue(key: KeychainKeys.dashScopeAPIKey, value: key)
    }
    
    func getDeepgramAPIKey() -> String {
        return getKeychainValue(key: KeychainKeys.deepgramAPIKey) ?? ""
    }
    
    func setDeepgramAPIKey(_ key: String) {
        setKeychainValue(key: KeychainKeys.deepgramAPIKey, value: key)
    }
    
    func getOpenAIAPIKey() -> String {
        return getKeychainValue(key: KeychainKeys.openAIAPIKey) ?? ""
    }
    
    func setOpenAIAPIKey(_ key: String) {
        setKeychainValue(key: KeychainKeys.openAIAPIKey, value: key)
    }
    
    func getOpenRouterAPIKey() -> String {
        return getKeychainValue(key: KeychainKeys.openRouterAPIKey) ?? ""
    }
    
    func setOpenRouterAPIKey(_ key: String) {
        setKeychainValue(key: KeychainKeys.openRouterAPIKey, value: key)
    }
    
    // MARK: - OpenRouter Model
    
    func getOpenRouterModel() -> String {
        return nonEmpty(defaults.string(forKey: Keys.openRouterModel)) ?? PolishProvider.openRouter.defaultModel
    }
    
    func setOpenRouterModel(_ model: String) {
        defaults.set(model, forKey: Keys.openRouterModel)
    }
    
    func getDashScopePolishModel() -> String {
        return nonEmpty(defaults.string(forKey: Keys.dashScopePolishModel)) ?? PolishProvider.dashScope.defaultModel
    }
    
    func setDashScopePolishModel(_ model: String) {
        defaults.set(model, forKey: Keys.dashScopePolishModel)
    }
    
    static let defaultDashScopeASRModel = "qwen-audio-3.0-asr-flash-streaming"
    
    func getDashScopeASRModel() -> String {
        return nonEmpty(defaults.string(forKey: Keys.dashScopeASRModel)) ?? Self.defaultDashScopeASRModel
    }
    
    func setDashScopeASRModel(_ model: String) {
        defaults.set(model, forKey: Keys.dashScopeASRModel)
    }

    static let defaultDashScopeBatchModel = "qwen3-asr-flash"

    /// Model for "说完再识别"; the streaming model above is used in real-time mode.
    func getDashScopeBatchModel() -> String {
        return nonEmpty(defaults.string(forKey: Keys.dashScopeBatchModel)) ?? Self.defaultDashScopeBatchModel
    }

    func setDashScopeBatchModel(_ model: String) {
        defaults.set(model, forKey: Keys.dashScopeBatchModel)
    }
    
    // MARK: - Recognition context
    
    static let maxRecognitionContextLength = 300
    
    /// Free-text description of the user's field, sent to ASR providers that accept context.
    func getRecognitionContext() -> String {
        defaults.string(forKey: Keys.recognitionContext) ?? ""
    }
    
    func setRecognitionContext(_ text: String) {
        defaults.set(String(text.prefix(Self.maxRecognitionContextLength)), forKey: Keys.recognitionContext)
    }
    
    /// Fix vocabulary terms that were misheard as same-sounding characters.
    func isPhoneticCorrectionEnabled() -> Bool {
        defaults.object(forKey: Keys.phoneticCorrection) as? Bool ?? true
    }
    
    func setPhoneticCorrectionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.phoneticCorrection)
    }
    
    // MARK: - Dictation language
    
    func getDictationLanguage() -> DictationLanguage {
        defaults.string(forKey: Keys.dictationLanguage).flatMap(DictationLanguage.init(rawValue:)) ?? .zhHans
    }
    
    func setDictationLanguage(_ language: DictationLanguage) {
        defaults.set(language.rawValue, forKey: Keys.dictationLanguage)
    }
    
    /// Expect English words mixed into non-English speech.
    func mixesEnglish() -> Bool {
        defaults.object(forKey: Keys.mixEnglish) as? Bool ?? true
    }
    
    func setMixesEnglish(_ mix: Bool) {
        defaults.set(mix, forKey: Keys.mixEnglish)
    }
    
    /// macOS voice processing on the microphone (echo cancellation + noise suppression).
    func isVoiceProcessingEnabled() -> Bool {
        defaults.bool(forKey: Keys.voiceProcessing)
    }
    
    func setVoiceProcessingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.voiceProcessing)
    }
    
    func getRecognitionMode() -> RecognitionMode {
        defaults.string(forKey: Keys.recognitionMode).flatMap(RecognitionMode.init(rawValue:)) ?? .realtime
    }
    
    func setRecognitionMode(_ mode: RecognitionMode) {
        defaults.set(mode.rawValue, forKey: Keys.recognitionMode)
    }
    
    // MARK: - Output
    
    /// Whether the inserted text may end with a period (。/.). Question and exclamation
    /// marks are always kept.
    func keepsTrailingPeriod() -> Bool {
        defaults.object(forKey: Keys.trailingPeriod) as? Bool ?? true
    }
    
    func setKeepsTrailingPeriod(_ keep: Bool) {
        defaults.set(keep, forKey: Keys.trailingPeriod)
    }
    
    // MARK: - Polish Provider
    
    func getPolishProvider() -> PolishProvider {
        if let raw = defaults.string(forKey: Keys.polishProvider), let provider = PolishProvider(rawValue: raw) {
            return provider
        }
        // Users who set up polish before providers existed only have an OpenRouter key.
        if getDashScopeAPIKey().isEmpty && !getOpenRouterAPIKey().isEmpty {
            return .openRouter
        }
        return .dashScope
    }
    
    func setPolishProvider(_ provider: PolishProvider) {
        defaults.set(provider.rawValue, forKey: Keys.polishProvider)
    }
    
    func getPolishAPIKey() -> String {
        switch getPolishProvider() {
        case .dashScope: return getDashScopeAPIKey()
        case .openRouter: return getOpenRouterAPIKey()
        }
    }
    
    func getPolishModel() -> String {
        switch getPolishProvider() {
        case .dashScope: return getDashScopePolishModel()
        case .openRouter: return getOpenRouterModel()
        }
    }
    
    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
    
    // MARK: - Hotkey Configuration
    
    func getHotkeyPreset() -> HotkeyPreset {
        if let rawValue = defaults.string(forKey: Keys.hotkeyPreset),
           let preset = HotkeyPreset(rawValue: rawValue) {
            return preset
        }
        return .defaultPreset
    }
    
    func setHotkeyPreset(_ preset: HotkeyPreset) {
        defaults.set(preset.rawValue, forKey: Keys.hotkeyPreset)
    }
    
    // MARK: - Polish Toggle
    
    func isPolishEnabled() -> Bool {
        if defaults.object(forKey: Keys.polishEnabled) == nil {
            // Default to true when key is present, false otherwise
            let hasKey = !getPolishAPIKey().isEmpty
            return hasKey
        }
        return defaults.bool(forKey: Keys.polishEnabled)
    }
    
    func setPolishEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.polishEnabled)
    }
    
    // MARK: - Keychain Helpers
    
    private func getKeychainValue(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        
        return nil
    }
    
    private func setKeychainValue(key: String, value: String) {
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add new
        guard let data = value.data(using: .utf8) else { return }
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrSynchronizable as String: false
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        
        if status != errSecSuccess {
            print("❌ Failed to save to keychain: \(status)")
        } else {
            print("✅ Saved '\(key)' to keychain with stable attributes")
        }
    }
}
