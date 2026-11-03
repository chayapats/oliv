# Changelog

All notable user-facing changes to OLIV. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/). `scripts/release.sh X.Y.Z` pulls
the matching `## [X.Y.Z]` section (falling back to `## [Unreleased]`) into the
Sparkle appcast's release notes, so keep entries short and end-user readable.

## [Unreleased]
- **Dictate while the models download.** On a new Mac, OLIV no longer has to
  sit idle through the 5 GB download: in Setup, **Try it now through the OLIV
  server** starts a free trial that sends your recordings to the OLIV server
  until the models are ready. It's off unless you choose it, shows as Cloud in
  the menu, the recording pill and Settings, never sends your Dictionary, and
  switches back to your Mac by itself (it tells you when). If the download
  stops, the trial stops too.
- **Report a wrong result.** On the Mac, choose **Recent… ▸ Report a Wrong
  Result**; on iPhone, use the button under a result or in History. You see
  and edit the report first, then it opens as a prefilled GitHub issue in your
  browser. Issues are public, so remove anything private; OLIV sends nothing
  itself and never attaches audio. A report about a Command mode edit or a
  translation also shows the text you selected and what you asked for. On
  iPhone, a recording that failed to send can now be shared from its card.
- **Volume no longer stays low when headphones connect or disconnect while you
  dictate.** With "Lower other audio while dictating" on, AirPods or other
  headphones that drop out mid-dictation get your volume back as soon as they
  reconnect, and your speakers get theirs back as soon as headphones take over.
- **Cleanup leaves your Thai alone.** While restoring English words, OLIV no
  longer turns a misheard name into unrelated Thai words, changes a number, or
  spells Thai names like ณัฐพงศ์ in English letters. Letters from other
  alphabets (Korean, Lao, Russian, …) no longer appear in your text.
- **The same through the OLIV API.** Dictation on iPhone, and with the OLIV API
  engine on Mac, Linux and Windows, gets these cleanup fixes too once the
  server is updated.
- **Command mode: edit selected text by voice.** Select text in any app, hold
  the Command mode shortcut and say what to change: "ทำให้สุภาพขึ้น", "สั้นลง",
  "สรุปเป็น bullet", "แก้คำผิด" or "เขียนเป็นอีเมล". OLIV replaces the
  selection, and your undo shortcut puts the original back. If OLIV isn't sure
  about an edit, your text stays as it was, and if you select something else
  while it works, the edit waits on the clipboard. It runs on your Mac, and
  never in verbatim apps or password managers. Off by default: Settings ›
  Voice editing.
- **Speak Thai, type English.** Set your secondary push-to-talk shortcut, or
  apps you choose, to translate: speak Thai, with English mixed in as usual,
  and OLIV pastes natural English. Names, product names and code terms stay as
  they are, and the recording pill shows "Thai → English" while it's on. Off
  by default.
- **OLIV speaks Thai.** On a Mac set to Thai, the menu, Settings, the setup
  window, recording notices and error messages are in Thai, with the same
  words as the iPhone app. Macs set to other languages keep English.
- **Spell names that are on screen.** Optional, off by default (Settings ›
  Text cleanup). When you start dictating, OLIV reads the window you're typing
  into and spells the names and terms it shows, such as a coworker in a chat or
  a customer in an email, without adding them to your Dictionary. The text stays
  in memory on your Mac for that one dictation and is never saved or sent.
  Password fields, password managers and verbatim apps are skipped, and your
  Dictionary always wins. On a public Thai benchmark, names shown on screen
  were recognized 57% of the time instead of 43%, and a screen full of
  unrelated names changed about 1 in 2,000 dictations for the worse. Works with
  on-device text processing, not yet with the OLIV API engine or the free
  trial.
- **See your words while you speak.** While you hold the key, the recording
  indicator shows what OLIV has heard so far, updated a few times a second, so
  you know early if it misheard. Words that have stopped changing are solid and
  the newest ones dimmer, and English terms, your Dictionary words and numbers
  already look the way they'll be typed. It's a quick on-device preview: the
  text OLIV types still comes from the full pass after you let go, just as fast
  as before. On-device engines only; a slower Mac updates it less often, and
  turns it off if it can't keep up. Turn it off in Settings › General.
- **Corrections that lead into each other apply once.** With rules like
  `foo → docker` and `docker → X`, a word OLIV already corrected is no longer
  corrected again after the cleanup model changes its capitals or spacing.

## [0.2.2] — 2026-10-28
- **Your Dictionary understands Thai spellings.** Thai names and terms in your
  Dictionary now fix near-miss spellings (บางแคร์ → บางแค, พงศ์ → พงษ์), and a
  name you add in English replaces its Thai spelling (คลองเตย → Khlong Toei).
  On a public Thai benchmark, listed names were recognized 63% of the time
  instead of 46%.
- **Fewer wrong substitutions with long lists.** All-caps words (tickers,
  brands) no longer replace everyday Thai words, and words that mix Thai and
  English or use accented letters no longer match fragments of other words.
  Dictation with an empty Dictionary is unchanged.

## [0.2.1] — 2026-10-27
- **One Dictionary for your words.** Vocabulary and Replacements are now a
  single Dictionary: a word, plus an optional correction for what you say or
  what OLIV mishears. Star the words that matter most, turn entries on/off,
  search, bulk delete, and import/export CSV. Your existing lists move over
  automatically; replacements a dictionary entry can't hold (long snippets,
  symbols) stay as "Older snippets" and keep working.
- **Synced across devices.** With the OLIV API, the Dictionary is kept on your
  server and shared with your other devices; edits made offline sync later.
- **Smarter matching.** Corrections ignore letter case and never cut a Thai word
  in half; "SHA สองห้าหก" becomes SHA256 for a word like `SHA256`; and if the
  cleanup model rewrites one of your words (e.g. spells a Thai name in English),
  OLIV keeps your spelling.
- **Suggestions you approve.** Turn on suggestions and OLIV notices when you undo
  a dictation and say it again, or when a newly added word was misheard before.
  Nothing is added until you approve it.
- OLIV API dictation survives a server restart without an error.

## [0.2.0] — 2026-10-11
- **A 5× smaller download, and no Python inside.** Text processing and API
  requests run on a shared Rust core; on-device Whisper and Gemma run with
  native MLX. The installer shrinks from about 123 MB to about 26 MB, and the
  models you already downloaded keep working offline.
- **Redesigned Settings.** A resizable window with searchable sidebar navigation,
  clear sections for shortcuts, audio, engines and cloud services, and consistent
  cards in light and dark mode. Replacements can be edited; model storage includes
  alternative engines and individual download controls.
- **Push-to-talk responds immediately.** Microphone setup runs in the background
  while the indicator shows that it is getting ready. Releasing during setup
  cancels that recording. Failed echo-cancellation routes are remembered across
  launches, avoiding repeated slow setup; toggle Cancel speaker echo off and on
  to retry. Changing devices or macOS also gives echo cancellation a fresh attempt.
- **Know where dictation runs.** The menu, recording indicator and Settings
  show On-device or Cloud with the engine name. The last result shows the
  engine actually used, including Groq's fallback to local transcription.
- **OLIV API engine (opt-in).** Use your own API URL and individual key for
  server transcription and cleanup without downloading local models. Keys live
  in macOS Keychain. Recordings are capped at two minutes; rate limits show a
  wait notice and requests are never automatically resent. Spoken formatting
  commands and saved-audio retry are not available with this engine yet.

## [0.1.11] — 2026-08-10
- **Tech jargon comes back as real English more reliably.** Dense Thai
  syllable-soup from speech-to-text (load balancer, OpenTelemetry, nginx,
  MongoDB, unit test, and similar) is restored more often instead of staying
  garbled or getting dropped by cleanup. Everyday Thai, spoken numbers, and
  format commands stay as they were.

## [0.1.10] — 2026-07-26
- **Music stops ending up in your dictation.** Holding push-to-talk while
  something played on the Mac's own speakers used to put that sound into the
  recording, and it cost twice over: OLIV would invent text out of the music —
  whole confident sentences nobody said — and the words you actually spoke came
  out worse for being buried under it. OLIV now subtracts what your Mac is
  playing from what the mic hears, and briefly dips the volume while you hold
  the key, putting it back the moment you let go. Both are on by default and
  live in Settings › General ("Cancel speaker echo" and "Lower other audio
  while dictating"). Your own volume is left alone if you reach for it
  mid-sentence, and Bluetooth headphones keep their full-quality audio.

## [0.1.9] — 2026-07-19
- **Settings scroll properly again.** As OLIV gained options, the General and
  Cleanup tabs grew taller than the Settings window, so the controls at the top
  and bottom — the push-to-talk key, Launch at login, the list of verbatim
  apps — were cut off with no way to scroll to them. Every tab now scrolls, so
  nothing is out of reach, and the "Push-to-talk key" row lines up with the
  other labelled rows.

## [0.1.8] — 2026-07-18
- **Spoken numbers and repeated words come out tidy.** Say a number and OLIV
  writes it in digits — "สี่สิบห้า" becomes 45, and version numbers like
  "สองจุดสี่จุดหนึ่ง" become 2.4.1. A word you stretch for emphasis becomes the
  proper Thai form with ๆ ("มากมาก" → "มากๆ"), which also cleans up the times
  speech-to-text echoes a word two or three times. Small counts and number
  words inside everyday phrases (ครั้งหนึ่ง, ขอสองแก้ว) are left alone. On by
  default — switch it off in Settings › Cleanup ("Format numbers & repeated
  words") if you'd rather keep everything spelled out.
- **Ready to dictate sooner after you open OLIV.** OLIV now gets speech
  recognition ready first and warms up the cleanup model quietly in the
  background, so you can start talking about 2.5× sooner after launch instead
  of waiting for everything to finish loading.

## [0.1.7] — 2026-07-13
- **Dictation no longer goes silently missing.** If you spoke a short sentence
  while holding the key for a while, OLIV could decide the whole clip was
  silence and type nothing at all — no text, no error, no clue. It now looks for
  speech anywhere in the clip instead of averaging the whole thing, so a short
  sentence inside a long hold is heard.
- **Choose your microphone** (Settings › General). OLIV used to record from
  whatever macOS called the default input — and macOS quietly makes paired
  AirPods the default the moment you connect them. That cost you the first
  second of every sentence (a Bluetooth mic takes up to 3 seconds to wake, and
  it sends pure silence meanwhile) and dropped your music to call quality while
  you dictated. OLIV now uses the **built-in mic by default** and stays there:
  you can wear AirPods to listen, and your music keeps its full quality while
  you talk. Pick a different mic any time — Settings warns you which ones cost
  you audio quality.
- **The mic is never mistaken for the message.** While a Bluetooth mic is still
  waking up, the pill now says "Getting the mic ready" instead of pretending to
  record, and if the mic never wakes at all OLIV tells you so — rather than
  looking exactly like you said nothing.

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
