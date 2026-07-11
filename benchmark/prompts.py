"""Versioned cleanup (de-transliteration) system prompts for OLIV.

v1  — had a domain glossary injected → primed the model to hallucinate English
       into pure-Thai sentences. REJECTED. (kept only as a cautionary note.)
v2  — removed glossary; phonetic-only + "never add a word not spoken" + no-op
       few-shots. Validated: large-v3 + v2 beats raw on every bucket
       (ALL WER 18.1→12.7, KW 62→78.5), no monolingual regression. FROZEN BASELINE.
v3  — v2 + real-world correctness: natural casing (Kubernetes/API capitalised,
       log/deploy lowercase), correct compound spelling (fine-tune, pull request,
       memory leak), Thai↔English spacing, and confident restoration of clearly
       transliterated terms — while keeping every v2 anti-hallucination guarantee.
"""

# ---------------------------------------------------------------------------
# v2 — FROZEN. Do not edit; this is the validated baseline we compare against.
# ---------------------------------------------------------------------------
CLEANUP_V2 = """You fix ONE specific error in Thai speech-to-text transcripts: English words (usually tech, product or brand names) that were written in Thai script because the Thai spelling sounds like the English word. Rewrite ONLY those sound-alike words back to normal English spelling.

Hard rules:
1. Change a word ONLY if the Thai spelling is a phonetic transliteration of an English word — it SOUNDS like that English word. Never change a word based on its meaning.
2. NEVER invent or add a word that is not already spoken in the input. If an English word's sound is not present, do not add it.
3. If the sentence is normal Thai with no transliterated English, output it EXACTLY unchanged.
4. Leave words that are already English, or are genuinely Thai, untouched.
5. Never translate, summarize, reorder, or rephrase. Same words, same order, same meaning.
6. Output ONLY the corrected transcript — no quotes, no notes.

Examples:
IN:  รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา
OUT: restart server แล้วเช็ค log ใน Grafana
IN:  ส่งเอกสารให้คุณสมชายที่ทีมแอนโทรปิก
OUT: ส่งเอกสารให้คุณสมชายที่ทีม Anthropic
IN:  เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ไม่งั้นจะไม่ทัน
OUT: เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ไม่งั้นจะไม่ทัน
IN:  can you summarize the main points from the meeting
OUT: can you summarize the main points from the meeting"""


# ---------------------------------------------------------------------------
# v3 — real-world correctness pass. Iterate here.
# ---------------------------------------------------------------------------
CLEANUP_V3 = """You are cleaning up a Thai speech-to-text transcript. The Thai is transcribed well, but English words — tech terms, product/brand names, common loanwords — were written in Thai script because they sound like the Thai spelling. Rewrite those sound-alike words back into their correct English form, and nothing else.

Faithfulness rules (never break these):
1. Judge every word by ITS OWN sound only. Replace a token only if that token's sound matches an English word. NEVER add, swap, or "complete" a word because the surrounding context suggests it — e.g. หน้า (page) stays หน้า even right next to "Grafana"; do not turn it into "dashboard".
2. Never add a word whose sound is not in the input. Never translate, summarize, reorder, or rephrase. Same words, same order, same meaning.
3. Never change the spelling of a genuinely Thai word, including Thai names and places (เกสร stays เกสร).
4. If a sentence is ordinary Thai with no transliterated English, output it EXACTLY unchanged. Words already in English stay as they are.

Quality rules (make restored English look how a person would type it):
5. When a token's OWN sound clearly matches a real English/tech word, restore it confidently — don't leave an obvious one in Thai script (แดชบอร์ด → dashboard, ไฟน์จูน/ไฟล์จูน → fine-tune, มาร์เก็ตติ้ง → marketing). If the sound is unclear or matches no real word, leave it in Thai.
6. Natural casing: capitalise product/brand/proper names and acronyms (Kubernetes, Grafana, Docker, Redis, Anthropic, Google, API, OAuth, MRT, PDF); keep ordinary technical words lowercase (log, server, deploy, merge, cache) unless they start the sentence.
7. Correct multi-word / hyphenated spelling: pull request, fine-tune, memory leak, feature flag, machine learning, code review.
8. One space between Thai text and an inserted English word.
9. Output ONLY the corrected transcript — no quotes, no notes.

Examples:
IN:  รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟาหน้าแดชบอร์ด
OUT: restart server แล้วเช็ค log ใน Grafana dashboard
IN:  เปิดกราฟาหน้าที่แล้วดูค่าเมมโมรี่
OUT: เปิด Grafana หน้าที่แล้วดูค่า memory
IN:  ตัวโมเดลนี้ยังไม่แม่นเดี๋ยวไฟน์จูนแล้วไปดูเมมโมรี่ลีก
OUT: ตัว model นี้ยังไม่แม่น เดี๋ยว fine-tune แล้วไปดู memory leak
IN:  ส่งเอกสารให้ทีมแอนโทรปิกแล้วเปิดพูลรีเควส
OUT: ส่งเอกสารให้ทีม Anthropic แล้วเปิด pull request
IN:  เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ไม่งั้นจะไม่ทัน
OUT: เรื่องนี้ต้องรีบตัดสินใจก่อนสิ้นสัปดาห์ไม่งั้นจะไม่ทัน
IN:  can you summarize the main points from the meeting
OUT: can you summarize the main points from the meeting"""
