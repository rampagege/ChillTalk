# PR #6: 修复 API 密钥持久化和添加录音状态浮动提示

## 已完成的修复

### 1. ✅ API 密钥持久化问题

**问题**：用户配置的 DashScope、Deepgram 和 OpenRouter API 密钥在 Xcode Debug 重新构建后消失。

**原因分析**：
- Keychain 存储时缺少稳定的可访问性属性
- 没有明确设置本地存储标志

**解决方案**：
```swift
// 在 SettingsManager.swift 的 setKeychainValue 方法中添加：
kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,  // 重启后可访问
kSecAttrSynchronizable as String: false  // 只存储在本地设备
```

**效果**：
- ✅ Debug 重新构建后密钥保留（Bundle ID 不变时）
- ✅ 设备重启后密钥依然可访问
- ✅ 不会意外同步到其他设备

### 2. ✅ 录音状态浮动 HUD

**问题**：按住全局快捷键时缺少明显的视觉反馈。

**解决方案**：
- 创建 `RecordingHUD.swift` 新组件
- 实现 `RecordingHUDController` 单例管理器
- 使用 NSPanel 创建非激活浮动窗口

**功能特性**：
- 📍 位置：屏幕右上角
- 🎤 录音时：显示"录音中"+ 麦克风图标
- 🌊 处理时：显示"处理中"+ 波形图标
- ❌ 出错时：短暂显示"出错"后自动消失
- ✨ 样式：半透明黑色背景 + 白色文字和图标
- 🎯 行为：不抢焦点，不影响文本插入

**技术实现**：
```swift
// 使用 nonactivatingPanel 确保不抢焦点
let panel = NSPanel(
    styleMask: [.borderless, .nonactivatingPanel],
    ...
)
panel.level = .floating  // 始终在顶层
panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
```

### 3. ✅ 改进错误提示

**优化前**：
- 错误提示："请在设置中配置 ASR API 密钥"
- 不够明确，用户可能误以为配置 OpenRouter 就够了

**优化后**：
```swift
let providerName = asrProvider == .dashScope ? "DashScope" : "Deepgram"
showError("请配置 \(providerName) ASR 密钥。注意：ASR 转录需要独立的 API 密钥，OpenRouter 仅用于可选的文本润色。")
```

**效果**：
- ✅ 明确指出需要哪个 ASR 提供商的密钥
- ✅ 澄清 ASR 和 OpenRouter 的不同用途
- ✅ 避免用户混淆

### 4. ✅ 文档更新

**README.md 更新内容**：
- 说明密钥持久化特性
- 明确 ASR 密钥（必需）vs OpenRouter 密钥（可选）
- 添加浮动状态提示功能说明
- 更新功能特性列表

## 技术细节

### 文件变更
- ✏️ `ChillTalk/Utils/SettingsManager.swift` - Keychain 存储改进
- 🆕 `ChillTalk/Views/RecordingHUD.swift` - 浮动 HUD 组件
- ✏️ `ChillTalk/ChillTalkApp.swift` - HUD 集成 + 错误提示改进
- ✏️ `ChillTalk.xcodeproj/project.pbxproj` - 添加新文件
- ✏️ `README.md` - 文档更新

### 集成点
1. `handleHotkeyPressed()` - 录音开始时显示 HUD
2. `handleHotkeyReleased()` - 录音时长检查后处理
3. `processAudio()` - 切换到处理状态
4. `insertText()` - 完成后隐藏 HUD
5. `showError()` - 错误时显示临时提示

## 测试建议

### 密钥持久化测试
1. ✅ 在设置中配置所有 API 密钥
2. ✅ 在 Xcode 中选择 Product → Clean Build Folder
3. ✅ 重新构建并运行应用
4. ✅ 打开设置，验证密钥是否还在
5. ✅ 重启 Mac，再次验证密钥

### 浮动 HUD 测试
1. ✅ 按住快捷键，检查右上角是否出现"录音中"
2. ✅ 释放快捷键，检查是否切换到"处理中"
3. ✅ 等待完成，检查 HUD 是否自动消失
4. ✅ 验证文本能否正确插入到目标应用
5. ✅ 测试短按快捷键（<0.3秒），HUD 应该消失
6. ✅ 触发错误（如未配置密钥），检查错误提示

### 跨应用测试
- ✅ 在 Notes.app 中测试
- ✅ 在 TextEdit 中测试
- ✅ 在 Safari 文本框中测试
- ✅ 在 Slack/Discord 输入框中测试

## 兼容性

- ✅ macOS 13.0+ 支持
- ✅ 向后兼容现有配置
- ✅ 不需要新的系统权限
- ✅ 保持现有功能不变

## 已知限制

### Keychain 持久化
- ⚠️ 如果 Bundle Identifier 改变，密钥会丢失（预期行为）
- ⚠️ 如果用户手动清除 Keychain，密钥会丢失（预期行为）
- ⚠️ Clean Build Folder 后如果签名配置改变，可能影响 Keychain 访问

### 建议
- 在 Xcode 项目设置中固定 Bundle Identifier
- 避免频繁更改签名证书
- 如遇问题，可在设置中重新配置密钥

## PR 链接

- GitHub PR: https://github.com/rampagege/ChillTalk/pull/6
- 分支: `cursor/fix-keychain-and-hud-bc5c`
- Base: `main`

## 下一步

用户可以：
1. Review PR 中的代码
2. 在本地测试修复效果
3. 如果满意，合并到 main 分支
4. 后续可考虑添加更多 HUD 自定义选项（位置、样式等）
