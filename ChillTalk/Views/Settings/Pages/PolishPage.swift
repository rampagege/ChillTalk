import SwiftUI

struct PolishPage: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        SettingsPageView(title: String(localized: "文字润色"), subtitle: String(localized: "用大模型补标点、去口头禅、修正中英文格式，不改变原意。")) {
            Card {
                CardRow(label: String(localized: "启用润色"), detail: String(localized: "关闭后直接插入识别原文"), savedKey: "polishEnabled") {
                    Toggle("", isOn: $model.polishEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Card(title: String(localized: "输出")) {
                CardRow(label: String(localized: "句末加句号"),
                        detail: String(localized: "关闭后去掉最后的「。」或「.」，问号和感叹号保留；不开润色也生效"),
                        savedKey: "keepsTrailingPeriod") {
                    Toggle("", isOn: $model.keepsTrailingPeriod)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Card(title: String(localized: "服务")) {
                CardRow(label: String(localized: "服务商"), savedKey: "polishProvider") {
                    Picker("", selection: $model.polishProvider) {
                        ForEach(PolishProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                CardDivider()
                CardRow(label: String(localized: "API 密钥"),
                        detail: model.polishProvider == .dashScope ? String(localized: "与语音识别共用，数据只经过阿里云") : nil,
                        savedKey: model.polishProvider == .dashScope ? "dashScopeKey" : "openRouterKey") {
                    SecretField(placeholder: model.polishProvider == .dashScope ? "sk-..." : "sk-or-v1-...",
                                text: Binding(
                                    get: { model[keyPath: model.polishKeyBinding] },
                                    set: { model[keyPath: model.polishKeyBinding] = $0 }
                                ))
                }
                CardDivider()
                if model.polishProvider == .dashScope {
                    CardRow(label: String(localized: "模型"), detail: String(localized: "默认 qwen3.8-flash，已关闭思考模式以降低延迟"),
                            savedKey: "dashScopePolishModel") {
                        BrandTextField(placeholder: PolishProvider.dashScope.defaultModel,
                                       text: $model.dashScopePolishModel)
                    }
                } else {
                    CardRow(label: String(localized: "模型"), savedKey: "openRouterModel") {
                        BrandTextField(placeholder: PolishProvider.openRouter.defaultModel,
                                       text: $model.openRouterModel)
                    }
                }
                CardDivider()
                TestConnectionRow(detail: String(localized: "发送一句测试文字，确认密钥和模型可用")) {
                    model.flushPendingSaves()
                    return await ConnectionTester.testPolish(provider: model.polishProvider,
                                                             apiKey: model[keyPath: model.polishKeyBinding],
                                                             model: model.polishModel)
                }
                .id(model.polishProvider)
            }
            .disabled(!model.polishEnabled)
            .opacity(model.polishEnabled ? 1 : 0.5)
        }
    }
}
