<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/oliv-mark-white-160.png">
  <img src="docs/img/oliv-mark-160.png" alt="OLIV logo — an olive with a voice waveform" width="80">
</picture>

# OLIV — Offline Local Inference Voice

[![License: MIT](https://img.shields.io/github/license/chayapats/oliv?color=57761f)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B%20Apple%20Silicon-111111)](#requirements)
[![Release](https://img.shields.io/github/v/release/chayapats/oliv?color=57761f)](https://github.com/chayapats/oliv/releases/latest)

**Thai + English push-to-talk dictation for macOS, local by default.**
Open-source voice typing: hold a key, speak Thai mixed with English, and OLIV types into the frontmost app. Speech-to-text runs on your Apple Silicon Mac by default. Optional remote engines upload audio only when enabled and selected.

> 🇹🇭 **ย่อ:** พิมพ์ด้วยเสียง ไทยปนอังกฤษ บน Mac ค่าเริ่มต้นทำงานในเครื่อง; remote engines ส่งเสียงเมื่อเปิดและเลือกใช้งานเท่านั้น
> STT ไทยมักเขียนคำอังกฤษเป็นตัวไทยเพราะเสียงคล้าย (`ดีพลอย`, `เกรดเวย์`) — OLIV คืนมันกลับเป็น `deploy`, `gateway`
> **[อ่าน README ภาษาไทยฉบับเต็ม →](README.th.md)**

<a href="https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg"><img src="https://img.shields.io/github/v/release/chayapats/oliv?style=for-the-badge&label=%E2%AC%87%EF%B8%8F%20%20Download%20for%20macOS&color=57761f" alt="Download OLIV for macOS — one click, the .dmg downloads immediately"></a>

**One click — the `.dmg` downloads immediately.** Apple Silicon (M1+) · free & open source · [all versions](https://github.com/chayapats/oliv/releases)

<img src="docs/img/oliv-demo.gif" alt="Demo: OLIV hears Thai-transliterated tech terms and types them back in English" width="840">

📊 **[Honest benchmark & how accurate it is →](https://chayapats.github.io/oliv/)** · 
the full write-up lives in [`docs/index.html`](docs/index.html) (bilingual, reproducible, failures shown).

---

## What it does

Thai speech-to-text writes English words in Thai script because they sound alike. OLIV's pipeline restores just those words and nothing else:

```
heard   ตัวบิวท์เฟลล์เพราะดิเพนเดนซี่เวอร์ชั่นไม่ตรง
OLIV →  ตัว build fail เพราะ dependency version ไม่ตรง
```

Pipeline: **Typhoon-turbo STT** (Thai fine-tune of Whisper-turbo) → deterministic dictionary/phonetic fixes → a small **Gemma-E2B** cleanup model that de-transliterates. Everything runs on-device.

## How accurate — honestly

Meaning-match (LaBSE semantic similarity, a clip counts at ≥ 0.80 — **this is not word-for-word accuracy**), fresh run of the shipped pipeline:

| Set | Meaning match | n |
|---|---|---|
| **Held-out** (fresh jargon, never tuned on) | **~95%** | 40 |
| Tuning | ~98% | 194 |
| Confirmation | ~97% | 30 |

- The cleanup model earns its keep: on the held-out set, **without it the number falls to ~65%**.
- Against the cloud: OLIV's full local pipeline beats raw Groq-hosted Whisper large-v3 (~84%) — while staying private and about half the size. But note: OLIV's *raw* STT is actually a bit *weaker* than the big cloud model; the win is the full pipeline, not raw transcription.

**Read the [limitations](docs/index.html) before trusting these numbers** — especially: the benchmark was recorded by **one speaker** (the developer), so cross-speaker/accent/noise performance is untested. Names and numbers can be wrong even when meaning counts as a match — glance before sending.

## Requirements

- **Apple Silicon** Mac (M1 or newer), macOS
- For local engines, one-time model download **≈ 5 GB**, pulled from Hugging Face on first run:
  - STT ~1.5 GB — [`chayapats/typhoon-whisper-turbo-mlx`](https://huggingface.co/chayapats/typhoon-whisper-turbo-mlx) (our MLX conversion of SCB 10X's Typhoon)
  - Cleanup ~3.3 GB — [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)
- Fully offline after that · ~1.1–1.3 s per phrase
- OLIV API mode needs a connection and an individual API key instead of local models.

## Install

1. [**Download OLIV.dmg**](https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg) (or pick a version from [Releases](https://github.com/chayapats/oliv/releases))
2. Open it, drag **OLIV** into **Applications**, launch
3. Grant microphone + accessibility permissions, set a push-to-talk hotkey in Settings

## Features & what you can customize

More than the defaults suggest — everything lives in the menu-bar olive icon and **Settings…** (⌘,).

**The menu**
- **Engine location** — `On-device · Typhoon`, `Cloud · OLIV API`, or `Cloud · Groq` in the menu and recording indicator. Enabling a remote engine makes it available; select it in General to use it.
- **Recent…** — your last 10 dictations; click one to copy it back (⌘V to paste). In memory only: quitting clears it, and a Settings toggle turns it off (clearing immediately).
- **Last-dictation line** — shows the engine actually used, duration and character count, including local fallback when Groq fails.
- **Copy Diagnostics** — one-click plain-text support report (app/OS versions, engine, toggles, permissions, model status). Never includes transcripts or your API key.

**General**
- Microphone setup runs in the background with an immediate getting-ready
  indicator. Release before it is ready to cancel. If echo cancellation fails,
  OLIV remembers that audio route across launches and uses the regular microphone
  with your audio-lowering setting. Toggle **Cancel speaker echo** off and on to
  retry; a device or macOS change also allows another attempt. **Copy Diagnostics**
  includes the last microphone startup time and actual capture backend.
- **Push-to-talk key** — default is Right ⌥ Option; record any key you like, applied live.
- **STT engine** — Thai-first Typhoon turbo (default), Pathumma (legacy), or English-heavy Whisper large-v3. Missing engine weights download in place with a progress bar.
- **Recording indicator** — the floating waveform pill; can be hidden.
- **Launch at login**, recent-transcripts toggle.
- **Cloud fallback (opt-in, OFF by default)** — a Groq large-v3 cloud engine appears only after you enable it *and* add an API key. Audio is sent to Groq only while that engine is selected.
- **OLIV API (opt-in, OFF by default)** — in General, enable OLIV API, set the base URL (default `https://oliv.redcomp.tech`) and an individual key with `dictate` access, then select **OLIV API (remote)** as the dictation engine. Transcription and cleanup run on the server; no local model downloads are required. Keys are stored separately in macOS Keychain. The connection check is unauthenticated liveness only. Recordings are limited to two minutes, requests are not resent automatically, and 429/503 responses can require a cooldown. This engine does not yet support spoken formatting commands or saving failed audio for retry. Local/Groq settings are kept when switching engines.

**Cleanup**
- Global cleanup on/off; **filler-word removal** (อืม/เอ่อ/um…, on by default); **spoken formatting commands** ("new line / ขึ้นบรรทัดใหม่", "new paragraph / ย่อหน้าใหม่", "bullet point" — off by default, since a command phrase can be real content).
- **Per-app verbatim list** — apps where text pastes exactly as heard, no cleanup (terminals, password managers…).

**Replacements** — spoken phrase → exact text, e.g. "อีเมลของผม" → `me@example.com`. Rewrites *after* transcription.

**Vocabulary** — your names/jargon/acronyms bias *recognition itself*, so a word STT kept mishearing comes out right from the start — the fix for a term Replacements can't catch reliably.

**Models** — what's downloaded, sizes, storage path, re-download / re-check.

## Reproduce the benchmark

The eval harness drives the **real shipping code path** (not a re-implementation):

```bash
# fresh benchmark of the shipped config over all sets:
# (model repos default to the shipped ones; point OLIV_TYPHOON_MLX_REPO at a
#  local path or another HF repo only if you want to swap the STT weights)
HF_HUB_DISABLE_XET=1 \
  sidecar/.venv/bin/python benchmark/eval_cleanup.py \
    --manifest data/manifest_all.jsonl --engine typhoon-turbo-mlx --out benchmark/eval_results/ship_main.json
sidecar/.venv/bin/python benchmark/semantic_score.py     # LaBSE meaning over eval_results/*.json
sidecar/.venv/bin/python benchmark/build_report_data.py  # + surface metrics -> report_data.json
sidecar/.venv/bin/python benchmark/build_landing.py      # regenerate docs/index.html
```

Manifests: `benchmark/data/manifest_{all,holdout,d2}.jsonl` (264 clips; audio not tracked). Metric: `benchmark/semantic_score.py` (LaBSE, Thai word-segmented before embedding, threshold 0.80).

## Build from source

Apple Silicon Mac, macOS 14+. Full notes in [CONTRIBUTING.md](CONTRIBUTING.md).

```bash
brew install xcodegen
python3.11 -m venv sidecar/.venv
sidecar/.venv/bin/pip install -r sidecar/requirements.lock
( cd macos && xcodegen generate )
bash scripts/build_app.sh    # -> build/OLIV.app
```

## Contributing

Bug reports and pull requests are welcome — Thai or English.
Please read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).
Security reports: [SECURITY.md](SECURITY.md), not a public issue.

## License

- **Models:** Typhoon-whisper-turbo weights are MIT, inherited from SCB 10X's [`typhoon-ai/typhoon-whisper-turbo`](https://huggingface.co/typhoon-ai/typhoon-whisper-turbo) and OpenAI Whisper — OLIV ships [an MLX conversion](https://huggingface.co/chayapats/typhoon-whisper-turbo-mlx) of those weights, all credit for the model to the original authors. The cleanup model follows its own upstream license.
- **App / code:** [MIT](LICENSE) — © 2026 Chayapat Sriwattanachote.

Third-party names (Groq, Whisper, etc.) belong to their owners; benchmark comparisons are on our own Thai–English dictation set, tested once.
