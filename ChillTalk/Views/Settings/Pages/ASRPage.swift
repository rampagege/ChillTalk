import SwiftUI

struct ASRPage: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        SettingsPageView(title: String(localized: "语音识别"), subtitle: String(localized: "把你说的话转成文字。录音时实时显示，说完即插入。")) {
            Card(title: String(localized: "语言")) {
                CardRow(label: String(localized: "我说的语言"), detail: languageDetail, savedKey: "dictationLanguage") {
                    Picker("", selection: $model.dictationLanguage) {
                        ForEach(DictationLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 260)
                }
                if model.dictationLanguage != .en {
                    CardDivider()
                    CardRow(label: String(localized: "夹杂英文"), detail: String(localized: "说话时会夹带英文单词（如产品名、术语），识别时同时考虑英文"),
                            savedKey: "mixEnglish") {
                        Toggle("", isOn: $model.mixEnglish)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            Card(title: String(localized: "麦克风")) {
                CardRow(label: String(localized: "语音增强"),
                        detail: String(localized: "回声消除 + 降噪 + 自动增益。适合外放音乐或视频、旁边有人说话、小声说话时使用；安静环境下不必开启。开启后会略微压低其他 App 的音量，并可在控制中心的「麦克风模式」里选择「人声隔离」。"),
                        savedKey: "voiceProcessing") {
                    Toggle("", isOn: $model.voiceProcessing)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Card(title: String(localized: "服务")) {
                CardRow(label: String(localized: "服务商"), savedKey: "asrProvider") {
                    Picker("", selection: $model.asrProvider) {
                        ForEach(ASRProviderType.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 260)
                }
                CardDivider()
                CardRow(label: String(localized: "API 密钥"), detail: keyHint, savedKey: keyFieldName) {
                    SecretField(placeholder: keyPlaceholder, text: Binding(
                        get: { model[keyPath: model.asrKeyBinding] },
                        set: { model[keyPath: model.asrKeyBinding] = $0 }
                    ))
                }
                if model.asrProvider == .dashScope {
                    CardDivider()
                    CardRow(label: String(localized: "识别模型"), detail: String(localized: "需为实时流式模型（名称含 streaming 或 realtime）"),
                            savedKey: "dashScopeASRModel") {
                        BrandTextField(placeholder: SettingsManager.defaultDashScopeASRModel,
                                       text: $model.dashScopeASRModel)
                    }
                }
                CardDivider()
                HStack {
                    Link(destination: consoleURL) {
                        Label("获取密钥", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Brand.mint)
                    Spacer()
                    Text(providerNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Card(title: String(localized: "连接")) {
                TestConnectionRow(detail: testDetail) {
                    model.flushPendingSaves()
                    return await ConnectionTester.testASR(provider: model.asrProvider,
                                                          apiKey: model[keyPath: model.asrKeyBinding])
                }
                .id(model.asrProvider)  // reset the result when switching provider
            }
        }
    }

    private var languageDetail: String {
        switch model.dictationLanguage {
        case .zhHans: return String(localized: "识别、润色和按发音纠正都按简体中文处理")
        case .zhHant: return String(localized: "输出繁體中文（台湾用字）；识别结果会自动转为繁体")
        case .yue: return String(localized: "粤语口语，输出繁体并保留粤语用字")
        case .en: return String(localized: "按英文规则识别和润色")
        case .ja: return String(localized: "按日语规则润色：句读点、去除填充词")
        case .ko: return String(localized: "按韩语规则润色：空格、标点、去除填充词")
        }
    }

    private var keyFieldName: String {
        switch model.asrProvider {
        case .dashScope: return "dashScopeKey"
        case .deepgram: return "deepgramKey"
        case .openAIWhisper: return "openAIKey"
        case .openRouter: return "openRouterKey"
        case .soniox: return "sonioxKey"
        case .assemblyAI: return "assemblyAIKey"
        }
    }

    private var keyPlaceholder: String {
        switch model.asrProvider {
        case .dashScope, .openAIWhisper: return "sk-..."
        case .deepgram: return "Deepgram API Key"
        case .openRouter: return "sk-or-v1-..."
        case .soniox: return "Soniox API Key"
        case .assemblyAI: return "AssemblyAI API Key"
        }
    }

    private var keyHint: String? {
        switch model.asrProvider {
        case .dashScope: return String(localized: "同一个密钥也可用于文字润色")
        case .openRouter: return String(localized: "与 OpenRouter 润色共用")
        default: return nil
        }
    }

    private var consoleURL: URL {
        switch model.asrProvider {
        case .dashScope: return URL(string: "https://www.qianwenai.com/")!
        case .deepgram: return URL(string: "https://console.deepgram.com/")!
        case .openAIWhisper: return URL(string: "https://platform.openai.com/api-keys")!
        case .openRouter: return URL(string: "https://openrouter.ai/keys")!
        case .soniox: return URL(string: "https://console.soniox.com/")!
        case .assemblyAI: return URL(string: "https://www.assemblyai.com/dashboard")!
        }
    }

    private var providerNote: String {
        switch model.asrProvider {
        case .dashScope: return String(localized: "实时流式 · 约 ¥1.2/小时")
        case .deepgram: return String(localized: "实时流式 · 普通话（zh-CN）")
        case .openAIWhisper: return String(localized: "说完后整段上传")
        case .openRouter: return String(localized: "实验性 · 说完后整段上传")
        case .soniox: return String(localized: "实时流式 · 约 ¥0.85/小时 · 服务在国外")
        case .assemblyAI: return String(localized: "实时流式 · 约 $0.45/小时 · 新用户送 $50 · 服务在国外")
        }
    }

    private var testDetail: String {
        switch model.asrProvider {
        case .dashScope: return String(localized: "会建立一次识别任务并立即结束，不上传音频")
        case .deepgram: return String(localized: "会建立一次连接并立即断开")
        case .openAIWhisper, .openRouter: return String(localized: "验证密钥是否有效")
        case .soniox, .assemblyAI: return String(localized: "会建立一次连接并立即结束，不上传音频")
        }
    }
}
