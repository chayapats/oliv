#!/usr/bin/env python3
"""Regression tests for the finetune corpus pipeline.

    python3 benchmark/finetune/test_finetune.py            # everything but misread()
    benchmark/.venv/bin/python benchmark/finetune/test_finetune.py   # + misread()

Every case here is a bug that was actually shipped and caught in review, not a
hypothetical. The pipeline had no tests; that is how a leak guard came to be built on a
symmetric metric that cannot see containment, and how `mapping` came to be counted as an
occurrence of `app`. Each name below is the bug.
"""
import array
import json
import math
import sys
import tempfile
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import matching as M
import record as R

PASS = FAIL = 0
SR = 16000


def check(name, got, want):
    global PASS, FAIL
    ok = got == want
    PASS, FAIL = PASS + ok, FAIL + (not ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f"\n        got {got!r}\n        want {want!r}"))


def wav(path, pcm):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(array.array(
            "h", [max(-32768, min(32767, int(v))) for v in pcm]).tobytes())


# ---------------------------------------------------------------- term matching
def test_boundaries():
    print("\nterm matching — a substring is not an occurrence")
    # These four wrongly credited `app` 95 times when the truth was 27.
    for word in ("mapping", "wrapper", "approve", "happy"):
        check(f"'{word}' does not contain the term 'app'",
              M.has_term(f"ตัว {word} ยังพัง", "app"), False)
    check("'app' does contain the term 'app'", M.has_term("เปิด app ใหม่", "app"), True)
    check("'optimizer' is not 'optimize'", M.has_term("ตัว optimizer พัง", "optimize"), False)
    check("'optimize' is 'optimize'", M.has_term("ต้อง optimize ก่อน", "optimize"), True)
    check("matching ignores case", M.has_term("ใช้ REDIS อยู่", "Redis"), True)
    check("terms with punctuation survive", M.has_term("แตะ requirements.txt ด้วย",
                                                       "requirements.txt"), True)
    check("p99 matches next to Thai", M.has_term("ดู p99 หน่อย", "p99"), True)
    check("Thai term matches", M.has_term("ฝากบอกวีระชัยด้วย", "วีระชัย"), True)


def test_canonicalise():
    print("\ncanonicalisation — one spelling per term, or the label teaches disagreement")
    terms = ["Whisper", "route", "Route 53", "API", "Vault"]
    check("lowercase term is raised to canonical",
          M.canonicalise("ลอง whisper ดู", terms)[0], "ลอง Whisper ดู")
    # `route` must not chew the longer term it sits inside.
    check("'Route 53' survives the shorter term 'route'",
          M.canonicalise("ตั้ง Route 53 ใหม่", terms)[0], "ตั้ง Route 53 ใหม่")
    check("both are canonicalised in one sentence",
          M.canonicalise("เรียก api ผ่าน vault", terms)[0], "เรียก API ผ่าน Vault")
    check("a non-term word is left alone",
          M.canonicalise("apixaban ไม่ใช่คำเทค", terms)[0], "apixaban ไม่ใช่คำเทค")


# ---------------------------------------------------------------- leak guard
def test_leak_guard():
    print("\nleak guard — an eval sentence must not survive inside a training sentence")
    ev = "ตั้ง cron job ให้ backup database ทุกเที่ยงคืน"

    # THE shipped bug: wrapping the eval sentence inflates the union, so symmetric
    # Jaccard falls to 0.57 and slides under a 0.60 gate. Two of these reached the corpus.
    wrapped = "ณัฐพงศ์ตั้ง cron job ให้ backup database ทุกเที่ยงคืนแล้ว ฝากบอกวีระชัยด้วย"
    check("jaccard alone CANNOT see the wrapped leak (this is the bug)",
          M.jaccard(M.grams(wrapped), M.grams(ev)) > 0.60, False)
    check("contiguity CAN see it", M.contiguous_ratio(ev, wrapped) > 0.60, True)
    check("verbatim reuse is caught", M.norm(ev) in M.norm(wrapped), True)

    # ... without flagging every sentence that merely shares the topic.
    unrelated = "เมื่อคืนผมนั่ง refactor ตัว cleanup pipeline ใหม่หมด ตัดโค้ดเก่าออกไปเยอะ"
    ev2 = "ช่วย review pull request ให้หน่อย"
    check("an unrelated sentence on the same topic is NOT a leak",
          M.contiguous_ratio(ev2, unrelated) > 0.60, False)


def test_shipped_script_is_clean():
    print("\nthe shipped script.jsonl — swept against every eval sentence")
    import evalcorpus
    script = R.SCRIPT
    if not script.exists():
        print("  skip (no script.jsonl)")
        return
    rows = [json.loads(l) for l in script.read_text(encoding="utf-8").splitlines() if l.strip()]
    ev = evalcorpus.load()
    leaks = [r["id"] for r in rows for e in ev
             if M.norm(e) in M.norm(r["text"]) or M.contiguous_ratio(e, r["text"]) > M.LEAK_C]
    check(f"zero eval sentences inside {len(rows)} training sentences", leaks, [])
    leaks2 = [r["id"] for r in rows if M.is_eval_leak(r["text"], ev)]
    check("  ...and the production predicate agrees", leaks2, [])

    bad = [(r["id"], t) for r in rows for t in r["terms"] if not M.has_term(r["text"], t)]
    check("every term annotation is really present at a boundary", bad, [])

    # is_eval_leak() skips the expensive checks when a cheap 4-gram bound rules a pair
    # out. That bound must never hide a leak — 9x faster is worthless if it is wrong.
    def unfiltered(text):
        nt = M.norm(text)
        return next((e for e in ev if M.norm(e) in nt
                     or M.contiguous_ratio(e, text) > M.LEAK_C
                     or M.ordered_ratio(e, text) > M.LEAK_O), None)
    sample = rows[::37]                       # ~66 sentences x 264 eval refs
    disagree = [r["id"] for r in sample
                if (M.is_eval_leak(r["text"], ev) is None) != (unfiltered(r["text"]) is None)]
    check("the pre-filter never hides a leak the full sweep would find", disagree, [])


# ---------------------------------------------------------------- audio QC
def test_qc():
    print("\naudio QC — energy is not speech")
    T = Path(tempfile.mkdtemp())

    real = T / "real.wav"
    import subprocess
    src = R.FT.parent / "data" / "clips" / "mx01.wav"
    if src.exists():
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
                        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(real)],
                       check=True)
        check("real speech passes", R.analyse(real)["ok"], True)

    wav(T / "silence.wav", [0] * (3 * SR))
    check("silence is rejected", R.analyse(T / "silence.wav")["ok"], False)

    wav(T / "short.wav", [3000 * math.sin(2 * math.pi * 200 * n / SR) for n in range(SR // 4)])
    check("a 0.25 s tap is rejected", R.analyse(T / "short.wav")["ok"], False)

    wav(T / "clipped.wav", [32767 if n % 100 < 50 else -32767 for n in range(3 * SR)])
    check("a clipped take is rejected", R.analyse(T / "clipped.wav")["ok"], False)

    # The exact signal the reviewer used to walk through the old QC: an alternating
    # square wave with a loud block and a quiet block, which fakes the energy envelope
    # of speech. It scored voiced=0.20, snr=20 dB, ok=True.
    step = 320
    wav(T / "square.wav",
        [((-1 if i % 2 == 0 else 1) * (5000 if f < 20 else 500))
         for f in range(100) for i in range(step)])
    check("reviewer's speech-free square wave is rejected",
          R.analyse(T / "square.wav")["ok"], False)

    # Harder: a sine amplitude-modulated at 4 Hz, which fakes a syllable rhythm too.
    # Its energy envelope looks like speech; its zero-crossing rate cannot.
    wav(T / "am_sine.wav",
        [8000 * math.sin(2 * math.pi * 440 * n / SR)
         * (0.15 + 0.85 * max(0, math.sin(2 * math.pi * 4 * n / SR))) for n in range(4 * SR)])
    check("a sine faking a syllable rhythm is rejected",
          R.analyse(T / "am_sine.wav")["ok"], False)

    wav(T / "hum.wav", [4000 * math.sin(2 * math.pi * 50 * n / SR) for n in range(3 * SR)])
    check("50 Hz mains hum is rejected", R.analyse(T / "hum.wav")["ok"], False)


# ---------------------------------------------------------------- misread (needs venv)
def test_misread():
    print("\nmisread — measured against the real (reference, typhoon-raw) pairs")
    try:
        from verify import misread
    except ImportError as e:
        print(f"  skip (needs benchmark/.venv: {e})")
        return
    res = R.FT.parent / "eval_results" / "ship_main.json"
    if not res.exists():
        print("  skip (no ship_main.json)")
        return
    clips = json.loads(res.read_text())["clips"]
    pairs = [(c["reference"], c["raw"]) for c in clips if c.get("raw")]
    shuffled = [(a, pairs[(i + 37) % len(pairs)][1]) for i, (a, _) in enumerate(pairs)]

    fp = sum(misread(a, b)["flag"] for a, b in pairs)
    missed = sum(not misread(a, b)["flag"] for a, b in shuffled)
    unjudged = sum(not misread(a, b)["judged"] for a, b in pairs)

    # Assert the property, not the number this happens to score today. A misread that
    # slips through poisons the training set silently; a false flag costs one take and is
    # printed by export. So: zero tolerance one way, a small budget the other.
    check(f"no misread survives ({len(shuffled)} shuffled pairs)", missed, 0)
    # The budget IS the decision, written down. sim<0.70 plus gap>=3 costs ~7% false flags
    # and buys 96% of skipped words. A false flag loses one take, and approve.py lets you
    # listen to it and settle it in seconds. A skipped word that slips through teaches the
    # model to say a word that is not in the audio — silently, permanently, in the exact
    # place we are trying to fix. There is no symmetry, so the budget is not symmetric.
    check(f"false flags stay under 9% ({fp}/{len(pairs)})", fp / len(pairs) <= 0.09, True)
    # The old rule refused to judge any label with under 12 Thai characters, abandoning
    # 183 of 2,447 sentences as unjudgeable. Folding both sides phonetically removed the
    # carve-out entirely, which is what lets export demand a verdict for every take.
    check("no sentence is left unjudgeable", unjudged, 0)

    # A word you SKIP while reading leaves a hole in the label with nothing opposite it;
    # a word typhoon MISHEARS gets substituted, so it leaves none. Whole-sentence
    # similarity is blind to the difference — one word in twenty still scores 0.88-0.93 —
    # and this used to catch 0% of them.
    import random
    rng = random.Random(5)
    kws = {}
    for m in ("manifest_all.jsonl", "manifest_holdout.jsonl"):
        f = R.FT.parent / "data" / m
        if f.exists():
            for l in f.read_text(encoding="utf-8").splitlines():
                if l.strip() and not l.startswith("#"):
                    r = json.loads(l)
                    if r.get("keywords"):
                        kws[r["reference"]] = r["keywords"]
    skips = [(ref, ref.replace(rng.choice(k), "", 1)) for ref, k in kws.items()]
    caught = sum(misread(a, b)["flag"] for a, b in skips)
    check(f"most single skipped words are caught ({caught}/{len(skips)})",
          caught / len(skips) >= 0.94, True)


# ---------------------------------------------------------------- export selection
def _ds(tmp, takes, verdicts, wavs):
    clips = tmp / "clips"; clips.mkdir(parents=True, exist_ok=True)
    for name, data in wavs.items():
        (clips / name).write_bytes(data)
    return clips, takes, verdicts


def test_insertion_attack():
    print("\nleak guard — an eval sentence broken up by inserted words")
    import evalcorpus
    ev = evalcorpus.load()
    # Measuring only the LONGEST contiguous run let one phrase in the middle of an eval
    # sentence halve the score while the whole sentence was still there, in order. A
    # systematic midpoint insertion slipped 124 of 188 eval references past that gate.
    def attack(e):
        w = e.split()
        return " ".join(w[:len(w) // 2] + ["ข้อมูลสำคัญ"] + w[len(w) // 2:]) if len(w) >= 4 else None
    atk = [(e, attack(e)) for e in ev if attack(e)]
    missed = [e for e, a in atk if M.is_eval_leak(a, [e]) is None]
    check(f"midpoint insertion into all {len(atk)} eval sentences is caught", missed, [])
    one = "ตั้ง cron job ให้ backup ข้อมูลสำคัญ database ทุกเที่ยงคืน"
    base = "ตั้ง cron job ให้ backup database ทุกเที่ยงคืน"
    check("  longest-run alone would have missed it",
          M.contiguous_ratio(base, one) > M.LEAK_C, False)
    check("  ordered-total catches it", M.ordered_ratio(base, one) > M.LEAK_O, True)


def test_neighbours_are_separated():
    print("\nscript — a wrong-row misread must stay catchable")
    try:
        from verify import THRESHOLD, pfold
    except ImportError as e:
        print(f"  skip (needs benchmark/.venv: {e})")
        return
    from difflib import SequenceMatcher
    rows = [json.loads(l) for l in R.SCRIPT.read_text(encoding="utf-8").splitlines() if l.strip()]
    folds = [pfold(r["text"]) for r in rows]
    worst = max(SequenceMatcher(None, folds[i - 1], folds[i]).ratio()
                for i in range(1, len(folds)))
    # If neighbours sound alike, reading the wrong row scores above THRESHOLD and
    # misread() calls it clean. This must be enforced, not left to the shuffle.
    check(f"worst adjacent pair ({worst:.3f}) stays under the misread gate ({THRESHOLD})",
          worst < THRESHOLD, True)


def test_export_gate():
    print("\nexport — the last gate trusts nothing upstream wrote")
    import export as E
    T = Path(tempfile.mkdtemp())
    AUD = b"RIFFfake-audio-bytes"
    ah = E.sha(AUD)
    good = "ช่วย deploy ตัวนี้ขึ้น production ให้หน่อย"
    lh = E.sha(good.encode())
    clips, _, _ = _ds(T, [], [], {f"ft1__{ah}.wav": AUD})
    base = {"id": "ft1", "audio": ah, "label": lh, "text": good, "dur": 5.0}
    clean = {"id": "ft1", "audio": ah, "label": lh, "flag": False, "judged": True}

    rows, _ = E.select([base], [clean], clips, [])
    check("a verified take ships", [r["text"] for r in rows], [good])

    rows, d = E.select([base], [], clips, [])
    check("no verdict -> not shipped", rows, [])

    # THE bug: relabelling keeps the audio, so a verdict earned by the OLD label was
    # applied to the NEW one and export shipped a sentence that was never spoken.
    wrong = "ประโยคใหม่ที่ไม่เคยพูด"
    relabel = {**base, "text": wrong, "label": E.sha(wrong.encode()), "relabeled": True}
    rows, d = E.select([base, relabel], [clean], clips, [])
    check("a relabel cannot inherit the old label's verdict", rows, [])

    # ... and ships once the new (audio,label) pair has its own verdict.
    v2 = {"id": "ft1", "audio": ah, "label": relabel["label"], "flag": False, "judged": True}
    rows, _ = E.select([base, relabel], [clean, v2], clips, [])
    check("...and ships once THAT pair is verified", [r["text"] for r in rows], [wrong])

    # A leak smuggled in by editing the sentence in the recorder never met build_script.
    ev = "ตั้ง cron job ให้ backup database ทุกเที่ยงคืน"
    leak = {**base, "text": ev, "label": E.sha(ev.encode())}
    lv = {"id": "ft1", "audio": ah, "label": leak["label"], "flag": False, "judged": True}
    rows, d = E.select([leak], [lv], clips, [ev])
    check("an edited-in eval sentence is caught at export", rows, [])
    check("  and named", list(d), ["label leaks an eval sentence"])

    # Crash between publishing the WAV and appending metadata: bytes no longer match.
    (clips / f"ft1__{ah}.wav").write_bytes(b"RIFFdifferent-bytes")
    rows, d = E.select([base], [clean], clips, [])
    check("audio that no longer hashes to its take is refused", rows, [])

    rows, _ = E.select([{**base, "invalid": True}], [clean], clips, [])
    check("an invalidated take is not shipped", rows, [])

    # An escape hatch of any kind voids the "verified" claim; it used to ignore
    # --keep-flagged entirely, so a set full of REJECTED takes still called itself clean.
    (clips / f"ft1__{ah}.wav").write_bytes(AUD)
    bad = {"id": "ft1", "audio": ah, "label": lh, "flag": True, "judged": True, "sim": 0.1}
    rows, _ = E.select([base], [bad], clips, [])
    check("a flagged take never ships — there is no override", rows, [])
    # ...but a HUMAN who listened to the clip is a verdict, and a better one than the
    # model's: the model failing on these terms is the whole reason the corpus exists.
    rows, _ = E.select([base], [{**bad, "flag": False, "by": "human"}], clips, [])
    check("a human verdict ships it", [r["by"] for r in rows], ["human"])
    # A verdict that says nothing is not a verdict. `v.get("judged", True)` used to let an
    # identity-only row through on Python's default.
    rows, d = E.select([base], [{"id": "ft1", "audio": ah, "label": lh}], clips, [])
    check("an identity-only verdict is refused", rows, [])
    # Presence is not enough: "false" is a truthy string and 0 is a falsy int. Python's
    # truthiness is a convenience, not a schema, and evidence needs a schema.
    for jd, fl in (("false", 0), (1, ""), (None, None)):
        rows, _ = E.select([base], [{"id": "ft1", "audio": ah, "label": lh,
                                     "judged": jd, "flag": fl}], clips, [])
        check(f"verdict judged={jd!r} flag={fl!r} is refused", rows, [])


def test_eval_corpus_fails_closed():
    print("\neval corpus — empty is as dangerous as missing")
    import evalcorpus as EC
    T = Path(tempfile.mkdtemp())
    try:
        EC.load(T); check("missing manifests abort", "returned", "SystemExit")
    except SystemExit:
        check("missing manifests abort", "SystemExit", "SystemExit")
    for m in EC.MANIFESTS:                      # exist, but truncated to nothing
        (T / m).write_text("")
    try:
        EC.load(T); check("EMPTY manifests abort too", "returned", "SystemExit")
    except SystemExit:
        check("EMPTY manifests abort too", "SystemExit", "SystemExit")


def test_leak_predicate_branches():
    print("\nleak guard — the shared predicate, and its known limits")
    ev = "ตั้ง cron job ให้ backup database ทุกเที่ยงคืน"
    F = [ev]
    check("verbatim", M.is_eval_leak(ev, F) is not None, True)
    # wrapped: jaccard cannot see this one — contiguity must
    wrapped = "ณัฐพงศ์ตั้ง cron job ให้ backup database ทุกเที่ยงคืนแล้ว ฝากบอกวีระชัยด้วย"
    check("wrapped (contiguity branch)", M.is_eval_leak(wrapped, F) is not None, True)
    check("  jaccard would have missed it (why that branch is gone)",
          M.jaccard(M.grams(wrapped), M.grams(ev)) > 0.60, False)
    check("an unrelated sentence is not a leak",
          M.is_eval_leak("เมื่อคืนผมนั่ง refactor ตัว cleanup pipeline ใหม่หมด", F), None)

    # This used to be pinned as a KNOWN GAP: order-preserving checks are blind to a
    # reordered eval sentence, and the Jaccard branch that was supposed to cover it could
    # not (reorderings score 0.32-0.39 against unrelated sentences reaching 0.45 — below
    # the noise). Characters were simply the wrong unit. At the WORD level a reordering
    # keeps every token, so it scores 1.00 by construction and the gap is closed.
    for reordered in ("database backup ทุกเที่ยงคืน ตั้ง job cron ให้",
                      "cron job ตั้งไว้ ทุกเที่ยงคืน database ก็ backup ให้",
                      "ทุกเที่ยงคืน database ก็ backup ให้ ตั้ง cron job ไว้"):
        check(f"reordered eval sentence is caught: {reordered[:28]}…",
              M.is_eval_leak(reordered, F) is not None, True)

    # Invisible characters render as nothing, break every n-gram, and leave a sentence a
    # human reads aloud verbatim. 263 of 264 eval refs walked through before norm() started
    # stripping them — and then U+061C walked through the hand-written list of ranges that
    # was the first fix. Do not enumerate this set by hand; ask Unicode. Every Cf and Cc
    # codepoint, injected into a real eval sentence:
    import unicodedata
    invisibles = [chr(cp) for cp in range(0x11000)
                  if unicodedata.category(chr(cp)) in ("Cf", "Cc")]
    missed = [hex(ord(c)) for c in invisibles
              if M.is_eval_leak((c * 3).join(ev), F) is None]
    check(f"all {len(invisibles)} invisible codepoints fail to hide an eval sentence",
          missed, [])
    # And the same bypass without any Unicode trickery at all: a separator between EVERY
    # character kills all 4-grams while ordered_ratio stays at 1.0. The prefilter must
    # bound on CHARACTERS, which is what the metrics actually count.
    check("character-separated eval sentence is caught",
          M.is_eval_leak("x".join(ev), F) is not None, True)

    # Fullwidth Latin renders as, and is read aloud as, ordinary Latin — and shares not one
    # codepoint with it. 176 of 264 references walked through a guard that had already been
    # hardened twice. NFKC is the standard answer; reaching for it earlier would have saved
    # two rounds. Every attack found so far, against every eval sentence:
    import evalcorpus, random as _r, re
    E = evalcorpus.load()
    wide = lambda x: "".join(chr(ord(c) - 0x20 + 0xFF00) if 0x21 <= ord(c) <= 0x7e else c
                             for c in x)
    zw = lambda x: "".join(c + "\u200b" for c in x)
    alm = lambda x: ("\u061c" * 3).join(x)
    def ins(x):
        w = x.split()
        return " ".join(w[:len(w) // 2] + ["ข้อมูลสำคัญ"] + w[len(w) // 2:]) if len(w) > 3 else x
    def reo(x):
        w = x.split(); _r.Random(1).shuffle(w); return " ".join(w)
    attacks = {"fullwidth": wide, "zero-width": zw, "U+061C": alm, "inserted word": ins,
               "reordered": reo, "fullwidth+zerowidth": lambda x: zw(wide(x)),
               "fullwidth+reordered": lambda x: wide(reo(x)),
               "wrapped": lambda x: f"ณัฐพงศ์{x}แล้ว ฝากบอกวีระชัยด้วย"}
    for name, f in attacks.items():
        slipped = [e for e in E if M.is_eval_leak(f(e), [e]) is None]
        check(f"{name}: 0 of {len(E)} eval sentences slip through", slipped, [])

    # Bidi controls REORDER rather than hide: store the Latin runs backwards inside U+202E
    # and the screen shows the eval sentence, which a human then reads aloud verbatim.
    # Deleting the control leaves the guard comparing reversed text — 164 of 195 got
    # through. You cannot recover a rendering by deleting characters. Refuse instead.
    def rtl(x):
        return re.sub(r"[A-Za-z ]{4,}", lambda m: "\u202e" + m.group(0)[::-1] + "\u202c", x)
    attackable = [e for e in E if rtl(e) != e]
    unrefused = [e for e in attackable if not M.hostile_chars(rtl(e))]
    check(f"bidi-override attack refused on all {len(attackable)} attackable refs",
          unrefused, [])
    check("a legitimate Thai/English sentence has no hostile characters",
          M.hostile_chars("ช่วย deploy ขึ้น production\nแล้ว merge branch main"), [])


# =====================================================================================
# The finetune RUN (docs/superpowers/plans/2026-07-15-finetune-run.md)
# =====================================================================================

def _base_model_dir():
    """The shipped MLX snapshot, if it is in the HF cache. The model tests are skipped
    without it so a fresh checkout still runs the other assertions — they must not become
    conditional on a 1.5GB download."""
    import glob
    hits = glob.glob(str(Path.home() / ".cache/huggingface/hub"
                         / "models--chayapats--typhoon-whisper-turbo-mlx/snapshots/*/"))
    return hits[0] if hits else None


def test_frozen_rulers_are_never_mined():
    """A ruler must never be a source of the vocabulary it exists to measure.

    manifest_holdout was authored with all-new jargon so it would test GENERALISATION, then
    from_eval() harvested its keywords and spoken_vocab() used its sentences to vouch for
    repo-mined words. 30 of its 40 clips now carry terms the finetune trains on.
    """
    import build_terms as bt
    check("holdout is declared a frozen ruler",
          "manifest_holdout.jsonl" in bt.FROZEN_RULERS, True)
    check("from_eval does not mine a frozen ruler",
          [m for m in bt.EVAL_MANIFESTS if m in bt.FROZEN_RULERS], [])
    check("spoken_vocab does not mine a frozen ruler",
          [m for m in bt.SPOKEN_MANIFESTS if m in bt.FROZEN_RULERS], [])

    # Each site keeps the manifest set it always had, minus the frozen ones. Quietly widening
    # either would change what gets mined for reasons unrelated to this fix.
    check("from_eval still reads its original 3 (minus holdout)",
          set(bt.EVAL_MANIFESTS), {"manifest_all.jsonl", "manifest_d2.jsonl"})
    check("spoken_vocab still reads its original 5 (minus holdout)", len(bt.SPOKEN_MANIFESTS), 4)

    # Pure functions -> call them. (NOT bt.main(): it rewrites terms.jsonl in place.)
    ev = {bt.key(t) for t in bt.from_eval()}
    check("Triton is gone: the holdout was its ONLY voucher", "triton" in ev, False)
    check("...and it no longer vouches for repo words either", "triton" in bt.spoken_vocab(), False)

    # The asymmetry that IS the finding: this cannot un-contaminate the current holdout.
    dc = {bt.key(t) for t in bt.from_dictionary()}
    check("Cassandra survives via dictionary.py — real vocabulary, correctly kept",
          "cassandra" in dc, True)

    # evalcorpus is leak DEFENCE — the opposite direction. It must NOT shrink.
    import evalcorpus
    check("the leak guard still loads the holdout",
          "manifest_holdout.jsonl" in evalcorpus.MANIFESTS, True)


def test_probe_contains_no_trained_term():
    """The invariant is about SPOKEN CONTENT, so it is checked against the REFERENCE TEXT — not
    the `keywords` annotation. A prior version of this test checked keywords, the same field the
    partition used, and so passed for the wrong reason: 16 of its 'clean' clips (every en* clip,
    which has keywords=None) actually spoke a trained term."""
    import probe
    rows, _ = probe.select_from_disk()
    terms = probe.trained_terms()
    check("the probe is non-empty", len(rows) >= 40, True)
    # THE real invariant: no probe clip's reference speaks any trained term.
    bad = [(r["id"], t) for r in rows for t in terms if M.has_term(r.get("reference", ""), t)]
    check("no probe clip's spoken text contains a term the finetune trains on", bad, [])

    # the complement is non-empty, or Gate 1 (generalisation) has nothing to measure
    clips = list(probe._rows(probe.DATA / "manifest_holdout.jsonl"))
    trained, clean = probe.partition(clips, terms)
    check("the holdout IS contaminated — 33 of 40 speak a trained term", len(trained), 33)
    check("...leaving only 7 clean, which is why the probe pools both manifests", len(clean), 7)

    # regression on the keyword bug: the OLD keyword test would have called these clips clean
    en = [r for r in rows if r["id"].startswith("en")]
    en_speaking_terms = [r["id"] for r in
                         list(probe._rows(probe.DATA / "manifest_all.jsonl"))
                         if r["id"].startswith("en")
                         and any(M.has_term(r.get("reference", ""), t) for t in terms)]
    check("en* clips that speak a trained term are EXCLUDED from the probe",
          [r["id"] for r in en if r["id"] in en_speaking_terms], [])


def test_probe_report_compares_only_shared_clips():
    """F3/F4/F7(round4): CALL the real probe.compare() (not a re-implementation) and assert its
    structured output. Covers: the real field is `wer` not `wer_newmm` (round4 #3, the report was
    all n/a on real data); only shared clips are compared (a dropped hard clip must not fake an
    improvement); a shared id whose reference changed is refused; duplicate ids are refused."""
    import probe, json, tempfile
    # a term the corpus trains on, so the 'trained-term' subset is non-empty
    trained = next(iter(probe.trained_terms()))
    T = Path(tempfile.mkdtemp())
    # base: an easy clip (kw 1.0) + a HARD clip (kw 0.0). tuned: only the easy one.
    base = {"clips": [
        {"id": "e1", "reference": f"ใช้ {trained} อยู่", "kw_recall": 1.0, "wer": 0.10},
        {"id": "h1", "reference": f"แก้ {trained} ด่วน", "kw_recall": 0.0, "wer": 0.90}]}
    tuned = {"clips": [
        {"id": "e1", "reference": f"ใช้ {trained} อยู่", "kw_recall": 1.0, "wer": 0.10}]}
    (T / "b.json").write_text(json.dumps(base, ensure_ascii=False))
    (T / "t.json").write_text(json.dumps(tuned, ensure_ascii=False))
    r = probe.compare(str(T / "b.json"), str(T / "t.json"))
    check("compare() uses only the shared clip (h1 dropped)", r["shared"], 1)
    cell = r["subsets"]["trained-term"]
    check("wer is read from the real 'wer' field, not n/a", cell["base"]["wer"], 0.10)
    check("no phantom improvement: shared-clip wer delta is 0",
          cell["tuned"]["wer"] - cell["base"]["wer"], 0.0)

    # a shared id whose reference text differs is refused (stale manifest)
    stale = {"clips": [{"id": "e1", "reference": "DIFFERENT text", "kw_recall": 1.0, "wer": 0.1}]}
    (T / "stale.json").write_text(json.dumps(stale))
    raised = False
    try:
        probe.compare(str(T / "b.json"), str(T / "stale.json"))
    except SystemExit:
        raised = True
    check("a shared id with a changed reference is refused", raised, True)

    # duplicate ids are refused
    (T / "dup.json").write_text(json.dumps({"clips": [{"id": "e1"}, {"id": "e1"}]}))
    raised = False
    try:
        probe._clips_by_id(T / "dup.json")
    except SystemExit:
        raised = True
    check("duplicate clip ids are refused", raised, True)

    # meaning% is computed from _semantic.json per-clip sims, and requires FULL subset coverage
    # (#3/#8 round4/5). Point SEMANTIC at a temp file keyed by our result-file stems.
    sem = {"configs": {"b": {"clips": [{"id": "e1", "sim": 0.95}]},
                       "t": {"clips": [{"id": "e1", "sim": 0.60}]}}}
    (T / "_sem.json").write_text(json.dumps(sem))
    orig_sem = probe.SEMANTIC
    probe.SEMANTIC = T / "_sem.json"
    try:
        r2 = probe.compare(str(T / "b.json"), str(T / "t.json"))
    finally:
        probe.SEMANTIC = orig_sem
    cell2 = r2["subsets"]["trained-term"]
    check("meaning% is computed from semantic sims (base sim 0.95 >= 0.80 -> 100%)",
          cell2["base"]["meaning_pct"], 100.0)
    check("meaning% reflects a below-threshold tuned sim (0.60 < 0.80 -> 0%)",
          cell2["tuned"]["meaning_pct"], 0.0)


def test_probe_freeze_fails_closed_on_empty_source():
    """F4(round3): a source manifest going empty (manifest_all is gitignored — a fresh checkout
    has none) must fail closed, not silently publish a holdout-only probe."""
    import probe
    raised = ""
    try:
        probe.select([{"text": "x", "terms": ["deploy"]}],   # script rows (single read, #2)
                     {"manifest_all.jsonl": [], "manifest_holdout.jsonl": [{"id": "x", "reference": "z"}]})
    except SystemExit as e:
        raised = str(e)
    check("an empty source manifest raises rather than publishing a partial probe",
          "empty or missing" in raised, True)


def test_probe_pins_the_script_it_was_derived_from():
    """A probe that drifts under the model is not a ruler. The term review WILL grow
    script.jsonl; the sha is what forces a regenerate + re-baseline rather than a silent
    reinterpretation."""
    import probe
    _, sha = probe.select_from_disk()
    check("probe records a full sha256 of script.jsonl", len(sha), 64)
    man = probe.DATA / "manifest_ft_probe.jsonl"
    if man.exists():
        hdr = [l for l in man.read_text().splitlines() if l.startswith("#")]
        check("the frozen manifest pins that same sha", any(sha in l for l in hdr), True)


def test_probe_manifest_is_gitignored():
    """The probe pools manifest_all (PRIVATE, gitignored) with manifest_holdout (public), so
    59 of its 69 rows quote private reference sentences. It must inherit the stricter posture.

    Not hypothetical: the first version of this plan said `git add manifest_ft_probe.jsonl`.
    The repo's privacy discipline is to VERIFY with git check-ignore, not to trust — same as
    the corpus spec did for dataset/ before any audio existed.
    """
    import subprocess
    man = R.FT.parent / "data" / "manifest_ft_probe.jsonl"
    rc = subprocess.run(["git", "check-ignore", "-q", str(man)],
                        cwd=str(R.FT.parent.parent)).returncode
    check("the generated probe manifest is gitignored", rc, 0)
    # the generator itself must NOT be ignored — it is the public, regenerable half
    rc2 = subprocess.run(["git", "check-ignore", "-q", str(R.FT / "probe.py")],
                         cwd=str(R.FT.parent.parent)).returncode
    check("probe.py itself IS committable", rc2 == 0, False)


def test_lora_starts_as_identity():
    """B is zero-init, so a freshly wrapped model must be NUMERICALLY IDENTICAL to the base.
    If not, every 'improvement' is partly the adapter perturbing the model, and the baseline
    is not the model you think it is."""
    import lora
    import mlx.core as mx
    import mlx.nn as nn
    base = nn.Linear(16, 16)
    x = mx.random.normal((4, 16))
    y0 = base(x)
    w = lora.LoRALinear.from_base(base, r=4, alpha=8.0, dropout=0.0)
    check("a freshly wrapped LoRA layer is the identity",
          bool(mx.allclose(w(x), y0, atol=1e-6)), True)


def test_lora_merge_is_equivalent():
    """A merge that quietly differs from the trained model is the most expensive bug here:
    you would ship a model you never evaluated."""
    import lora
    import mlx.core as mx
    import mlx.nn as nn
    base = nn.Linear(16, 16)
    w = lora.LoRALinear.from_base(base, r=4, alpha=8.0, dropout=0.0)
    w.lora_b = mx.random.normal(w.lora_b.shape) * 0.1        # pretend it trained
    x = mx.random.normal((4, 16))
    before = w(x)
    merged = lora.merge_one(w)
    check("merged output == adapter output",
          bool(mx.allclose(merged(x), before, atol=1e-3)), True)
    check("the merged layer is a plain nn.Linear", isinstance(merged, nn.Linear), True)


def test_targets_match_the_production_decode_prefix():
    """Production decodes with DecodingOptions.without_timestamps=False (the default; OLIV
    never overrides it), so the model is ASKED for timestamps. Training on <|notimestamps|>
    — what every standard recipe does — fine-tunes a path the app never takes."""
    import targets
    from mlx_whisper.tokenizer import get_tokenizer
    tok = get_tokenizer(multilingual=True, num_languages=100, language="th", task="transcribe")
    t = targets.build_target(tok, "AWS", dur=2.0)
    check("prefix is the production sot_sequence", tuple(t[:3]), tuple(tok.sot_sequence))
    check("<|notimestamps|> is NOT in the target", tok.no_timestamps in t, False)
    check("the 4th token is <|0.00|>", t[3], tok.timestamp_begin)
    check("it ends <|dur|><|eot|>", (t[-2], t[-1]),
          (tok.timestamp_begin + int(round(2.0 / targets.TS_RESOLUTION)), tok.eot))

    _, _, mask = targets.make_batch_from_targets([t])
    check("the 2 fixed lang/task slots carry no learning signal", float(mask[0, :2].sum()), 0.0)
    check("everything from <|0.00|> onward is supervised",
          float(mask[0].sum()), float(len(t) - 3))


def test_base_loss_under_the_real_format_is_sane():
    """The load-bearing check on the token layout. A wrong layout does not crash — it shows
    up as a loss around 10. The stock model finds its OWN production format cheap: ~0.85."""
    base = _base_model_dir()
    if not base:
        print("  skip base-loss (no model in HF cache)")
        return
    import targets
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    from mlx_whisper.tokenizer import get_tokenizer
    rows = [json.loads(l) for l in (R.FT / "dataset" / "train.jsonl").read_text().splitlines() if l.strip()][:2]
    if not rows:
        print("  skip base-loss (no exported clips yet)")
        return
    tok = get_tokenizer(multilingual=True, num_languages=100, language="th", task="transcribe")
    model = load_model(base, dtype=mx.float16)
    mel, inp, tgt, mask = targets.make_batch(tok, rows)
    loss = float(targets.loss_fn(model, mel, inp, tgt, mask))
    check(f"stock model's loss on its own production format is < 2.0 (got {loss:.3f})",
          loss < 2.0, True)


def test_lora_wraps_encoder_and_decoder():
    base = _base_model_dir()
    if not base:
        print("  skip lora-wrap (no model in HF cache)")
        return
    import lora
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    model = load_model(base, dtype=mx.float16)
    n = lora.apply_lora(model, r=16, alpha=32.0)
    # 32 encoder blocks (self) + 4 decoder blocks x (self + cross) = 40 attn modules, x (q,v)
    check("wraps 80 projections across encoder AND decoder", n, 80)

    # apply_lora alone does NOT freeze anything — without mark_trainable, every one of the
    # 810M params is still trainable and the optimiser would update the whole model.
    check("before mark_trainable, the WHOLE model is trainable (freezing is not implicit)",
          lora.trainable_params(model) > 700_000_000, True)
    lora.mark_trainable(model)
    tp = lora.trainable_params(model)
    check(f"after mark_trainable, only the adapters train ({tp/1e6:.2f}M)", tp < 5_000_000, True)


def test_trainer_can_overfit_one_clip():
    """Not a proof of generalisation — a proof the loop LEARNS. If loss does not collapse on
    a single clip, gradients are not reaching the adapters and every later number is noise.
    Measured in the spike: 0.85 -> 0.0006 in 30 steps."""
    base = _base_model_dir()
    if not base:
        print("  skip trainer smoke (no model in HF cache)")
        return
    import train
    rows = train.load_rows(R.FT / "dataset" / "train.jsonl")[:1]
    if not rows:
        print("  skip trainer smoke (no exported clips yet)")
        return
    losses, _ = train.fit(rows, [], base=base, steps=30, lr=1e-4, batch=1, quiet=True)
    check(f"initial loss is sane, so the target format is right (got {losses[0]:.3f})",
          losses[0] < 2.0, True)
    check(f"loss collapses, so the loop learns (got {losses[-1]:.4f})", losses[-1] < 0.05, True)


# --- second-eye findings, each a confirmed bug turned regression test ---

def test_target_length_limit_is_off_by_one_safe():
    """F5: teacher forcing feeds s[:-1], so a 449-token target = 448 decoder positions and
    fits n_text_ctx=448. The guard must accept 449 and reject 450 — the old `len(seq) > 448`
    wrongly rejected 449. `'x '*n` steps the sequence length by exactly 1 (verified): n=442
    -> 449, n=443 -> 450."""
    import targets
    from mlx_whisper.tokenizer import get_tokenizer
    tok = get_tokenizer(multilingual=True, num_languages=100, language="th", task="transcribe")
    seq449 = targets.build_target(tok, "x " * 442, dur=1.0)   # accepted; raises if guard is wrong
    check("a 449-token target (448 decoder positions) is accepted", len(seq449), 449)
    raised = False
    try:
        targets.build_target(tok, "x " * 443, dur=1.0)        # 450 tokens -> 449 positions
    except ValueError:
        raised = True
    check("a 450-token target (449 decoder positions) is rejected", raised, True)


def test_probe_sha_covers_term_annotations():
    """F3/F7: probe membership depends on the script's `terms`, so the fingerprint must too.
    The REAL property — same text, DIFFERENT terms -> different fingerprint — is tested directly
    on probe.fingerprint. (A prior version only checked sha != raw-text-digest, which an impl
    that JSON-wrapped the text but dropped terms would also pass.)"""
    import probe
    same_text_diff_terms_a = [{"text": "รัน deploy", "terms": ["deploy"]}]
    same_text_diff_terms_b = [{"text": "รัน deploy", "terms": ["deploy", "route"]}]
    check("same text but different terms yields a DIFFERENT fingerprint",
          probe.fingerprint(same_text_diff_terms_a) == probe.fingerprint(same_text_diff_terms_b),
          False)
    check("identical text+terms is stable",
          probe.fingerprint(same_text_diff_terms_a) == probe.fingerprint([{"text": "รัน deploy", "terms": ["deploy"]}]),
          True)
    check("term order does not matter (sorted)",
          probe.fingerprint([{"text": "a", "terms": ["y", "x"]}]) ==
          probe.fingerprint([{"text": "a", "terms": ["x", "y"]}]), True)


def test_epoch_is_exactly_one_pass():
    """F2: an epoch must present each row once — no wrap into the next shuffle to fill the last
    accumulation window. _windows yields ceil(n/batch) micro-batches total, each row exactly once."""
    import train, random
    rows = list(range(30))
    wins = train._windows(rows, batch=2, accum=4, rng=random.Random(0), shuffle=True)
    micro = [c for w in wins for c in w]
    seen = [r for c in micro for r in c]
    check("one epoch presents exactly len(rows) samples (no duplication)", len(seen), 30)
    check("every row appears exactly once", sorted(seen), rows)
    check("micro-batch count is ceil(n/batch)", len(micro), 15)  # ceil(30/2)
    # a full accumulation window holds `accum` micro-batches (the steps branch feeds window[0]
    # to do_update, so this is what makes steps-mode honour accum — F6)
    check("a full window holds `accum` micro-batches", len(wins[0]), 4)


def test_epoch_train_loss_is_token_weighted():
    """F8(round4): the epoch train loss must be token-weighted (to match the token-weighted val
    loss), not an equal average of window means. Tests the real train.weighted_mean helper
    against a hand-computed weighted mean — an equal average would give a different number."""
    import train
    losses, tokens = [1.0, 1.0, 3.0], [40.0, 40.0, 20.0]
    got = train.weighted_mean(losses, tokens)
    check("weighted_mean equals the token-weighted value (1.4), not the equal average (1.667)",
          abs(got - 1.4) < 1e-9, True)


def test_epoch_mode_fit_runs_and_counts_updates():
    """F5(round4): the smoke test returns in steps-mode before epoch code, so epoch accounting
    was untested. Run a real epoch-mode fit and assert the update count reflects accum grouping."""
    base = _base_model_dir()
    if not base:
        print("  skip epoch-mode fit (no model in HF cache)")
        return
    import train
    rows = train.load_rows(R.FT / "dataset" / "train.jsonl")
    if len(rows) < 6:
        print("  skip epoch-mode fit (need >= 6 exported clips)")
        return
    tr, val = rows[:6], rows[6:8] if len(rows) >= 8 else rows[:2]
    losses, model = train.fit(tr, val, base=base, epochs=2, batch=1, accum=2, lr=1e-4, quiet=True)
    # 6 rows, batch 1 -> 6 micro-batches; accum 2 -> 3 updates/epoch; 2 epochs -> 6 updates.
    # accum ignored would be 12; epochs not run would be 0.
    check(f"epoch-mode fit does accum-grouped updates (got {len(losses)})", len(losses), 6)
    check("epoch-mode fit returns a model", model is not None, True)


def test_fit_consumes_accum_micro_batches_per_update():
    """F7/F9(round4/5): steps-mode must feed `accum` micro-batches to each optimiser step, not
    one. BEHAVIOURAL: wrap targets.make_batch with a counter and run a real steps-mode fit —
    steps*accum make_batch calls. If steps-mode sliced the window to one chunk, this would be
    `steps`, not `steps*accum`."""
    base = _base_model_dir()
    if not base:
        print("  skip micro-batch count (no model in HF cache)")
        return
    import train, targets
    rows = train.load_rows(R.FT / "dataset" / "train.jsonl")
    if len(rows) < 8:
        print("  skip micro-batch count (need >= 8 clips)")
        return
    calls = {"n": 0}
    orig = targets.make_batch
    def counting(tok, chunk):
        calls["n"] += 1
        return orig(tok, chunk)
    targets.make_batch = counting
    try:
        train.fit(rows[:8], [], base=base, steps=3, batch=1, accum=2, quiet=True)  # no val -> no evaluate
    finally:
        targets.make_batch = orig
    check("steps-mode does steps*accum micro-batches (3*2=6), proving accum is honoured",
          calls["n"], 6)


def test_fit_restores_best_val_epoch_not_last():
    """F10(round4/5): best-val restore must return the BEST epoch's adapters, not the last.
    BEHAVIOURAL: monkeypatch evaluate to force epoch 1 << epoch 2, snapshot the adapters at each
    boundary, and assert the returned model equals epoch 1's snapshot. Deleting the restore block
    would return epoch 2 and fail this."""
    base = _base_model_dir()
    if not base:
        print("  skip best-val restore (no model in HF cache)")
        return
    import train
    import mlx.core as mx
    from mlx.utils import tree_flatten
    rows = train.load_rows(R.FT / "dataset" / "train.jsonl")
    if len(rows) < 6:
        print("  skip best-val restore (need >= 6 clips)")
        return
    snaps, vals = [], iter([0.10, 0.90])          # epoch 1 is far better than epoch 2
    orig_eval = train.evaluate
    def fake_eval(model, tok, r, batch):
        snaps.append({k: mx.array(v) for k, v in tree_flatten(model.trainable_parameters())})
        return next(vals)
    train.evaluate = fake_eval
    try:
        _, model = train.fit(rows[:6], rows[:2], base=base, epochs=2, batch=1, accum=2, quiet=True)
    finally:
        train.evaluate = orig_eval
    final = dict(tree_flatten(model.trainable_parameters()))
    d_to_ep1 = max(float(mx.max(mx.abs(final[k] - snaps[0][k]))) for k in final)
    d_to_ep2 = max(float(mx.max(mx.abs(final[k] - snaps[1][k]))) for k in final)
    check("returned model matches the BEST epoch (epoch 1), not the last", d_to_ep1 < 1e-6, True)
    check("returned model is NOT the last epoch (epoch 2)", d_to_ep2 > 1e-6, True)


def test_save_preserves_existing_model_on_write_failure():
    """F5(round5): a mid-write failure must NOT destroy the previous known-good model. BEHAVIOURAL:
    write a good model, then monkeypatch save_safetensors to raise during a second save, and assert
    the first model still exists and loads."""
    base = _base_model_dir()
    if not base:
        print("  skip save-failure (no model in HF cache)")
        return
    import train, lora
    import tempfile as _tf
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    with _tf.TemporaryDirectory() as td:
        out = Path(td) / "model_ft"
        m1 = load_model(base, dtype=mx.float16)
        lora.apply_lora(m1, r=8, alpha=16.0, dropout=0.0)
        train.save_mlx_model(m1, base, out)               # good model published
        orig = train.mx.save_safetensors
        train.mx.save_safetensors = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("disk full"))
        raised = False
        try:
            m2 = load_model(base, dtype=mx.float16)
            lora.apply_lora(m2, r=8, alpha=16.0, dropout=0.0)
            train.save_mlx_model(m2, base, out)
        except RuntimeError:
            raised = True
        finally:
            train.mx.save_safetensors = orig
        check("a mid-write save failure propagates", raised, True)
        check("the previous known-good model still exists", out.exists(), True)
        check("...and still loads via the app loader",
              load_model(str(out), dtype=mx.float16) is not None, True)
        check("no .tmp/.bak litter left behind",
              sorted(p.name for p in out.parent.iterdir()), ["model_ft"])


def test_save_overwrites_existing_model_safely():
    """F6(round4): the round-3 save test used a fresh dir only. Save must correctly REPLACE an
    existing model at the default output dir (reused every rerun) and leave a loadable result."""
    base = _base_model_dir()
    if not base:
        print("  skip save-overwrite (no model in HF cache)")
        return
    import train, lora
    import tempfile as _tf
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    with _tf.TemporaryDirectory() as td:
        out = Path(td) / "model_ft"
        m1 = load_model(base, dtype=mx.float16)
        lora.apply_lora(m1, r=8, alpha=16.0, dropout=0.0)
        train.save_mlx_model(m1, base, out)
        first = (out / "weights.safetensors").stat().st_size
        # save a SECOND, differently-perturbed model to the SAME dir
        m2 = load_model(base, dtype=mx.float16)
        lora.apply_lora(m2, r=8, alpha=16.0, dropout=0.0)
        for _, mm in m2.named_modules():
            if isinstance(mm, lora.LoRALinear):
                mm.lora_b = mx.random.normal(mm.lora_b.shape) * 0.1
        train.save_mlx_model(m2, base, out)
        check("overwrite leaves exactly the two model files (no .bak/.tmp litter)",
              sorted(p.name for p in out.parent.iterdir()), ["model_ft"])
        check("the overwritten model still loads via the app loader",
              load_model(str(out), dtype=mx.float16) is not None, True)


def test_trainer_refuses_empty_training_set():
    """F4: export.py ships an empty train.jsonl when only one unique sentence exists (it goes
    to val). fit() used to spin forever at next(batches); it must fail loud instead."""
    import train
    raised = ""
    try:
        train.fit([], [], base="/nonexistent", steps=1, batch=1, quiet=True)
    except ValueError as e:
        raised = str(e)
    check("fit([]) raises ValueError, not a hang", "empty training set" in raised, True)


def test_gradient_accumulation_equals_a_combined_batch():
    """F3/F4: exercise the REAL production helper (train.combine_token_weighted) against an
    INDEPENDENT ground truth — the gradient of one combined batch — not a re-derivation of the
    helper's own formula. A prior version computed the expected value inline and never touched
    train.py, so reverting production to equal-weighting would have left it green."""
    import train
    import mlx.core as mx
    import mlx.nn as nn

    lin = nn.Linear(4, 1)

    def loss_fn(m, x, y, mask):
        pred = m(x).reshape(-1)
        return (((pred - y) ** 2) * mask).sum() / mask.sum()   # per-token mean, like targets.loss_fn

    gfn = nn.value_and_grad(lin, loss_fn)
    # two micro-batches with DIFFERENT supervised-token counts (3 and 4)
    xA = mx.random.normal((3, 4)); yA = mx.random.normal((3,)); mA = mx.array([1.0, 1.0, 1.0])
    xB = mx.random.normal((5, 4)); yB = mx.random.normal((5,)); mB = mx.array([1.0, 1.0, 1.0, 1.0, 0.0])
    lA, gA = gfn(lin, xA, yA, mA)
    lB, gB = gfn(lin, xB, yB, mB)
    acc_grads, _ = train.combine_token_weighted([(gA, float(lA), 3.0), (gB, float(lB), 4.0)])

    # ground truth: ONE combined batch of all rows (7 supervised tokens)
    xC = mx.concatenate([xA, xB]); yC = mx.concatenate([yA, yB]); mC = mx.concatenate([mA, mB])
    _, gC = gfn(lin, xC, yC, mC)
    check("accumulated grad equals the true combined-batch grad (weight)",
          bool(mx.allclose(acc_grads["weight"], gC["weight"], atol=1e-4)), True)
    check("accumulated grad equals the true combined-batch grad (bias)",
          bool(mx.allclose(acc_grads["bias"], gC["bias"], atol=1e-4)), True)


def test_validation_uses_eval_mode():
    """F2: without model.eval(), LoRA dropout stays active during validation and best_w is
    picked on a stochastic loss. evaluate() must be deterministic across calls."""
    base = _base_model_dir()
    if not base:
        print("  skip val-eval-mode (no model in HF cache)")
        return
    import train, lora
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    rows = train.load_rows(R.FT / "dataset" / "train.jsonl")[:2]
    if not rows:
        print("  skip val-eval-mode (no exported clips yet)")
        return
    model = load_model(base, dtype=mx.float16)
    lora.apply_lora(model, r=8, alpha=16.0, dropout=0.5)   # heavy dropout to expose it
    lora.mark_trainable(model)
    # perturb lora_b so dropout has a nonzero path to affect the loss
    for _, m in model.named_modules():
        if isinstance(m, lora.LoRALinear):
            m.lora_b = mx.random.normal(m.lora_b.shape) * 0.1
    tok = train.tokenizer()
    v1 = train.evaluate(model, tok, rows, batch=1)
    v2 = train.evaluate(model, tok, rows, batch=1)
    check(f"validation loss is deterministic across calls ({v1:.5f} == {v2:.5f})",
          abs(v1 - v2) < 1e-6, True)
    check("evaluate() restores training mode afterwards", model.training, True)


def test_saved_model_round_trips_through_the_app_loader():
    """F6: save format is an explicit acceptance criterion and the highest-risk trust boundary
    (filename, flat keys, config copy, merge-before-save). Nothing tested it. Prove a merged,
    perturbed model saved by save_mlx_model loads via mlx_whisper.load_model and matches."""
    base = _base_model_dir()
    if not base:
        print("  skip save round-trip (no model in HF cache)")
        return
    import train, lora, targets
    import tempfile as _tf
    import mlx.core as mx
    from mlx_whisper.load_models import load_model
    from mlx_whisper.tokenizer import get_tokenizer
    rows = train.load_rows(R.FT / "dataset" / "train.jsonl")[:1]
    if not rows:
        print("  skip save round-trip (no exported clips yet)")
        return
    model = load_model(base, dtype=mx.float16)
    lora.apply_lora(model, r=8, alpha=16.0, dropout=0.0)
    for _, m in model.named_modules():
        if isinstance(m, lora.LoRALinear):
            m.lora_b = mx.random.normal(m.lora_b.shape) * 0.05   # a "trained" adapter
    model.eval()
    tok = get_tokenizer(multilingual=True, num_languages=100, language="th", task="transcribe")
    mel, inp, tgt, mask = targets.make_batch(tok, rows)

    # Save while adapters are STILL WRAPPED, so save_mlx_model's merge-before-save is exercised:
    # if the merge were deleted, the saved weights would be the un-adapted base and the reload
    # would NOT match. TemporaryDirectory cleans up the 1.5GB artifact (a leak found earlier).
    with _tf.TemporaryDirectory() as td:
        out = Path(td) / "model_ft"
        train.save_mlx_model(model, base, out)       # merges the wrapped model in place, writes
        check("save_mlx_model merged away every LoRA layer",
              [n for n, m in model.named_modules() if isinstance(m, lora.LoRALinear)], [])
        merged_logits = model(mel, inp)              # in-memory model is now merged
        mx.eval(merged_logits)
        names = sorted(p.name for p in out.iterdir())
        check("save writes exactly config.json + weights.safetensors",
              names, ["config.json", "weights.safetensors"])
        reloaded = load_model(str(out), dtype=mx.float16)   # the app's own loader
        got = reloaded(mel, inp)
        mx.eval(got)
        check("save/load is bit-exact: reloaded logits == merged in-memory model",
              float(mx.max(mx.abs(got - merged_logits))), 0.0)


if __name__ == "__main__":
    test_boundaries()
    test_canonicalise()
    test_leak_guard()
    test_shipped_script_is_clean()
    test_qc()
    test_misread()
    test_insertion_attack()
    test_neighbours_are_separated()
    test_export_gate()
    test_eval_corpus_fails_closed()
    test_leak_predicate_branches()
    # --- the finetune run ---
    test_frozen_rulers_are_never_mined()
    test_probe_contains_no_trained_term()
    test_probe_report_compares_only_shared_clips()
    test_probe_freeze_fails_closed_on_empty_source()
    test_probe_pins_the_script_it_was_derived_from()
    test_probe_manifest_is_gitignored()
    test_lora_starts_as_identity()
    test_lora_merge_is_equivalent()
    test_targets_match_the_production_decode_prefix()
    test_base_loss_under_the_real_format_is_sane()
    test_lora_wraps_encoder_and_decoder()
    test_trainer_can_overfit_one_clip()
    # --- second-eye findings, now regression tests ---
    test_target_length_limit_is_off_by_one_safe()
    test_trainer_refuses_empty_training_set()
    test_gradient_accumulation_equals_a_combined_batch()
    test_validation_uses_eval_mode()
    test_saved_model_round_trips_through_the_app_loader()
    # --- second-eye FIX-ROUND findings, now regression tests ---
    test_probe_sha_covers_term_annotations()
    test_epoch_is_exactly_one_pass()
    test_epoch_train_loss_is_token_weighted()
    test_epoch_mode_fit_runs_and_counts_updates()
    test_fit_consumes_accum_micro_batches_per_update()
    test_fit_restores_best_val_epoch_not_last()
    test_save_overwrites_existing_model_safely()
    test_save_preserves_existing_model_on_write_failure()
    print(f"\n{PASS} passed, {FAIL} failed of {PASS + FAIL}")
    print("ALL PASS" if not FAIL else "FAILURES")
    sys.exit(1 if FAIL else 0)
