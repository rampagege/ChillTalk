# ChillTalk

[简体中文](README.md) | **English**

Voice dictation for the macOS menu bar. Tap a hotkey, speak, tap again — polished text appears at your cursor.

Built for **domain terminology**: a personal vocabulary, learning from your corrections, sound-alike fixes and industry word packs.

## Why

Typeless is great, but it's a monthly subscription with way more features than I'll ever touch. I just want to talk and have the words show up at my cursor. That's it.

ChillTalk does just that. It calls the Qwen API directly (or AssemblyAI, Deepgram, Soniox, OpenAI or OpenRouter, your pick) and you pay for what you use. With Qwen, half an hour a day comes to about CN¥10 a month, and the free quota for new accounts covers the first few months.

## Features

- Global hotkey (Right ⌥ by default), Esc to cancel; choose real-time (text as you speak) or after-you-finish (cheaper, usually more accurate)
- Six recognition providers: Qwen / Alibaba Cloud Model Studio, AssemblyAI, Deepgram, Soniox, OpenAI, OpenRouter; pick the Qwen model per mode
- LLM polish: removes filler words, adds punctuation, resolves self-corrections, keeps your meaning
- Vocabulary: hot words, key terms, background context, automatic replacement of misheard spellings, sound-alike correction, industry packs
- Correct a mistake in History and save it as a rule in one click
- 6 dictation languages, 5 interface languages
- History and usage stats, iCloud sync, optional voice enhancement (echo cancellation + noise suppression)

## Install

Download the latest `.dmg` from [Releases](https://github.com/rampagege/ChillTalk/releases), open it and drag ChillTalk onto the Applications folder. Requires macOS 14+.

This build is not notarized: on first launch, go to System Settings → Privacy & Security and click **Open Anyway**.

## Usage

1. Grant **Microphone** and **Accessibility** permissions
2. Menu bar icon → Settings… → Speech recognition: pick a provider, enter its API key, click **Test connection**
3. In any text field, tap Right ⌥, speak, tap it again

For Chinese, one pay-as-you-go key from the [Qwen AI Platform](https://www.qianwenai.com/) (Alibaba Cloud Model Studio) covers both recognition and polish.

| Recognition | Price (approx.) | Free for new users | Notes |
|---|---|---|---|
| Qwen / Alibaba Cloud Model Studio | Real-time CN¥0.5/hour<br>After you finish CN¥0.1/hour | For 90 days, **per model**: 10 hours for per-second models, 1M tokens (≈12 hours) for the 3.1 series | Recommended for Chinese; the same key works for polish |
| AssemblyAI | Real-time $0.45/hour<br>After you finish $0.21/hour | $50, no expiry, no card | Hosted in the US |
| Deepgram | $0.46/hour | $200, no expiry, no card | Real-time only; Chinese as Mandarin |
| Soniox | $0.12/hour | None (ended Oct 2025) | Real-time only; good with mixed Chinese/English |
| OpenAI / OpenRouter | ≈$0.36/hour | None | After you finish only; weaker on Chinese |

Prices and free quotas as of October 2026; check each provider's site. Remaining quota is shown in each provider's console.

## Privacy

Audio goes only to the recognition provider you choose; ChillTalk doesn't keep recordings. With polish on, the recognized text goes to the polish provider you choose. API keys live in the macOS Keychain and are never synced or uploaded. History and vocabulary stay on your Mac, with a copy in your iCloud Drive if you turn on sync.

## License

MIT
