# Changelog

All notable user-facing changes to OLIV. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/). `scripts/release.sh X.Y.Z` pulls
the matching `## [X.Y.Z]` section (falling back to `## [Unreleased]`) into the
Sparkle appcast's release notes, so keep entries short and end-user readable.

## [Unreleased]

## [0.1.6] — 2026-07-11
- **Recording indicator in OLIV's colors:** the waveform while you speak and
  the "Transcribing…" dots are now OLIV's olive green instead of the system
  blue — matching the app's branding (and the demo on the site).

## [0.1.5] — 2026-07-11
- **Recent transcripts in the menu:** a new "Recent…" submenu keeps your last
  10 dictations, so text that landed in the wrong window (or got replaced on
  the clipboard) is one click away — click an entry to copy it back, then ⌘V.
  Kept in memory only: nothing is saved to disk, quitting clears the list, and
  you can turn it off in Settings › General (which also clears it immediately).
- **Last-dictation stats:** the menu now shows a small line like
  "Last: 1.4s · 38 chars" after each dictation — how long it took and how much
  text was pasted, at a glance.
- **Copy Diagnostics:** a new menu item copies a plain-text support report
  (version, macOS, engine, settings, permissions, model status) to the
  clipboard — one paste answers "what's your setup?" when reporting a problem.
  It never includes your transcripts or your cloud API key.
- **Interrupted downloads are detected:** a model download that was cut off
  midway no longer counts as installed (which made the first dictation fail) —
  OLIV now checks the model's files are actually complete and offers the
  download again.
- **Download progress in Settings › General:** the engine-download row shows a
  real progress bar instead of a spinner.
- **Settings window opens in front** instead of hiding behind other windows.

## [0.1.4] — 2026-07-11
- **Engine picker knows what's downloaded:** Settings › General now marks speech
  engines whose model isn't on your Mac as "(not downloaded)" and offers a
  one-click download with live progress — instead of the first dictation
  failing with a generic error.
- **Switching engines frees memory:** changing the STT engine now releases the
  previous model's memory before loading the new one, so a switch no longer
  holds two models at peak.
- **10-minute recording ceiling:** a single hold is now capped at 10 minutes
  (far beyond any real utterance — this guards against a stuck key). Hitting
  the cap shows a notice instead of silently cutting the audio.
- **Sturdier audio teardown:** one wedged microphone shutdown can no longer slow
  down every later dictation.
- **Small fixes:** the Setup window stops its background polling once closed;
  the release pipeline now refuses to build with incomplete code signing.

## [0.1.3] — 2026-07-11
- **Update feed moved to OLIV's main repository** (github.com/chayapats/oliv) —
  downloads and future updates now live in one place. No functional changes.

## [0.1.2] — 2026-07-10
- **Better speech model:** OLIV now uses Typhoon Whisper Turbo for speech plus a
  smaller Gemma-E2B cleanup pass — more accurate on unfamiliar English/tech terms
  and about half the size of the previous model.
- **No more stray characters on silence:** pressing the push-to-talk key without
  speaking no longer types random (often Chinese) characters.
- **Fixed a freeze on quit:** the app could hang (“not responding”) when quitting
  right after granting a permission — it now quits instantly.
- **Fixed “transcribing…” hanging forever:** models load fully offline, so a slow
  or unreachable network can no longer stall a dictation.
- **Custom vocabulary:** a new Settings › Vocabulary list of your terms (names,
  jargon, product names, acronyms). OLIV biases recognition toward them, so a
  word it kept mishearing is transcribed right from the start — unlike
  Replacements, which only rewrite text after the fact.
- **Spoken formatting commands (opt-in):** say “new line / ขึ้นบรรทัดใหม่”,
  “new paragraph / ย่อหน้าใหม่”, or “bullet point” to insert line breaks. Off by
  default (Settings › Cleanup) since a command phrase can also be real text.
- **You now see when something goes wrong:** if a dictation can’t be transcribed,
  or the text can’t be pasted (missing Accessibility, or a password field is
  focused), OLIV shows a brief notice and leaves the text on the clipboard for a
  manual ⌘V — instead of silently dropping it.

## [0.1.1] — 2026-07-08
- OLIV now has an app icon (the olive + voice-wave mark) — in Finder, in the
  permission dialogs, and on the disk image.
- New drag-to-install disk image: a proper installer window with a background,
  an arrow to the Applications folder, and the OLIV volume icon.

## [0.1.0] — 2026-07-07
- First self-contained OLIV.app: fully local Thai + English push-to-talk
  dictation on Apple Silicon (embedded CPython sidecar — MLX Whisper for speech
  plus a Gemma-4 de-transliteration cleanup pass; no cloud unless you opt in).
- Menu-bar app: hold the push-to-talk key, speak, release, and the text is
  pasted at the cursor in any app.
- Auto-updates via Sparkle: automatic background checks plus a "Check for
  Updates…" menu item; updates are EdDSA-signed.
- Hardened runtime enabled (mic entitlement for capture; JIT/library-validation
  exceptions scoped to the embedded interpreter) — notarization-ready.
