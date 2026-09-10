#!/usr/bin/env python3
"""High-throughput recorder for the personal-finetune corpus.

benchmark/record_webapp.py was built for 100 clips: record, stop, listen back, accept —
about 20 s each, which is 13 hours for this script. Here the loop is hold-space, speak,
release: the clip uploads and the next sentence is up before you let go of the key.
Quality control moves from your ears to the server.

    python3 benchmark/finetune/record.py                       # QC only
    benchmark/.venv/bin/python benchmark/finetune/record.py --verify

--verify additionally transcribes each take with the shipped typhoon model in a
background thread and flags takes whose audio does not contain the sentence you were
given. It is not measuring the model — the model is EXPECTED to mangle the English terms.
It catches YOU: a line misread, a word skipped, the wrong row read twice.

The invariant this file exists to protect: **the label on a clip is what was actually
said into it**. Everything below — the take identity, the upload lock, the item snapshot
in the browser, the relabel-or-rerecord fork on edit — serves that one sentence.

RUN IT FROM benchmark/.venv. It used to be stdlib-only, and the docstring still said so
after the leak guard grew a Thai tokeniser — so under system python, pressing E to edit a
sentence died with ModuleNotFoundError mid-session. Rather than degrade the guard when the
tokeniser is missing (a silently weaker leak guard is worse than none, because it still
reports success), this refuses to start.
"""
import argparse
import array
import hashlib
import json
import math
import queue
import secrets
import shutil
import statistics
import subprocess
import tempfile
import threading
import time
import wave
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import evalcorpus
from matching import hostile_chars, is_eval_leak

FT = Path(__file__).resolve().parent
ROOT = FT.parent.parent
SCRIPT = FT / "script.jsonl"
DS = FT / "dataset"
CLIPS, RAW = DS / "clips", DS / "raw"
TAKES, VERIFY, EDITS = DS / "takes.jsonl", DS / "verify.jsonl", DS / "edits.jsonl"
PORT = 8750

TYPHOON_REPO = "chayapats/typhoon-whisper-turbo-mlx"
MAX_UPLOAD = 30 * 1024 * 1024

MIN_DUR, MAX_DUR = 0.8, 25.0
PEAK_CLIP_DB = -1.0
MIN_RMS_DB = -45.0
MIN_VOICED = 0.15
MIN_SNR_DB = 10.0
# Zero-crossing rate. Speech constantly alternates between voiced frames (vowels, low
# ZCR) and unvoiced ones (fricatives, high ZCR); a tone has ONE frequency and cannot.
# Amplitude-modulating a sine to fake a syllable rhythm fakes the energy envelope but
# not this: measured zcr_std 0.0015 for that adversary and 0.0000 for a square wave,
# against 0.070-0.124 for real clips. The band catches hum (0.006) and hiss (0.50).
ZCR_LO, ZCR_HI, ZCR_STD_MIN = 0.02, 0.35, 0.02

STYLE_CYCLE = (["normal"] * 7 + ["fast"] + ["quiet"] + ["normal"] * 7 +
               ["fast"] + ["normal"] * 2 + ["quiet"] + ["normal"] * 2)
STYLE_TH = {"normal": "", "fast": "⏩ พูดเร็วกว่าปกติ", "quiet": "🔉 พูดเบาๆ เหมือนคุยในออฟฟิศ"}


# ---------------------------------------------------------------------- audio QC
def analyse(path: Path) -> dict:
    """Frame-wise analysis of a 16 kHz mono PCM16 wav. Stdlib only — audioop was removed
    in Python 3.13, so the arithmetic is here.

    This is a cheap heuristic, NOT a voice-activity detector. It rejects dead mics,
    clipped takes, tones and noise; it cannot tell you that you read the RIGHT sentence.
    That is --verify's job, and export.py refuses to ship a take without it.
    """
    with wave.open(str(path)) as w:
        n, sr = w.getnframes(), w.getframerate()
        pcm = array.array("h", w.readframes(n))
    if not n:
        return {"ok": False, "why": "ไฟล์ว่าง", "dur": 0.0}

    dur = n / sr
    peak = max(abs(min(pcm)), abs(max(pcm))) or 1
    peak_db = 20 * math.log10(peak / 32768)
    rms_db = 20 * math.log10(
        math.sqrt(sum(v * v for v in pcm) / len(pcm)) / 32768 + 1e-9)

    step = int(sr * 0.02)  # 20 ms frames
    energy, zcr = [], []
    for i in range(0, len(pcm) - step, step):
        ch = pcm[i:i + step]
        e = sum(v * v for v in ch) / len(ch)
        energy.append(20 * math.log10(math.sqrt(e) / 32768) if e > 0 else -90.0)
        zcr.append(sum(1 for k in range(1, len(ch)) if (ch[k - 1] < 0) != (ch[k] < 0))
                   / (len(ch) - 1))
    if not energy:
        return {"ok": False, "why": "สั้นเกินไป", "dur": dur}

    floor = sorted(energy)[len(energy) // 10]          # 10th pct = room tone
    voiced_i = [i for i, v in enumerate(energy) if v > floor + 12]
    voiced_ratio = len(voiced_i) / len(energy)
    vz = [zcr[i] for i in voiced_i]
    snr = (sorted(energy[i] for i in voiced_i)[len(voiced_i) // 2] - floor) if voiced_i else 0.0
    zcr_mean = statistics.mean(vz) if vz else 0.0
    zcr_std = statistics.pstdev(vz) if len(vz) > 1 else 0.0

    m = {"dur": round(dur, 2), "peak_db": round(peak_db, 1), "rms_db": round(rms_db, 1),
         "voiced": round(voiced_ratio, 2), "snr_db": round(snr, 1),
         "zcr": round(zcr_mean, 3), "zcr_std": round(zcr_std, 4)}

    if dur < MIN_DUR:
        return {**m, "ok": False, "why": f"สั้นเกินไป ({dur:.1f} วิ)"}
    if dur > MAX_DUR:
        return {**m, "ok": False, "why": f"ยาวเกินไป ({dur:.0f} วิ)"}
    if peak_db > PEAK_CLIP_DB:
        return {**m, "ok": False, "why": "เสียงดังจนคลิป — ถอยจากไมค์นิดนึง"}
    if rms_db < MIN_RMS_DB:
        return {**m, "ok": False, "why": "แทบไม่ได้ยินเสียงพูด — ไมค์ปิดอยู่หรือเปล่า"}
    # Energy is present but does not behave like speech. Checked after the level test so
    # the two never get confused: under heavy noise the floor rises until almost no frame
    # clears it, which would otherwise read as "silent".
    if voiced_ratio < MIN_VOICED or snr < MIN_SNR_DB:
        return {**m, "ok": False, "why": f"เสียงรบกวนกลบเสียงพูด (SNR {snr:.0f} dB)"}
    if not ZCR_LO <= zcr_mean <= ZCR_HI or zcr_std < ZCR_STD_MIN:
        return {**m, "ok": False, "why": "ไม่พบลักษณะของเสียงพูด (โทน/เสียงรบกวน?)"}
    return {**m, "ok": True, "why": ""}


# ------------------------------------------------------------------ verify worker
class Verifier(threading.Thread):
    daemon = True

    def __init__(self):
        super().__init__()
        self.q: queue.Queue = queue.Queue()
        self.flagged = 0

    def run(self):
        import mlx_whisper
        from verify import misread
        while True:
            cid, audio, label, path, text = self.q.get()
            try:
                r = mlx_whisper.transcribe(
                    str(path), path_or_hf_repo=TYPHOON_REPO,
                    temperature=(0.0, 0.2, 0.4, 0.6, 0.8, 1.0), verbose=False)
                hyp = (r.get("text") or "").strip()
            except Exception as e:
                print(f"  ! verify failed for {cid}: {e}", flush=True)
                continue

            v = misread(text, hyp)
            self.flagged += v["flag"]
            with VERIFY.open("a", encoding="utf-8") as f:
                f.write(json.dumps({"id": cid, "audio": audio, "label": label,
                                    "hyp": hyp, **v}, ensure_ascii=False) + "\n")
            if v["flag"]:
                print(f"  ⚠ {cid} sim={v['sim']:.2f} — อ่านตรงกับประโยคหรือเปล่า?\n"
                      f"      ควรพูด: {text}\n      ได้ยิน : {hyp}", flush=True)


VERIFIER: Verifier | None = None


# ------------------------------------------------------------------------- items
def load_jsonl(p: Path) -> list[dict]:
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text(encoding="utf-8").splitlines() if l.strip()]


def load_items() -> list[dict]:
    if not SCRIPT.exists():
        raise SystemExit(f"ไม่พบ {SCRIPT.relative_to(ROOT)} — รัน build_script.py ก่อน")
    edits = {r["id"]: r["text"] for r in load_jsonl(EDITS)}   # last write wins
    items = []
    for r in load_jsonl(SCRIPT):
        items.append({
            "n": len(items) + 1,
            "id": r["id"],
            "text": edits.get(r["id"], r["text"]),
            "terms": r.get("terms", []),
            "bucket": r.get("bucket", ""),
            "style": STYLE_CYCLE[len(items) % len(STYLE_CYCLE)],
            "verbatim": r.get("bucket") == "fl",   # fl text has the fillers written in
        })
    return items


def sha(b: bytes) -> str:
    return hashlib.sha1(b).hexdigest()[:16]


def label_hash(text: str) -> str:
    return sha(text.encode())


def wav_path(cid: str, audio: str) -> Path:
    """Immutable. A take's audio is never overwritten, so a crash between publishing the
    WAV and appending its metadata leaves an orphan file, not a clip whose audio and
    label came from different takes."""
    return CLIPS / f"{cid}__{audio}.wav"


def latest_takes() -> dict[str, dict]:
    """Last row per sentence — re-recording is how a bad take is fixed, and an
    invalidated row is how an edited one is retired. Append-only, last write wins."""
    out = {}
    for r in load_jsonl(TAKES):
        out[r["id"]] = r
    return out


def verdict_key(t: dict) -> tuple:
    """A verdict is only about ONE (audio, label) pair.

    Keying it by audio alone was a silent hole: relabelling keeps the audio, so a take
    whose label had been edited inherited the clean verdict earned by the OLD label, and
    export shipped a sentence that was never spoken. Identity has to include both halves
    of the thing being asserted."""
    return (t["id"], t.get("audio"), t.get("label"))


def done_ids() -> set[str]:
    return {cid for cid, t in latest_takes().items() if not t.get("invalid")}


PAGE = """<!doctype html><html lang="th"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>OLIV — อัดเสียง finetune</title>
<style>
:root{--paper:#eadfc4;--surf:#f6efdc;--ink:#241f11;--ink2:#4d4530;--muted:#6a5f45;
--line:#d1c39a;--olive:#57761f;--olive-d:#40501f;--olive-l:#e4e8c6;--bad:#a8451f;--badbg:#f7e0d2}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-family:"IBM Plex Sans Thai",system-ui,sans-serif;line-height:1.5}
.wrap{max-width:760px;margin:0 auto;padding:14px 16px 50px}
header{display:flex;align-items:center;gap:10px}
header b{color:var(--olive)}
.prog{flex:1;height:8px;background:var(--surf);border:1px solid var(--line);border-radius:5px;overflow:hidden}
.prog i{display:block;height:100%;background:var(--olive);width:0%;transition:width .2s}
.count{font-size:.85rem;color:var(--muted);white-space:nowrap;font-variant-numeric:tabular-nums}
.card{background:var(--surf);border:1px solid var(--line);border-radius:18px;padding:22px;margin-top:12px}
.card.busy{opacity:.72}
.meta{display:flex;gap:8px;align-items:center;font-size:.8rem;color:var(--muted);flex-wrap:wrap}
.chip{background:var(--olive-l);color:var(--olive-d);border-radius:20px;padding:2px 10px;font-weight:600}
.chip.style{background:#f0e3c8;color:#7a5a12}
.chip.verb{background:var(--badbg);color:var(--bad)}
.sent{font-size:1.55rem;font-weight:600;margin:16px 0;min-height:2.8em;outline:none;border-radius:10px}
.sent[contenteditable=true]{background:#fffdf5;box-shadow:0 0 0 2px var(--olive);padding:8px}
.mic{display:flex;align-items:center;gap:12px;margin-top:6px}
.lvl{flex:1;height:22px;background:#e2d7b8;border-radius:6px;overflow:hidden}
.lvl i{display:block;height:100%;width:0%;background:linear-gradient(90deg,var(--olive),#8aa63a)}
.lvl.on i{background:linear-gradient(90deg,var(--bad),#d4703f)}
.state{font-family:ui-monospace,monospace;font-size:.9rem;color:var(--muted);min-width:9em}
.toast{margin-top:12px;border-radius:10px;padding:10px 14px;font-size:.92rem;font-weight:600;display:none}
.toast.bad{background:var(--badbg);color:var(--bad);display:block}
.toast.ok{background:var(--olive-l);color:var(--olive-d);display:block}
.fork{margin-top:12px;background:var(--badbg);border-radius:12px;padding:14px;display:none}
.fork p{margin:0 0 10px;font-size:.92rem;color:var(--bad);font-weight:600}
.fork button{padding:10px 14px;margin-right:8px;border-radius:10px;border:1px solid var(--line);background:var(--surf);font:inherit;font-weight:600;cursor:pointer}
.fork .keep{background:var(--olive);border-color:var(--olive);color:#fff}
.keys{margin-top:16px;font-size:.84rem;color:var(--muted);display:flex;gap:16px;flex-wrap:wrap}
kbd{background:var(--surf);border:1px solid var(--line);border-bottom-width:2px;border-radius:5px;padding:1px 6px;font-family:ui-monospace,monospace;font-size:.85em}
.stats{display:flex;gap:18px;margin-top:14px;font-size:.85rem;color:var(--muted);flex-wrap:wrap}
.stats b{color:var(--ink2);font-variant-numeric:tabular-nums}
.done{text-align:center;font-size:1.3rem;padding:50px 0}
</style></head><body><div class="wrap">
<header><b>OLIV</b><span style="font-size:.9rem">finetune corpus</span>
<div class="prog"><i id="bar"></i></div><span class="count" id="count"></span></header>

<div class="card" id="card">
  <div class="meta">
    <span id="num"></span><span class="chip" id="bucket"></span>
    <span class="chip style" id="style" style="display:none"></span>
    <span class="chip verb" id="verb" style="display:none">อ่านทุกคำ รวมคำเติม</span>
  </div>
  <div class="sent" id="sent"></div>
  <div class="mic">
    <div class="lvl" id="lvl"><i id="lvlbar"></i></div>
    <div class="state" id="state">พร้อม</div>
  </div>
  <div class="toast" id="toast"></div>
  <div class="fork" id="fork">
    <p>ข้อนี้อัดไปแล้ว — เสียงเดิมพูดตามข้อความ<em>เก่า</em> คุณแก้ข้อความแล้ว เสียงกับ label ไม่ตรงกันแล้ว</p>
    <button class="keep" id="relabel">เสียงที่อัดไว้พูดแบบใหม่นี้แหละ — เปลี่ยน label</button>
    <button id="rerec">อัดใหม่</button>
  </div>
  <div class="keys">
    <span><kbd>Space</kbd> กดค้าง = อัด · ปล่อย = ไปข้อถัดไป</span>
    <span><kbd>E</kbd> แก้ข้อความ</span>
    <span><kbd>←</kbd> ย้อนกลับ</span>
    <span><kbd>Esc</kbd> ทิ้งเทค</span>
  </div>
</div>

<div class="stats">
  <span>เซสชันนี้ <b id="sess">0</b></span>
  <span>ความเร็ว <b id="pace">—</b> วิ/คลิป</span>
  <span>เหลืออีก <b id="eta">—</b></span>
  <span>ไมค์ <b id="dev">—</b></span>
</div>
<p class="stats" style="color:var(--muted)">กดค้างแล้ว <b>หายใจสักจังหวะก่อนพูด</b> — ไม่งั้นคำแรกจะโดนตัด · อัดหลายวันหลายไมค์ดีกว่าอัดรวดเดียว</p>
</div><script>
const K=new URLSearchParams(location.search).get('k')||'';
let items=[],done=new Set(),idx=0,rec=null,chunks=[],stream=null,an=null,
    recording=false,uploading=false,cancelled=false,pending=null,
    sess=0,sessT0=Date.now();
const $=id=>document.getElementById(id);
const api=async p=>{const r=await fetch(p+(p.includes('?')?'&':'?')+'k='+K);if(!r.ok)throw new Error(r.status);return r.json()};
const firstUndone=()=>{const i=items.findIndex(x=>!done.has(x.id));return i<0?items.length-1:i};
// Any state where the displayed item must not change out from under an in-flight take.
const locked=()=>recording||uploading||$('fork').style.display==='block'
                 ||$('sent').getAttribute('contenteditable')==='true';

function render(){
  const it=items[idx];if(!it)return;
  if(done.size===items.length){$('card').innerHTML='<div class="done">🎉 ครบ '+items.length+' ข้อ<br><span style="font-size:.9rem;color:var(--muted)">รัน export.py เพื่อสร้าง train/val</span></div>';return}
  $('num').textContent='ข้อ '+it.n+' / '+items.length+(done.has(it.id)?' ✓':'');
  $('bucket').textContent=it.bucket;
  $('sent').textContent=it.text;
  $('style').style.display=it.styleTh?'inline':'none';$('style').textContent=it.styleTh;
  $('verb').style.display=it.verbatim?'inline':'none';
  $('bar').style.width=(100*done.size/items.length)+'%';
  $('count').textContent=done.size+'/'+items.length;
  const left=items.length-done.size, pace=sess>1?(Date.now()-sessT0)/1000/sess:null;
  $('sess').textContent=sess;
  $('pace').textContent=pace?pace.toFixed(1):'—';
  $('eta').textContent=pace?(left*pace/3600).toFixed(1)+' ชม.':'—';
  $('card').classList.toggle('busy',locked());
}
function toast(msg,cls){const t=$('toast');t.textContent=msg;t.className='toast '+cls;
  if(cls==='ok')setTimeout(()=>{if(t.textContent===msg)t.className='toast'},1400)}

async function ensureMic(){
  if(stream)return;
  stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:false,noiseSuppression:false,autoGainControl:false}});
  $('dev').textContent=stream.getAudioTracks()[0].label||'default';
  const ac=new AudioContext();an=ac.createAnalyser();an.fftSize=512;
  ac.createMediaStreamSource(stream).connect(an);
  const buf=new Uint8Array(an.frequencyBinCount);
  (function meter(){
    an.getByteTimeDomainData(buf);
    let peak=0;for(const v of buf)peak=Math.max(peak,Math.abs(v-128));
    $('lvlbar').style.width=Math.min(100,peak/128*140)+'%';
    requestAnimationFrame(meter);
  })();
}
async function start(){
  if(recording||uploading||locked())return;
  try{await ensureMic()}catch(e){toast('เปิดไมค์ไม่ได้: '+e.message,'bad');return}
  // Snapshot the item NOW. idx can move (navigation, auto-advance) between pressing the
  // key and the upload landing; reading items[idx] later would post this audio under a
  // different sentence's id and label.
  pending={id:items[idx].id,style:items[idx].style,label:items[idx].labelHash};
  const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm'].find(m=>MediaRecorder.isTypeSupported(m))||'';
  chunks=[];cancelled=false;
  rec=new MediaRecorder(stream,mime?{mimeType:mime}:{});
  rec.ondataavailable=e=>chunks.push(e.data);
  rec.onstop=()=>{
    recording=false;$('lvl').classList.remove('on');
    if(cancelled){$('state').textContent='ทิ้งแล้ว';pending=null;render();return}
    upload(new Blob(chunks,{type:rec.mimeType}),pending);
  };
  rec.start();recording=true;cancelled=false;stopping=false;
  $('lvl').classList.add('on');$('state').textContent='● อัดอยู่';$('toast').className='toast';
  render();
}
let stopping=false;
function stop(cancel){
  if(!recording)return;
  // Latch. Escape sets cancelled; releasing Space inside the 250 ms tail window then
  // called stop(false), which cleared it, and the discarded take uploaded anyway.
  cancelled=cancelled||!!cancel;
  if(stopping)return;
  stopping=true;
  setTimeout(()=>{if(rec&&rec.state==='recording')rec.stop();stopping=false},250);
}
async function upload(blob,snap){
  uploading=true;$('state').textContent='กำลังส่ง…';render();
  try{
    const r=await fetch('/api/take?k='+K+'&id='+snap.id+'&style='+snap.style
                        +'&label='+snap.label
                        +'&dev='+encodeURIComponent($('dev').textContent),
      {method:'POST',headers:{'Content-Type':blob.type||'application/octet-stream'},body:blob});
    const j=await r.json();
    if(!j.ok){toast('✗ '+j.why+' — อัดใหม่','bad')}
    else{
      done.add(snap.id);sess++;
      toast('✓ '+j.dur+' วิ','ok');
      idx=firstUndone();
    }
  }catch(e){toast('ส่งไม่สำเร็จ: '+e.message+' — อัดใหม่','bad')}
  uploading=false;pending=null;$('state').textContent='พร้อม';render();
}

// ---- editing -------------------------------------------------------------------
let editPrev='';
const sent=$('sent');
function beginEdit(){
  if(locked())return;
  editPrev=items[idx].text;
  sent.setAttribute('contenteditable','true');sent.focus();
  const r=document.createRange();r.selectNodeContents(sent);
  getSelection().removeAllRanges();getSelection().addRange(r);
  render();
}
sent.addEventListener('blur',async()=>{
  if(sent.getAttribute('contenteditable')!=='true')return;
  sent.setAttribute('contenteditable','false');
  const text=sent.textContent.trim(), it=items[idx];
  if(!text||text===editPrev){sent.textContent=it.text;render();return}
  const er=await fetch('/api/edit?k='+K+'&id='+it.id,{method:'POST',
    headers:{'Content-Type':'application/json'},body:JSON.stringify({text})});
  const ej=await er.json();
  if(!ej.ok){sent.textContent=it.text;toast('✗ '+ej.why,'bad');render();return}
  it.text=text;it.labelHash=ej.label;
  if(ej.wasDone){
    // The server already retired the old take. Nothing exportable survives this edit
    // even if the tab dies right here; the fork below only decides how to recover.
    done.delete(it.id);
    $('fork').style.display='block';
  }else{
    toast('แก้ข้อความแล้ว — อัดให้ตรงกับที่แก้','ok');
  }
  render();
});
$('relabel').onclick=async()=>{
  const it=items[idx];
  // Post the label we are CONFIRMING. Another tab may have edited this item since the
  // fork appeared; the server must relabel the audio with the sentence the human just
  // looked at, or refuse.
  const r=await fetch('/api/relabel?k='+K+'&id='+it.id+'&label='+it.labelHash,{method:'POST',
    headers:{'Content-Type':'application/json'},body:'{}'});
  const j=await r.json();
  $('fork').style.display='none';
  if(!j.ok){toast('✗ '+j.why+' — อัดใหม่','bad');render();return}
  done.add(it.id);
  toast('เปลี่ยน label ของเสียงเดิมแล้ว — ส่งไป verify ใหม่','ok');
  render();
};
$('rerec').onclick=async()=>{
  const it=items[idx];
  done.delete(it.id);              // already retired server-side by the edit
  $('fork').style.display='none';
  toast('ทิ้งเทคเดิมแล้ว — กด Space อัดใหม่','ok');
  render();
};

document.addEventListener('keydown',e=>{
  if(sent.getAttribute('contenteditable')==='true'){
    if(e.key==='Enter'){e.preventDefault();sent.blur()}
    if(e.key==='Escape'){sent.textContent=editPrev;sent.setAttribute('contenteditable','false');render()}
    return;
  }
  if($('fork').style.display==='block')return;      // resolve the fork first
  if(e.code==='Space'&&!e.repeat){e.preventDefault();start()}
  if(e.key==='Escape'&&recording){e.preventDefault();stop(true)}
  if(e.key==='e'||e.key==='E'){e.preventDefault();beginEdit()}
  if(e.key==='ArrowLeft'&&idx>0&&!locked()){e.preventDefault();idx--;render()}
  if(e.key==='ArrowRight'&&idx<items.length-1&&!locked()){e.preventDefault();idx++;render()}
});
document.addEventListener('keyup',e=>{
  if(e.code==='Space'&&recording&&sent.getAttribute('contenteditable')!=='true'){
    e.preventDefault();stop(false)}
});
(async()=>{
  items=await api('/api/items');
  (await api('/api/status')).done.forEach(id=>done.add(id));
  idx=firstUndone();render();
})().catch(e=>{document.body.innerHTML='<p style="padding:30px">โหลดไม่ได้ ('+e.message+')</p>'});
</script></body></html>"""


EXT = {"audio/mp4": "m4a", "audio/webm": "webm", "audio/ogg": "ogg", "audio/wav": "wav"}
ITEMS: list[dict] = []
BY_ID: dict[str, dict] = {}
TOKEN = ""

# One lock per sentence. Two uploads for the same id can otherwise interleave so the
# surviving WAV comes from request B while the surviving metadata row comes from
# request A — audio and label from different takes, which is the one thing this file
# exists to prevent. Cheap: a single user never contends.
_LOCKS: dict[str, threading.Lock] = defaultdict(threading.Lock)
_LOCKS_GUARD = threading.Lock()


def lock_for(cid: str) -> threading.Lock:
    with _LOCKS_GUARD:
        return _LOCKS[cid]


def token() -> str:
    """Stable across restarts. This runs for weeks and is stopped and started dozens of
    times; a fresh token each launch means hunting the terminal for a new URL each time."""
    f = DS / ".token"
    if f.exists():
        return f.read_text().strip()
    t = secrets.token_urlsafe(8)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(t)
    return t


def append(path: Path, row: dict) -> None:
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _q(self):
        u = urlparse(self.path)
        return u.path, {k: v[0] for k, v in parse_qs(u.query).items()}

    def do_GET(self):
        path, q = self._q()
        if q.get("k") != TOKEN:
            return self._send(403, {"error": "bad token"})
        if path == "/":
            return self._send(200, PAGE.encode(), "text/html")
        if path == "/api/items":
            return self._send(200, [{**it, "styleTh": STYLE_TH.get(it["style"], ""),
                                     "labelHash": label_hash(it["text"])} for it in ITEMS])
        if path == "/api/status":
            return self._send(200, {"done": sorted(done_ids())})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path, q = self._q()
        if q.get("k") != TOKEN:
            return self._send(403, {"error": "bad token"})
        cid = q.get("id", "")
        if cid not in BY_ID:
            return self._send(400, {"ok": False, "why": "unknown id"})
        length = int(self.headers.get("Content-Length", 0))
        if not 0 <= length <= MAX_UPLOAD:
            return self._send(413, {"ok": False, "why": "size"})
        body = self.rfile.read(length) if length else b"{}"
        it = BY_ID[cid]

        if path == "/api/edit":
            text = json.loads(body)["text"].strip()
            if not text:
                return self._send(400, {"ok": False, "why": "ข้อความว่าง"})
            bad = hostile_chars(text)
            if bad:
                print(f"  ✗ {cid}  edit refused — hostile characters: {bad}", flush=True)
                return self._send(200, {"ok": False,
                                        "why": f"มีอักขระควบคุมที่ไม่อนุญาต: {bad[0]}"})
            # The script was leak-checked at generation time; a free-text edit is a hole
            # straight past that. Same predicate, same corpus, no exceptions.
            hit = is_eval_leak(text, FORBIDDEN)
            if hit:
                print(f"  ✗ {cid}  edit refused — leaks eval sentence: {hit}", flush=True)
                return self._send(200, {"ok": False,
                                        "why": f"ประโยคนี้ซ้ำกับชุดทดสอบ: {hit[:40]}"})
            with lock_for(cid):
                # ORDER MATTERS, and it is the opposite of the obvious one. The audio on
                # disk says the OLD words, so the take must stop being exportable BEFORE
                # the new label becomes durable. Written the other way round, a crash
                # between the two appends leaves the edit applied on restart while the old
                # take is still valid — the exact mismatch this whole file exists to
                # prevent, produced by the very act of correcting it.
                #
                # Retire first, edit second, restore on relabel. Every crash point in
                # between fails to a take that simply needs re-recording.
                prev = latest_takes().get(cid)
                was_done = bool(prev) and not prev.get("invalid")
                if was_done:
                    append(TAKES, {"id": cid, "invalid": True, "reason": "edited",
                                   "audio": prev.get("audio"), "text": prev.get("text", ""),
                                   "ts": int(time.time())})
                append(EDITS, {"id": cid, "text": text, "ts": int(time.time())})
                it["text"] = text
            print(f"  ✎ {cid}  {text}" + ("  (take retired pending your choice)" if was_done else ""),
                  flush=True)
            return self._send(200, {"ok": True, "label": label_hash(text),
                                    "wasDone": was_done})

        if path == "/api/relabel":
            # You edited the sentence AFTER recording it, and confirmed the audio already
            # says the new words. Supersede the take's label, keep the audio, and send it
            # back through verification — which is exactly what would catch you if the
            # audio does not in fact say this.
            with lock_for(cid):
                # The take we are relabelling was invalidated by /api/edit. Find the last
                # REAL take, and rebuild from it.
                prev = None
                for r in load_jsonl(TAKES):
                    if r["id"] == cid and not r.get("invalid"):
                        prev = r
                if not prev:
                    return self._send(409, {"ok": False, "why": "no take to relabel"})
                # Same audio, different label = a DIFFERENT claim, and the old verdict
                # said nothing about it. The new label hash makes that structural: export
                # joins on (id, audio, label) and will not find a verdict until this one
                # has been checked on its own terms.
                # Capture the text INSIDE the lock. Reading it["text"] again afterwards
                # let a concurrent edit make the verifier judge one sentence and file the
                # verdict under another one's hash.
                text = it["text"]
                # And confirm it is the sentence the human actually looked at. Without
                # this, two tabs editing the same item race: A sees the fork for its text,
                # B edits to something else, A clicks confirm, and the audio is relabelled
                # with B's sentence — which nobody spoke and nobody approved.
                want = q.get("label")
                if want != label_hash(text):        # required, see /api/take
                    return self._send(409, {"ok": False,
                                            "why": "ข้อความเปลี่ยนไปแล้ว — โหลดหน้าใหม่"})
                row = {**prev, "text": text, "label": label_hash(text),
                       "relabeled": True, "invalid": False, "ts": int(time.time())}
                append(TAKES, row)
            if VERIFIER:
                VERIFIER.q.put((cid, row["audio"], row["label"],
                                wav_path(cid, row["audio"]), text))
            print(f"  ↻ {cid}  relabelled -> re-verifying", flush=True)
            return self._send(200, {"ok": True})

        if path == "/api/invalidate":
            with lock_for(cid):
                append(TAKES, {"id": cid, "invalid": True, "ts": int(time.time())})
            print(f"  ✗ {cid}  take invalidated — needs re-recording", flush=True)
            return self._send(200, {"ok": True})

        if path != "/api/take":
            return self._send(404, {"ok": False, "why": "not found"})
        if not length:
            return self._send(400, {"ok": False, "why": "empty upload"})

        # Everything from here to the metadata append is one transaction for this id.
        with lock_for(cid):
            ext = EXT.get((self.headers.get("Content-Type") or "").split(";")[0].strip(), "bin")
            rawf = RAW / f"{cid}.{ext}"
            rawf.write_bytes(body)

            with tempfile.NamedTemporaryFile(suffix=".wav", dir=CLIPS, delete=False) as tf:
                tmp = Path(tf.name)
            p = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(rawf),
                                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(tmp)],
                               capture_output=True, text=True)
            if p.returncode != 0:
                tmp.unlink(missing_ok=True)
                return self._send(200, {"ok": False, "why": "แปลงไฟล์ไม่ได้ (ffmpeg)"})

            qc = analyse(tmp)
            if not qc["ok"]:
                # A rejected take never lands in clips/. The training set only ever sees
                # audio that passed; the raw upload stays for forensics.
                tmp.unlink(missing_ok=True)
                print(f"  ✗ {cid}  {qc['why']}", flush=True)
                return self._send(200, {"ok": False, **qc})

            # The label the browser SHOWED when recording started. If it no longer
            # matches, the sentence was edited mid-take (another tab, a stray keypress)
            # and this audio speaks the old words. Refuse rather than mislabel it.
            text = it["text"]
            lab = label_hash(text)
            posted = q.get("label")
            # REQUIRED, not "checked if supplied". `if posted and posted != lab` let any
            # client skip the check by simply omitting the parameter — and an old tab left
            # open across a server restart is exactly such a client, since the token
            # persists. A check you can opt out of is not a check.
            if posted != lab:
                tmp.unlink(missing_ok=True)
                why = ("ข้อความเปลี่ยนระหว่างอัด — อัดใหม่" if posted
                       else "client ไม่ได้ส่ง label hash — โหลดหน้าใหม่")
                print(f"  ✗ {cid}  label hash {'mismatch' if posted else 'MISSING'}", flush=True)
                return self._send(200, {"ok": False, "why": why})

            audio = sha(tmp.read_bytes())
            wav = wav_path(cid, audio)
            shutil.move(str(tmp), wav)       # immutable name: never clobbers a prior take
            row = {"id": cid, "audio": audio, "label": lab, "text": text,
                   "terms": it["terms"], "bucket": it["bucket"],
                   "style": q.get("style", "normal"), "device": q.get("dev", ""),
                   "ts": int(time.time()),
                   **{k: qc[k] for k in ("dur", "peak_db", "rms_db", "voiced", "snr_db",
                                         "zcr", "zcr_std")}}
            append(TAKES, row)

        if VERIFIER:
            VERIFIER.q.put((cid, audio, lab, wav, text))
        print(f"  ✓ {cid}  {qc['dur']}s  snr {qc['snr_db']}dB", flush=True)
        return self._send(200, {"ok": True, "dur": qc["dur"]})

    def log_message(self, *a):
        pass


FORBIDDEN: list[str] = []


def main():
    global VERIFIER, ITEMS, BY_ID, TOKEN, FORBIDDEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true",
                    help="transcribe each take with typhoon to catch misread lines")
    ap.add_argument("--port", type=int, default=PORT)
    a = ap.parse_args()

    # Fail here, loudly, rather than inside a request handler when you edit a sentence.
    try:
        import pythainlp.tokenize  # noqa: F401
    except ImportError:
        raise SystemExit(
            "REFUSING — the leak guard needs a Thai tokeniser (pythainlp) to see a\n"
            "reordered eval sentence, and it is not importable here.\n\n"
            "  benchmark/.venv/bin/python benchmark/finetune/record.py --verify\n\n"
            "Running without it would mean a weaker guard that still reports success.")

    CLIPS.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(parents=True, exist_ok=True)
    TOKEN = token()
    FORBIDDEN = evalcorpus.load()      # aborts if the eval corpus is missing or empty
    ITEMS = load_items()
    BY_ID = {it["id"]: it for it in ITEMS}

    d = len(done_ids())
    if a.verify:
        VERIFIER = Verifier()
        VERIFIER.start()
        # The queue was in-memory only, so anything still pending when you last quit was
        # lost — and export drops takes with no verdict. Over a multi-day recording effort
        # that quietly bleeds clips. Re-enqueue everything still missing a verdict for its
        # exact (audio, label).
        have = {(v["id"], v.get("audio"), v.get("label")) for v in load_jsonl(VERIFY)}
        backlog = [t for t in latest_takes().values()
                   if not t.get("invalid") and verdict_key(t) not in have]
        for t in backlog:
            VERIFIER.q.put((t["id"], t["audio"], t["label"],
                            wav_path(t["id"], t["audio"]), t["text"]))
        if backlog:
            print(f"  re-queued {len(backlog)} take(s) that were never verified")

    print(f"OLIV finetune recorder — {len(ITEMS)} sentences, {d} recorded, {len(ITEMS)-d} to go")
    if a.verify:
        print("  verify: on (typhoon) — misread takes get flagged and export drops them")
    else:
        print("  verify: OFF — export.py will REFUSE these takes. Rerun from benchmark/.venv"
              "\n          with --verify unless you plan to pass --allow-unverified.")
    print(f"  http://127.0.0.1:{a.port}/?k={TOKEN}\n", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()


if __name__ == "__main__":
    main()
