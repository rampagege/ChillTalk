# ChillTalk

[简体中文](README.md) | **English**

Voice dictation for the macOS menu bar. Tap a hotkey, speak, tap again — polished text appears at your cursor.

Built for **domain terminology**: a personal vocabulary, learning from your corrections, sound-alike fixes and industry word packs.

## Features

- Global hotkey (Right ⌥ by default), Esc to cancel; text streams in as you speak and is inserted when you finish
- LLM polish: removes filler words, adds punctuation, resolves self-corrections, keeps your meaning
- Vocabulary: hot words, key terms, background context, automatic replacement of misheard spellings, sound-alike correction, industry packs
- Correct a mistake in History and it becomes a rule
- 6 dictation languages, 5 interface languages
- History and usage stats, iCloud sync, optional voice enhancement (echo cancellation + noise suppression)

## Install

**From source** (macOS 14+, Xcode 15+):

```bash
git clone https://github.com/rampagege/ChillTalk.git
cd ChillTalk
./scripts/install.sh   # builds and installs to /Applications; runs without Xcode afterwards
```

Before the first build, set your own Team under Signing & Capabilities in Xcode (a free Personal Team works). A stable signature lets macOS remember the microphone and Accessibility permissions.

**Downloaded builds** are not notarized: on first launch, go to System Settings → Privacy & Security and click **Open Anyway**.

## Usage

1. Grant **Microphone** and **Accessibility** permissions
2. Menu bar icon → Settings… → Speech recognition: pick a provider, enter its API key, click **Test connection**
3. In any text field, tap Right ⌥, speak, tap it again

For Chinese, [Alibaba Cloud Model Studio](https://bailian.console.aliyun.com/) (pay-as-you-go) covers both recognition and polish with one key — about CN¥20/month at 30 minutes of dictation a day.

| Recognition | Price (approx.) | Notes |
|---|---|---|
| Alibaba Cloud Model Studio | CN¥1.2/hour | Recommended for Chinese |
| Soniox | $0.12/hour | Good with mixed Chinese/English |
| Deepgram | $0.46/hour | |
| OpenAI / OpenRouter | $0.36/hour | Uploads after you finish; weaker on Chinese |

## Privacy

Audio goes only to the recognition provider you choose; ChillTalk doesn't keep recordings. API keys live in the macOS Keychain and are never synced or uploaded. History and vocabulary stay on your Mac, with a copy in your iCloud Drive if you turn on sync.

## Development

Native Swift/SwiftUI, no third-party dependencies. Source is under `ChillTalk/`; UI strings are in `Localizable.xcstrings`.

Release: `scripts/release.sh <version>` (universal build, zip, GitHub draft release; `--dry-run` to package only).

## License

MIT
