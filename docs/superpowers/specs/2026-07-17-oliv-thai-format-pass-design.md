# OLIV Thai-Formatting Post-Pass — Design (2026-07-17)

Status: APPROVED — decisions D1–D6 resolved by the user; this spec is the implementation
contract. Do not relitigate the decisions; identifiers below are final.

## Goal

A **deterministic** Thai-formatting post-pass applied to the FINAL cleaned dictation text,
behind ONE Settings toggle (default ON). Two transforms:

- **(A) Reduplication**: adjacent identical Thai word tokens collapse to `word + "ๆ"`.
- **(B) Numbers → Arabic**: maximal runs of Thai numeral words become Arabic digits when
  the value is ≥ 10, plus a `จุด` version/decimal form.

## Why deterministic, not an LLM prompt edit

`benchmark/pipeline.py:211` — `_gate(dict_text, dict_hits)` returns
`(False, "clean-thai", ...)` for pure-Thai utterances with **no dictionary hits and no
suspect tokens**, which SKIPS the Gemma LLM entirely. So utterances like
`ตลอดตลอด` or `สี่สิบห้า` never reach the model; a prompt edit cannot touch them.
A deterministic pass placed beside `normalize_thai_spacing` / `apply_canonical_casing`
runs on BOTH the LLM path and the gate-skip path, which is required.

## Transform A — Reduplication

Adjacent identical Thai-word tokens (from the shared newmm tokenization) collapse to
`token + "ๆ"`. Runs of 3+ identical tokens collapse to a single `ๆ`.

**Gate**: the token must be a REAL Thai word — membership in a module-level cached
`frozenset(pythainlp.corpus.thai_words())` — so STT garbles are never reduplicated.

**Stoplist (D5, initial, tunable)** — grammatical particles whose doubling is far more
likely an STT stutter than intended reduplication; these stay untouched:

```
ไม่ ก็ ที่ จะ นะ ค่ะ ครับ คะ
```

Examples (positive):

| input | output |
|---|---|
| มากมาก | มากๆ |
| ตลอดตลอด | ตลอดๆ |
| มากมากมาก | มากๆ (3+ → one ๆ) |
| ดีดีเลย | ดีๆเลย |

Negative cases (MUST stay unchanged):

| input | why unchanged |
|---|---|
| จริงจัง | single newmm token — no adjacent pair exists |
| ไม่ไม่ | stoplist |
| ที่ที่ | stoplist |
| any doubled non-word garble | fails the thai_words() real-word gate |

## Transform B — Numbers → Arabic

Walk the shared newmm token list. A **maximal run of consecutive numeral tokens** is
joined and passed to `pythainlp.util.words_to_num`; convert **only when value ≥ 10**
(D1). Lone 1–9 words stay Thai so natural speech stays natural.

**จุด rule**: a `จุด` token flanked by numeral runs on BOTH sides marks a
version/decimal — each segment is converted independently and joined with `"."`.
The จุด path **ignores** the ≥ 10 threshold (each segment may be < 10).

Examples (positive):

| input | output |
|---|---|
| สี่สิบห้า | 45 |
| เก้าสิบเก้า | 99 |
| สองจุดห้า | 2.5 |
| สองจุดสี่จุดหนึ่ง | 2.4.1 |

Negative cases (MUST stay unchanged):

| input | why unchanged |
|---|---|
| ขอสองแก้ว | สอง = 2 < 10, no จุด flank |
| ครั้งหนึ่ง | single newmm token; words_to_num fails on the whole token |
| บ่ายสอง | สอง = 2 < 10 |
| สามารถ / เก้าอี้ / ห้าม | hidden numeral syllables, but words_to_num fails on the whole token |

**Spacing (D4)**: digits stay glued to adjacent Thai text — `อายุสี่สิบห้าปี → อายุ45ปี`
is only produced when newmm splits the numeral run out; we do NOT insert spaces around
converted digits. Minimal change; no spacing logic.

## Resolved decisions (D1–D6)

- **D1** Number aggressiveness: cardinals ≥ 10 convert; lone 1–9 stay words;
  version/decimal via จุด (threshold-exempt).
- **D2** Delivery: ONE Settings toggle covering BOTH transforms, **default ON**.
- **D3** Verbatim apps (cleanup bypassed) must ALSO skip this pass — "verbatim = exactly
  what I said". Wiring: DictationController sends `thaiFormat && cl` where `cl` is the
  same `resolveCleanup(...)` result already passed as `cleanup`, so verbatim/cleanup-off
  dictation never sends the flag and gets raw text.
- **D4** Number spacing: none — digits glued to Thai.
- **D5** Reduplication stoplist: `ไม่ ก็ ที่ จะ นะ ค่ะ ครับ คะ` (module constant, tunable).
- **D6** Sub-pass order: reduplication FIRST, then numbers — a doubled numeral word must
  not become `ๆ` before the number pass sees it... and conversely a collapsed pair must
  not feed the number-run joiner. Both sub-passes share ONE token list: pass A rewrites
  the token list (replacing a run with `token + "ๆ"`), pass B scans the rewritten list.

## Module contract

- **File**: `sidecar/thai_format.py` (new; the Python sidecar is copied wholesale into
  the app bundle — NOT part of the Xcode project).
- **Public API**: `apply_thai_format(text: str) -> tuple[str, int]` — returns
  `(formatted_text, n_changes)` where `n_changes` = number of reduplication collapses +
  number of converted number runs. `(text, 0)` on the short-circuit paths.
- Helpers stay pure and importable for tests (e.g. `_collapse_reduplication(tokens)`,
  `_convert_numbers(tokens)`, `_num(tok)`).
- **Reconstruction**: tokenize with `word_tokenize(text, engine="newmm",
  keep_whitespace=True)` and rebuild by pure concatenation, so all non-numeral /
  non-repeat text — including spaces and the `"\n"` separators inserted by format
  commands — is preserved byte-for-byte.

## Latency requirement + plan (HARD)

The pass must add NO perceptible latency. Mandatory optimizations:

1. **Toggle OFF ⇒ zero work**: Swift omits `thai_format` from the wire when off
   (omit-when-default idiom); the sidecar handler doesn't even call the module.
2. **Thai-presence short-circuit**: a module-level precompiled regex for
   `[฀-๿]`; no match ⇒ return `(text, 0)` immediately, before any tokenize.
3. **Single tokenization**: `newmm` with `keep_whitespace=True` runs EXACTLY ONCE per
   call; the token list is shared by sub-pass A and sub-pass B. Never tokenize twice.
4. **Module-level constants, no per-call imports**: precompiled regexes; one cached
   `frozenset(thai_words())`; a small numeral-component word set
   (ศูนย์ หนึ่ง สอง ยี่ สาม สี่ ห้า หก เจ็ด แปด เก้า เอ็ด สิบ ร้อย พัน หมื่น แสน ล้าน, จุด)
   used as a cheap membership pre-check so `words_to_num` (try/except) is attempted only
   on plausible numeral tokens. All built at import time — the sidecar already imports
   pythainlp at startup, so incremental import cost is negligible and paid once.
5. **Evidence required**: a micro-benchmark (`time.perf_counter`, median over ~10
   representative utterances, measured AFTER a warmup tokenize so the newmm trie is
   built) pasted into the review. Target: low single-digit ms median — negligible next
   to STT + Gemma (hundreds of ms). Run with `sidecar/.venv/bin/python`.

## End-to-end plumbing (touch list)

Mirror the existing `format_commands` toggle EXACTLY. Wire contract:

| item | value |
|---|---|
| wire key | `"thai_format"` (sent only when true) |
| reply counter | `"thai_format_fired"` (int, default 0) |
| Swift prop | `thaiFormat` |
| UserDefaults key | `"oliv.thaiFormat"` |
| default | ON (`?? true` in init read) |
| UI label | "Format numbers & repeated words" |
| UI caption | "Collapses repeated words to ๆ (มากมาก → มากๆ) and writes spoken numbers from ten up as digits (สี่สิบห้า → 45, สองจุดห้า → 2.5). Small counts stay words. On by default." |

Files (paths relative to repo root):

1. **macos/OLIV/OLIVSettings.swift** — `Key` enum (~line 36): add
   `static let thaiFormat = "oliv.thaiFormat"`; `@Published var thaiFormat: Bool` with
   persisting `didSet` firing `onChange?()` (pattern at 111–113 / 145–147); init read
   `thaiFormat = defaults.object(forKey: Key.thaiFormat) as? Bool ?? true` (pattern at
   209/213 — default ON).
2. **macos/OLIV/SettingsView.swift** — `CleanupSettingsView` (struct @331): insert
   `Toggle` + caption `Text` + `Divider` right after the format-commands block
   (~line 357), BEFORE `Text("Verbatim apps ...")` at 359. Same shape as siblings.
3. **macos/OLIV/DictationController.swift** — stored `var thaiFormat: Bool = true`
   (near 50/60); release-time snapshot `let thaiFormat = self.thaiFormat` (near
   359–362); in the `dictateWithFallback` closure (413–418) pass
   `thaiFormat: thaiFormat && cl` — `cl` is the effective cleanup bool the closure
   already receives, so D3 (verbatim/cleanup-off skips formatting) is enforced per
   attempt with the exact same resolution as `cleanup`.
4. **macos/OLIV/SidecarClient.swift** — `dictate(...)` signature (307–311): add
   `thaiFormat: Bool = false`; JSON body (313–325): `if thaiFormat { body["thai_format"]
   = true }` (omit-when-default); `DictationResult` gains
   `thaiFormatFired: (reply["thai_format_fired"] as? NSNumber)?.intValue ?? 0`
   (mirror `formatCommandsFired` at 338).
5. **macos/OLIV/AppDelegate.swift** — seed `controller.thaiFormat = settings.thaiFormat`
   at init (pattern 63/66) and in `applyLiveSettings()` (pattern 95/98); feed the
   diagnostics builder call (near 168–169).
6. **macos/OLIV/Diagnostics.swift** — builder param (near 16) + render line (near
   30–31): `"Thai format: \(onOff(thaiFormat))"`.
7. **sidecar/sidecar_server.py** — reply init (786–788): add
   `"thai_format_fired": 0,`. **Apply point**: immediately after
   `reply["final"] = info["final"]` (line 833), i.e. AFTER the whole per-segment
   pipeline (`_clean_and_replace_segments`: clean_ex → replacements →
   normalize_thai_spacing → `_join_format`) — the pass runs LAST on the final rejoined
   text, so it covers the LLM path, the clean-thai gate-skip path, and format-command
   rejoins alike:

   ```python
   if req.get("thai_format", False) and reply["final"].strip():
       reply["final"], reply["thai_format_fired"] = apply_thai_format(reply["final"])
   ```

   `from thai_format import apply_thai_format` at module top level (no per-call import).
   D3 is already enforced upstream (Swift only sends the flag when cleanup is
   effective); the sidecar still touches `reply["final"]` only when the flag is present.
8. **sidecar/thai_format.py** — the new module (contract above).

## Test plan

- **sidecar/test_text_passes.py** (run:
  `sidecar/.venv/bin/python sidecar/test_text_passes.py`; match the existing
  register/CASES style, hermetic, no models): pure-function tests for
  `apply_thai_format` + helpers covering EVERY example table above, including the
  negatives (สามารถ, เก้าอี้, ห้าม, ครั้งหนึ่ง, ขอสองแก้ว, บ่ายสอง, จริงจัง, stoplist
  ไม่ไม่/ที่ที่), the จุด threshold exemption, 3+ collapse, whitespace/`\n` preservation
  (byte-for-byte around untouched spans), no-Thai short-circuit, empty string, and the
  known-limitation case below (asserting the CURRENT miss so a behavior change is loud).
- **macos/OLIVTests/SettingsStoreTests.swift** — default-ON assertion in
  `testDefaults()` (mirror line 32 `XCTAssertTrue(s.removeFillers)`) + round-trip in
  `testRoundTrip()` (set false, reload, assert false — mirror 80/91).
- **macos/OLIVTests/SidecarClientTests.swift** — payload pair (mirror 106–147):
  default dictate omits `thai_format` (fake echoes counter 0); `thaiFormat: true`
  dictate reaches the wire (fake packs a sentinel into `thai_format_fired`). Extend the
  fake sidecar script the tests spawn accordingly.

## Verification commands (from /Users/chayapats/Projects/whispy)

```
sidecar/.venv/bin/python sidecar/test_text_passes.py
# latency: perf_counter micro-benchmark harness via sidecar/.venv/bin/python (paste output)
xcodebuild -project macos/OLIV.xcodeproj -scheme OLIV -destination "platform=macOS,arch=arm64" build
xcodebuild -project macos/OLIV.xcodeproj -scheme OLIV -destination "platform=macOS,arch=arm64" test -only-testing:OLIVTests
```

Python correctness + latency evidence are the hard gate; Swift must at least compile.
Report toolchain friction honestly. Do NOT git commit — the user reviews and commits.

## Known limitation (documented, NOT to be solved)

A decimal whose leading digit-word is glued by newmm into a preceding Thai word is
missed: `ที่สองจุดห้า` tokenizes as `ที่สอง|จุด|ห้า` — `ที่สอง` is not a numeral token, so
the จุด is not numeral-flanked on the left and the run stays words. The common clean
form (`เวอร์ชัน|สอง|จุด|สี่|จุด|หนึ่ง` → `เวอร์ชัน2.4.1`) tokenizes correctly and works.
Accepted; a test pins the current behavior.

## Open risks

- newmm glue (above) — accepted, pinned by a test.
- `thai_words()` lexicon coverage gates reduplication: a legitimate word missing from
  the lexicon won't collapse. Fails safe (no change); stoplist/lexicon tunable later.
- Numeral pre-check set must stay a superset of what `words_to_num` accepts, or a valid
  run is skipped; the try/except remains the authority, the set is only a fast filter.
- First-call newmm trie build (~100+ ms) must not be billed to the pass: benchmark after
  warmup; in production the trie is warm (pipeline tokenizes during cleanup/gating).
- Xcode toolchain friction may block running OLIVTests in this environment; compile is
  the minimum Swift gate.
- Counter semantics (`n_changes` = collapses + converted runs) must match between module
  docstring, tests, and any diagnostics rendering.
- Wire back-compat: unknown request keys are ignored by older sidecars; a missing reply
  counter decodes as 0 in Swift. Both directions degrade cleanly.
