# Apple's on-device dictation (DictationTranscriber, Thai) vs OLIV

macOS 26 added `SpeechAnalyzer` with `DictationTranscriber`, an on-device
dictation model that supports `th_TH`, streams results and runs on the Neural
Engine. Issue #47 asked whether it is good enough on Thai–English speech to
replace OLIV's speech-to-text. This page compares it with OLIV on the same
clips with the same scorer.

Measured on 3 November 2026: Apple M4 Pro, 48 GB, macOS 27.2 (26B123). OLIV
`main` at 0c9190e (`chayapats/typhoon-whisper-turbo-mlx@1631224`,
`mlx-community/gemma-4-e2b-it-4bit@2387675`). Apple asset
`com.apple.siri.asr.assistant.th_TH` 3100.52007.81619.

## Summary

**Keep OLIV's speech-to-text.** Apple's Thai model is good at plain Thai.
It is not good at the Thai–English speech OLIV is built for. English words
mostly come back as Thai-script sound-alikes, and OLIV's cleanup can't recover
them.

| All 264 private clips (one speaker) | Meaning match |
|---|---:|
| OLIV full pipeline (Typhoon → Rust core → Gemma) | **97.3%** |
| Typhoon Whisper Turbo, speech model only | 71.2% |
| Apple DictationTranscriber, raw | 39.8% |
| Apple → OLIV text pipeline | 57.2% |

- **Where Apple wins.**
  - Plain Thai read speech: on FLEURS, meaning match is the same as OLIV's (96.6%), with lower WER and CER.
  - Speed: 0.10 s to decode a clip after release vs Typhoon's 0.62 s.
  - Streaming: the final text arrives 18 ms after the end of audio, the first preview 0.65 s after speech starts.
  - Footprint: under 0.1 GB of process memory and no GPU, against 5–6.6 GB of memory and a busy GPU for OLIV.
  - Download: nothing of OLIV's own. The 1.06 GB model is a macOS-managed asset.
- **Where it loses.**
  - Everything with English. 22 of 36 all-English clips came back mostly in Thai script.
  - Of 603 English words inside Thai sentences, 58 kept their Latin spelling (Typhoon: 223).
  - Thai–English tech talk matched 14 of 72 clips (OLIV: 70).
- **Combining doesn't rescue it.**
  - Apple's text through OLIV's cleanup reaches 57.2%.
  - Apple's vocabulary biasing (contextual strings) clearly helps listed names on Thai ContextASR Bench. Followed by OLIV's cleanup it spells listed names best of all configurations, but its other text is worse.
  - Apple for previews with OLIV for the final would show wrong English words in the preview and change them at release.
  - It is also macOS 26+ only; OLIV supports macOS 14+.

## What was compared

| Config | What runs |
|---|---|
| Typhoon STT only | `oliv-dev eval --no-cleanup` (same-day re-run) |
| OLIV full pipeline | `oliv-dev eval` (Typhoon → Rust core → Gemma E2B cleanup) |
| Apple raw | `SpeechAnalyzer` + `DictationTranscriber(th_TH)`, preset `shortDictation` (short-form hint, punctuation) |
| Apple, no punctuation | the same without the `punctuation` option |
| Apple + list | `AnalysisContext.contextualStrings[.general]` = the clip's list: the private `vb` clips' user vocabulary (what OLIV receives), or ContextASR's frozen list |
| Apple + oracle list | each private clip's own `keywords` (the terms actually spoken, an upper bound no user list reaches) |
| Apple → OLIV | Apple's transcript replayed through OLIV's text pipeline (`oliv-dev eval --replay`, `contextasr run --stt-replay`) with the same per-bucket settings and vocabulary as OLIV full |
| Apple streamed | preset `progressiveShortDictation` (volatile results, frequent finalization), audio fed at real-time speed in 100 ms chunks |

| Set | Clips | Notes |
|---|---:|---|
| Everyday (tuning set) | 194 | private, one speaker; aggregates only |
| Held out | 40 | private, new jargon |
| Confirmation (D2) | 30 | private |
| FLEURS Thai test | 237 | 80 sentences with two or more readers, seed 2026: the [multi-voice sample](speakers.md) (CC-BY-4.0) |
| Thai ContextASR Bench | 300 | `--limit 300 --seed 2026` of 2,062 utterances; conditions `none`, `bias@0`, `bias@50`, `dis@50` ([details](contextasr.md); CC-BY-NC, never committed) |
| Synthetic | 12 | our own sentences read by macOS's Thai voice (Kanya), for quotable examples only |

The scorer is the one in the [main benchmark](README.md). Meaning match is LaBSE
cosine ≥ 0.80 on newmm-segmented text. WER uses newmm words; CER ignores
spaces. ContextASR uses the native port of its upstream scorer.

How Apple was run:
- The model stayed loaded (`modelRetention: .processLifetime`) and one warm-up clip was discarded, as OLIV keeps its models warm.
- Audio was converted to the analyzer's preferred format (16 kHz mono Int16).
- Final segments were joined with single spaces.
- A clip that failed (`SFSpeechErrorDomain` "RecogFailed") counts as empty text.

The OLIV rows reproduce the published 0.2.2 figures exactly: 97.9 / 95.0 /
96.7 / 97.3% full pipeline, and 77.3 / 60.0 / 71.2% speech model only.

## On-device check and permissions

This check ran on public FLEURS audio before any private clip was used.

- **The model is local.** Thai is served by `com.apple.siri.asr.assistant.th_TH` under `/System/Library/AssetsV2`. On disk it is 512 MB of model files plus a 545 MB secure image, plus a 14 MB `asr.hammer.th_TH`.
  - It was already on this Mac, written at 19:36 that day, before this work started. Most likely the earlier locale probe triggered the fetch.
  - `AssetInventory` reported it "supported (not installed)" until the locale was reserved, even though `DictationTranscriber.installedLocales` listed `th_TH`. `oliv-apple-dictation install` (`AssetInventory.reserve`, then `assetInstallationRequest`) found nothing to download.
  - `run` refuses to start unless the asset is installed, so a benchmark never triggers a download.
- **Recognition is sandboxed away from the network.** It runs in Speech.framework's `localspeechrecognition` XPC service. Its sandbox profile (`com.apple.speech.localspeechrecognition.sb`) denies by default and allows outbound traffic only to the local syslog socket.
- **No traffic during a run.** The run covered 237 FLEURS clips whole-file plus 20 streamed (0.82 h of audio, about 94 MB of PCM).
  - `lsof -i` sampled every 0.5 s (627 samples) found no internet socket on the harness or the speech service.
  - `nettop` sampled every process each second. Neither process moved a byte. The only speech, asset or Siri process with traffic was `mobileassetd`, about 9 KB (an asset catalog check).
- **Not proven:** networking was not physically switched off; that would have interrupted other work on this shared Mac. The service holds Siri analytics entitlements, so usage metrics may reach Apple when the user shares Mac analytics. No audio-sized traffic appeared.
- **Permissions:** no prompt appeared. The harness never asked for speech-recognition authorization (it stayed `notDetermined`), and `tccd` logged nothing during transcription. File input needs no microphone permission. Whether a shipping app needs `NSSpeechRecognitionUsageDescription` for `SpeechAnalyzer` was not tested.

## Private corpus

Meaning match · WER · CER:

| Config | Everyday (194) | Held out (40) | D2 (30) | All 264 |
|---|---|---|---|---:|
| **OLIV full pipeline** | **97.9%** · 0.122 · 0.078 | **95.0%** · 0.226 · 0.117 | **96.7%** · 0.192 · 0.134 | **97.3%** |
| Typhoon STT only | 77.3% · 0.330 · 0.230 | 60.0% · 0.662 · 0.427 | 46.7% · 0.543 · 0.400 | 71.2% |
| Apple raw | 45.9% · 0.517 · 0.404 | 27.5% · 0.804 · 0.597 | 16.7% · 0.702 · 0.504 | 39.8% |
| Apple, no punctuation | 45.9% · 0.518 · 0.405 | 27.5% · 0.804 · 0.597 | 16.7% · 0.702 · 0.504 | 39.8% |
| Apple + user list | 45.9% · 0.514 · 0.403 | 30.0% · 0.795 · 0.594 | 20.0% · 0.685 · 0.489 | 40.5% |
| Apple + oracle list | 50.0% · 0.483 · 0.378 | 32.5% · 0.749 · 0.565 | 20.0% · 0.679 · 0.481 | 43.9% |
| Apple → OLIV | 59.8% · 0.361 · 0.276 | 47.5% · 0.492 · 0.362 | 53.3% · 0.399 · 0.290 | 57.2% |
| Apple + user list → OLIV | 59.8% · 0.358 · 0.276 | 47.5% · 0.489 · 0.360 | 56.7% · 0.382 · 0.275 | 57.6% |
| Apple + oracle list → OLIV | 64.4% · 0.330 · 0.250 | 50.0% · 0.463 · 0.344 | 56.7% · 0.373 · 0.269 | 61.4% |
| Apple streamed (everyday set) | 46.4% · 0.518 · 0.402 | – | – | – |

The punctuation option changes nothing measurable. The streamed text matched
the whole-file text exactly in 144 of 194 clips, with the same accuracy.
Apple is deterministic: no clip without a list changed between runs.

By category, everyday set (clips with a meaning match; the groups are the ones
the [speaker kit](speakers.md) uses):

| Group (buckets) | Clips | OLIV full | Typhoon STT | Apple | Apple → OLIV |
|---|---:|---:|---:|---:|---:|
| Everyday Thai and English (`th`, `xg`, `lf`, `en`) | 57 | 57 | 57 | 32 | 34 |
| … plain Thai only (`th`) | 12 | 12 | 12 | **12** | 12 |
| … English sentences only (`en`) | 12 | 12 | 12 | **0** | 1 |
| Thai–English tech talk (`mx`, `hx`, `tc`, `vb`) | 72 | 70 | 41 | 14 | 35 |
| Names and places (`pn`, `nu`) | 25 | 25 | 20 | 19 | 20 |
| Numbers and dates (`nm`) | 20 | 20 | 20 | 14 | 14 |
| Spoken formatting and fillers (`fm`, `fl`) | 20 | 18 | 12 | 10 | 13 |

Held out and D2 follow the same pattern. Tech talk: Apple raw matched 2 of 21
held-out clips (OLIV 21) and 3 of 26 D2 clips (OLIV 25).

Failure counts over all 264 clips (counts only; private sentences are not quoted):

- **English sentences:** 22 of 36 all-English clips came back mostly in Thai script, as a phonetic spelling. Meaning match on `en` was 0 of 12 (everyday) and 0 of 6 (held out).
- **English terms in Thai speech:** of 603 English words inside Thai sentences, Apple kept 58 in Latin script, Typhoon 223. Keyword recall (mostly English terms and names) from the speech model alone:

  | Set | Apple | Typhoon |
  |---|---:|---:|
  | Everyday (170 clips with keywords) | 28.4% | 58.6% |
  | Held out (32 clips) | 5.2% | 39.7% |
  | D2 (29 clips) | 10.3% | 17.8% |
- **User vocabulary:** passing the user's list as contextual strings raised keyword recall on the 10 everyday `vb` clips from 15% to 25%. Meaning stayed at 3 of 10.
- **Numbers:** Apple writes digits (see the synthetic "2,350,000 บาท" and "10:30 น." below), as many people type; these references spell numbers out, so CER overstates its number errors. Meaning match was 14 of 20 vs 20 of 20.
- **Fillers and formatting:** Apple keeps fillers, and doesn't turn spoken commands into new lines. With OLIV's cleanup after it, these reach 13 of 20 (OLIV full: 18).

## FLEURS Thai (237 recordings, many voices)

| Config | Meaning | WER | CER |
|---|---:|---:|---:|
| Typhoon STT only | 96.6% | 0.215 | 0.101 |
| OLIV full pipeline | 96.6% | 0.199 | 0.108 |
| Apple raw | 96.6% | **0.164** | **0.079** |
| Apple → OLIV | 95.8% | 0.171 | 0.095 |

Read Thai news sentences are Apple's strength. Two recordings failed with
"RecogFailed" in every mode and preset tried, and count as empty; another
reader of one of those sentences was transcribed fine. Today's OLIV full
pipeline scores 96.6% here against 95.4% published with 0.2.2 (3 recordings),
after later text-pipeline changes.

## Thai ContextASR Bench (300 utterances)

Percentages. Recall is gold entities transcribed; "listed form" is listed gold
entities in the exact listed spelling; fires are wrong insertions of listed
distractor names.

| Config | `none` CER | `none` recall | `bias@0` recall / listed form | `bias@50` CER | `bias@50` recall | `bias@50` listed form | `bias@50` B-CER | `dis@50` fires | ΔCER `dis@50` − `none` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Typhoon STT only | 6.13 | 44.3 | 44.3 / 30.3 | 6.13 | 44.3 | 30.3 | 21.5 | 1 | 0.00 |
| OLIV full pipeline | 6.52 | 41.5 | 64.3 / 50.0 | **5.98** | **64.0** | 49.8 | 17.6 | 3 | 0.00 |
| Apple raw | 8.41 | 40.5 | 40.5 / 31.3 | 8.41 | 40.5 | 31.3 | 18.6 | 1 | 0.00 |
| Apple + list | 8.41 | 40.5 | 55.0 / 46.3 | 7.99 | 51.5 | 42.8 | 15.0 | 1 | +0.45 |
| Apple → OLIV (list as OLIV vocabulary) | 8.65 | 40.3 | 55.3 / 47.0 | 8.34 | 55.0 | 46.8 | 16.6 | 7 | −0.01 |
| Apple + list → OLIV | 8.65 | 40.3 | 64.3 / **57.0** | 7.97 | 62.5 | **54.8** | **12.7** | 5 | +0.46 |

- **Apple's vocabulary biasing works.** The list raises recall by 11–15 points, with few wrong insertions.
- **Combined with OLIV's cleanup it spells listed names best of all.** Exact listed spelling is 54.8% vs OLIV's 49.8%, and B-CER is 12.7 vs 17.6.
- **The rest of its text is worse.** U-CER is 7.45 vs 4.82, so overall CER loses (7.97 vs 5.98).
- **Failures:** Apple's no-list CER includes 3 failed utterances. Without them it is 7.03, against Typhoon's 6.18 on the same 297.
- **The references favor Apple here.** This benchmark keeps loanwords in Thai script unless they are entities, so Apple's habit of writing English in Thai script costs less here than in OLIV's corpus.

## Latency

One lock hold, back to back, everyday set (194 clips), load 8–10. Times are
after the end of audio (key release):

| | Median | p90 |
|---|---:|---:|
| Typhoon decode | 0.62 s | 1.01 s |
| OLIV full pipeline: decode + cleanup | 0.98 s | 1.25 s |
| Apple, whole clip decoded after release | 0.10 s | 0.28 s |
| Apple streamed: release → final text | **0.018 s** | 0.042 s |
| OLIV cleanup on Apple's text (add to Apple's time) | 0.54 s | 0.68 s |

Streamed preview, a separate run of the same 194 clips at load 6–8:

| | Median | p90 |
|---|---:|---:|
| First text after speech starts (energy onset) | 0.65 s | 0.79 s |
| First text after audio starts | 1.13 s | 1.33 s |
| Gap between updates (per-clip median) | 0.20 s | 0.26 s |

That is about 14 updates per clip, and the final text needs no extra wait
after release. OLIV's cleanup model ran on 112 of 194 Apple transcripts
against 90 of Typhoon's, so Apple → OLIV adds about half a second. OLIV's own
live-preview latency is measured by its live-preview bench (#46), not here.

Earlier accuracy runs share this Mac with another agent's benchmarks and a
virtual machine (load 6–36). Their per-run latencies are kept in the result
files with the load, but compare latency with the matched run above.

## Resources

| | Apple DictationTranscriber | OLIV |
|---|---|---|
| Download | none of OLIV's own; macOS asset of 1.06 GB on disk, shared with Siri and Dictation | 4.8 GB (Typhoon 1.5 GB, Gemma E2B 3.3 GB) |
| Memory | speech service footprint peak 97 MB (309 MB resident including memory-mapped model files); harness 22 MB | Typhoon alone 2.6 GB footprint; full pipeline 5.2 GB steady, 6.6 GB peak |
| GPU (device utilization, all clients) | 23.9% during the run vs 21.3% idle: effectively none | 92–94% while decoding |
| CPU time, 194 clips (14.8 min of audio) | 27.5 s in the speech service + 3.5 s harness (whole clip); 50.5 s streamed in real time (≈6% of one core) | 36 s (Typhoon), 64 s (full pipeline) in the inference helper |
| Neural Engine | used: the service logs ANE model initialization and holds ANE entitlements. Utilization and power were not measured; `powermetrics` needs root | not used |
| macOS | 26+ (`SpeechAnalyzer`); Thai only through `DictationTranscriber`, since `SpeechTranscriber` has no Thai. `SFSpeechRecognizer` Thai was server-based when the probe ran; it reports on-device support now that the asset is installed, but was not used | 14+ |

## Failure examples (public text only)

FLEURS (CC-BY-4.0), reference → Apple (Typhoon for comparison):

- **Numbers:** "ในทศวรรษที่ 1920 … ต้องการความสงบ" → "ในทศวรรษที่หนึ่งเก้าสองศูนย์ … องการความโศก" (the year spelled out; สงบ became โศก). "หลายล้านแกลลอน" → "หลาย 1,000,000 แกลลอน".
- **Foreign names:**
  - "มหาวิทยาลัย Princeton … มหาวิทยาลัย Uppsala" → "มหาวิทยาลัยฟีเซิล … มหาวิทยาลัย Azar" (Typhoon: "พรินท์สตัน … อัพซาลา").
  - "Tupua Tamasese Lealofi III" → "ทัวร์ทา Marsh รยอโรฟิสที่สาม".
- **English technical terms:**
  - "อินฟราเรดสเปกโทรสโกปี (FTIR)" → "Infra Spector Scooby เอฟทีไออาร์" (Typhoon: "Infrares Spectroscopy FTIR").
  - "NextGen … FAA" → "เน็กซ์เจน … เอฟเอเอ" for one reader, and "RecogFailed" (no text at all) for another.

Synthetic sentences we wrote (`tools/apple-dictation/synthetic.jsonl`), read by
macOS's Kanya voice. Kanya is Apple's own synthetic voice, which may suit
Apple's recognizer, so these illustrate the categories and are not a score:

| Category | Intended text | Typhoon | Apple |
|---|---|---|---|
| English terms | พรุ่งนี้ต้องรีวิว pull request ของทีม backend ให้เสร็จก่อนเที่ยง | พรุ่งนี้ต้องรีวิว pool request ของทีมบาเคน… | พรุ่งนี้ต้องรีวิวผู้รีเควสต์ของทีมบาร์เคน… |
| English terms | ลอง restart container ที่รัน Redis ใน Docker ให้หน่อย | ลอง restart container ที่ run Redis ใน darker ให้หน่อย | ลองรีสตาร์ตคอนเทนเนอร์ที่รันเรดใน Drake ให้หน่อย |
| English terms | ส่งลิงก์ Figma มาใน Slack ได้ไหม เดี๋ยวจะเช็ก layout ให้ | ส่งลิง ฟิตมา มาใน สลาด ได้ไหม เดี๋ยวจะเช็ค เลล็อป ให้ | ส่งลิงก์มาใน LINE ได้ไหมเดี๋ยวจะเช็กเรทให้ |
| Code-switching | ประชุม sprint planning เลื่อนไปวันพฤหัสบดีนะครับ | ประชุมสปรินท์พลานิ่งเลื่อนไป… | ประชุมศรินทร์ระนงเลื่อนไป… |
| Names | ทีมของคุณณัฐพงษ์จะไปดูงานที่ Shopee สิงคโปร์สัปดาห์หน้า | …คุณนัทพงศ์…ที่ชาพี่สิงคโปร์… | …คุณณัฐพงษ์…ที่ชาพี่สิงคโปร์… |
| Numbers | ยอดขายเดือนนี้อยู่ที่ 2,350,000 บาท | …สองล้านสามแสนห้าหมื่นบาท | …2,350,000 บาท |
| Numbers | ส่งงานภายในวันที่ 15 พฤศจิกายน เวลา 10.30 น. | ทรงงานภายในวันที่สิบห้าพฤศจิกายน เวลาสิบนาฬิกาสามสิบนาที | ส่งงานภายในวันที่ 15 พฤศจิกายนเวลา 10:30 น. |
| Fillers | วันนี้ผมอาจจะเข้าประชุมไม่ทันนะครับ (said with เอ่อ คือว่า อืม) | เออคือว่าลืมวันนี้… | เออคือว่าลืมวันนี้… |

On this voice, the oracle keyword list (for example "Docker", "Redis") did not
change Apple's output.

## Limits

- **Coverage:**
  - One speaker recorded the private sets.
  - FLEURS is read news.
  - ContextASR is a 300-utterance subset, and 67% of the full benchmark is synthetic voices.
- **Load:** the Mac was shared, so compare latency with the matched run, not across sections.
- **The Apple model can change underneath:** macOS manages it (asset 3100.52007.81619), so results can move with an OS update without any OLIV change.
- **Untested Apple options:**
  - Only the `.general` contextual-strings tag.
  - Custom language models (`SFCustomLanguageModelData`), alternatives and confidence.
  - A second, `en_US` transcriber running alongside with a merge step. `DictationTranscriber` takes a single locale.
- **Not measured:** Neural Engine utilization, energy, and cold first load after a reboot. Here the first prepare took 0.29 s and the warm-up clip 0.64 s.
- **The OLIV baseline is the source build:** the worktree build of `main`. The app installed on this Mac (0.2.3) was not touched or used.

## Recommendation

Keep OLIV's speech-to-text, and don't build on `DictationTranscriber` now.

- **Accuracy where it matters.** OLIV is for people who mix Thai and English. On that speech Apple's model loses most English words, even with OLIV's cleanup after it: 57% vs 97% meaning match. Its biasing lists help names, not English terms in general.
- **Previews.** Apple's preview is fast and cheap: Neural Engine, 0.2 s updates, no GPU contention with the final decode. But on mixed speech the preview would show Thai-script or wrong English words, which the OLIV final then replaces at release. That would mislead on exactly the words users dictate OLIV for.
- **Platform.** macOS 26+ only, against OLIV's 14+. It would also add a second, OS-versioned model that OLIV doesn't control.
- **What would change this.** A future macOS whose Thai model keeps English words, or a Thai `SpeechTranscriber`.
  - Plain Thai is already strong: 12 of 12 plain-Thai clips, and FLEURS at OLIV's level with lower error rates.
  - Until then, one product idea is a zero-download fallback on macOS 26+ while OLIV's 4.8 GB of models download, for Thai-only speech. That is the maintainer's call; it was not built or measured as a feature.
  - The harness re-runs this whole page in about two hours on this Mac.

## Re-running

```sh
bash scripts/build_dev.sh
swift build -c release --package-path tools/apple-dictation
tools/apple-dictation/.build/release/oliv-apple-dictation status    # locale, asset, presets
tools/apple-dictation/.build/release/oliv-apple-dictation install   # reserve + download Apple's model
LABSE_DIR=/path/to/LaBSE/snapshot OLIV_PRIVATE_DATA=benchmark/data \
  bash benchmark/run_dictation_transcriber.sh   # private fleurs contextasr synth stream semantic
```

- **Lock and resume:** every model run holds `lockf /tmp/oliv-gpu.lock`. A run whose output exists is skipped, so an interrupted run resumes.
- **Outputs:** results go under the ignored `benchmark/eval_results/dictation/`.
- **The harness.** `tools/apple-dictation` writes `oliv-dev eval`-format results.
  - These are read by `oliv-dev score`, `oliv-dev semantic` and `oliv-dev eval --replay`.
  - With `--hyps-out` it also writes `{utt_id, condition, text, raw}` rows for `oliv-dev contextasr score --hyps` and `contextasr run --stt-replay`.
- **Manifests:** `oliv-dev contextasr manifest` and `oliv-dev speakers fleurs --manifest-out` write the same subsets as manifests.
- **Debugging:** `OLIV_DICTATION_DEBUG=1` prints every result the transcriber reports.
