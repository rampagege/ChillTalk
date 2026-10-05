# ChillTalk

[简体中文](README.md) | **English**

Voice dictation for the macOS menu bar. Tap a hotkey, speak, tap again — polished text appears at your cursor.

Built for **domain terminology**: a personal vocabulary, learning from your corrections, sound-alike fixes and industry word packs.

## Features

- Global hotkey (Right ⌥ by default), Esc to cancel; choose real-time (text as you speak) or after-you-finish (cheaper, usually more accurate)
- LLM polish: removes filler words, adds punctuation, resolves self-corrections, keeps your meaning
- Vocabulary: hot words, key terms, background context, automatic replacement of misheard spellings, sound-alike correction, industry packs
- Correct a mistake in History and it becomes a rule
- 6 dictation languages, 5 interface languages
- History and usage stats, iCloud sync, optional voice enhancement (echo cancellation + noise suppression)

## Install

Download the latest build from [Releases](https://github.com/rampagege/ChillTalk/releases), unzip it and move ChillTalk.app to Applications. Requires macOS 14+.

This build is not notarized: on first launch, go to System Settings → Privacy & Security and click **Open Anyway**.

## Usage

1. Grant **Microphone** and **Accessibility** permissions
2. Menu bar icon → Settings… → Speech recognition: pick a provider, enter its API key, click **Test connection**
3. In any text field, tap Right ⌥, speak, tap it again

For Chinese, a pay-as-you-go key from the [Qwen AI Platform](https://www.qianwenai.com/) (Alibaba Cloud Model Studio) covers both recognition and polish, with a 90-day free quota for new users — about CN¥20/month at 30 minutes of dictation a day.

| Recognition | Price (approx.) | Notes |
|---|---|---|
| Qwen / Alibaba Cloud Model Studio | CN¥1.2/hour | Recommended for Chinese |
| Soniox | $0.12/hour | Good with mixed Chinese/English |
| AssemblyAI | $0.45/hour | $50 free for new users; mixed Chinese/English |
| Deepgram | $0.46/hour | |
| OpenAI / OpenRouter | $0.36/hour | Uploads after you finish; weaker on Chinese |

## Privacy

Audio goes only to the recognition provider you choose; ChillTalk doesn't keep recordings. API keys live in the macOS Keychain and are never synced or uploaded. History and vocabulary stay on your Mac, with a copy in your iCloud Drive if you turn on sync.

## Development

Native Swift/SwiftUI, no third-party dependencies. Open `ChillTalk.xcodeproj` in Xcode 15+, set Signing to your own Team (a free Personal Team works; a stable signature lets macOS remember permissions), then run `./scripts/install.sh` to build and install to Applications.

## License

MIT
