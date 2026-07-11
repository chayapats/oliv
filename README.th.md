<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/oliv-mark-white-160.png">
  <img src="docs/img/oliv-mark-160.png" alt="โลโก้ OLIV — ลูกมะกอกกับคลื่นเสียง" width="80">
</picture>

# OLIV — Offline Local Inference Voice

**พิมพ์ด้วยเสียง ไทยปนอังกฤษ ทำงานในเครื่องทั้งหมด สำหรับ macOS**
กดปุ่มแล้วพูดไทยปนศัพท์อังกฤษได้เลย OLIV พิมพ์ออกมา*ถูก* — บน Mac ของคุณ ไม่ส่งเสียงขึ้น cloud

> 🇬🇧 [English version →](README.md)

<a href="https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg"><img src="https://img.shields.io/github/v/release/chayapats/oliv?style=for-the-badge&label=%E2%AC%87%EF%B8%8F%20%20%E0%B9%82%E0%B8%AB%E0%B8%A5%E0%B8%94%E0%B8%AA%E0%B8%B3%E0%B8%AB%E0%B8%A3%E0%B8%B1%E0%B8%9A%20macOS&color=57761f" alt="ดาวน์โหลด OLIV สำหรับ macOS — คลิกเดียว ไฟล์ .dmg โหลดทันที"></a>

**คลิกเดียว — ไฟล์ `.dmg` เริ่มโหลดทันที** · Apple Silicon (M1 ขึ้นไป) · ฟรี โอเพนซอร์ส · [ทุกเวอร์ชัน](https://github.com/chayapats/oliv/releases)

<img src="docs/img/oliv-demo.gif" alt="เดโม: OLIV ได้ยินคำทับศัพท์แล้วพิมพ์กลับเป็นอังกฤษให้ถูกต้อง" width="840">

📊 **[Benchmark แบบตรงไปตรงมา — แม่นแค่ไหน ดูเอง →](https://chayapats.github.io/oliv/)** ·
ฉบับเต็มอยู่ใน [`docs/index.html`](docs/index.html) (สองภาษา ทำซ้ำได้ โชว์เคสที่พลาดด้วย)

---

## มันทำอะไร

แอปพิมพ์ตามเสียงภาษาไทยมักสะกดคำอังกฤษออกมาเป็นตัวไทยเพราะเสียงคล้ายกัน (`ดีพลอย`, `เกรดเวย์`) — OLIV แปลงเฉพาะคำพวกนั้นกลับเป็นอังกฤษ ส่วนอื่นไม่แตะ:

```
ได้ยิน  ตัวบิวท์เฟลล์เพราะดิเพนเดนซี่เวอร์ชั่นไม่ตรง
OLIV →  ตัว build fail เพราะ dependency version ไม่ตรง
```

Pipeline: **Typhoon-turbo STT** (Whisper-turbo ที่ fine-tune สำหรับภาษาไทย) → แก้คำด้วยพจนานุกรม/การเทียบเสียงแบบ deterministic → โมเดลเล็ก **Gemma-E2B** เป็นตัวช่วยแก้คำทับศัพท์กลับเป็นอังกฤษ — ทุกขั้นรันในเครื่อง

## แม่นแค่ไหน — บอกตามตรง

วัดแบบ "ความหมายตรง" (LaBSE semantic similarity นับว่าผ่านที่ ≥ 0.80 — **ไม่ใช่ความถูกต้องแบบคำต่อคำ**) จากการรันจริงหนึ่งรอบของ pipeline ตัวเดียวกับที่ให้โหลด:

| ชุดทดสอบ | ความหมายตรง | n |
|---|---|---|
| **Held-out** (ศัพท์ใหม่ ไม่เคยใช้จูนระบบ) | **~90%** | 40 |
| ชุดจูน | ~92% | 194 |
| ชุดยืนยัน | ~87% | 30 |

- ตัวช่วยแก้คือพระเอกตัวจริง: ในชุด held-out ถ้าถอดมันออก ตัวเลขร่วงเหลือ **~65%**
- เทียบกับ cloud: pipeline เต็มของ OLIV ชนะ Whisper large-v3 แบบดิบที่โฮสต์บน Groq (~84%) — แถมเสียงเป็นส่วนตัวและโมเดลเล็กกว่าราวครึ่งหนึ่ง แต่พูดตรงๆ: โมเดลฟังเสียง*ดิบๆ* ของ OLIV อ่อนกว่าโมเดล cloud ตัวใหญ่อยู่เล็กน้อย — ที่ชนะคือระบบรวมทั้งเส้น ไม่ใช่การถอดเสียงดิบ

**อ่าน[ข้อจำกัด](docs/index.html)ก่อนเชื่อตัวเลขพวกนี้** — ที่สำคัญสุด: benchmark อัดจากเสียง**คนเดียว** (ตัวผู้พัฒนาเอง) ยังไม่ได้ทดสอบกับผู้พูดคนอื่น สำเนียงอื่น หรือที่มีเสียงรบกวน · ชื่อเฉพาะกับตัวเลขอาจพิมพ์ผิดได้ทั้งที่ความหมายนับว่าตรง — เหลือบดูก่อนส่งข้อความ

## สเปกที่ต้องมี

- Mac ชิป **Apple Silicon** (M1 ขึ้นไป), macOS
- โหลดโมเดลครั้งเดียว **≈ 5 GB** ดึงจาก Hugging Face ตอนเปิดใช้ครั้งแรก:
  - STT ~1.5 GB — [`chayapats/typhoon-whisper-turbo-mlx`](https://huggingface.co/chayapats/typhoon-whisper-turbo-mlx) (เราแปลง Typhoon ของ SCB 10X เป็น MLX เอง)
  - ตัวช่วยแก้คำ ~3.3 GB — [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)
- หลังจากนั้นใช้ออฟไลน์ได้เต็มรูปแบบ · ~1.1–1.3 วินาทีต่อประโยค

## ติดตั้ง

1. [**โหลด OLIV.dmg**](https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg) (หรือเลือกเวอร์ชันเองที่ [Releases](https://github.com/chayapats/oliv/releases))
2. เปิดไฟล์ ลาก **OLIV** ลงโฟลเดอร์ **Applications** แล้วเปิดแอป
3. ให้สิทธิ์ไมโครโฟนกับ accessibility แล้วตั้งปุ่มกดพูด (push-to-talk) ใน Settings

## ฟีเจอร์ & สิ่งที่ปรับแต่งได้

ของปรับได้เยอะกว่าที่เห็นตอนแรก — ทั้งหมดอยู่ที่ไอคอนมะกอกบนเมนูบาร์ กับ **Settings…** (⌘,)

**ในเมนู**
- **Recent…** — เก็บข้อความที่เพิ่งพูดไป 10 รายการล่าสุด คลิกแล้ว copy กลับมาให้เลย (กด ⌘V วางได้ทันที) เก็บไว้ในแรมอย่างเดียว ไม่เขียนลงดิสก์ ปิดแอปก็หายหมด ถ้าไม่อยากให้เก็บเลยก็ปิดได้ใน Settings (ปิดปุ๊บล้างปั๊บ)
- **สถิติรอบล่าสุด** — บรรทัดเล็ก ๆ แบบ `Last: 1.4s · 38 chars` บอกว่ารอบที่แล้วใช้เวลาเท่าไหร่ ได้ข้อความกี่ตัวอักษร
- **Copy Diagnostics** — คลิกเดียวได้รายงานไว้แปะเวลาแจ้งปัญหา (เวอร์ชันแอป/macOS, engine ที่ใช้, ค่าที่ตั้ง, สิทธิ์, สถานะโมเดล) ไม่มีข้อความที่พูดหรือ API key ติดไปแน่นอน

**General**
- **ปุ่มกดพูด** — ค่าเริ่มต้นคือ Right ⌥ Option แต่จะตั้งเป็นปุ่มไหนก็ได้ เปลี่ยนแล้วใช้ได้เลย ไม่ต้องเปิดแอปใหม่
- **เลือก engine ถอดเสียง** — Typhoon turbo เน้นไทย (ค่าเริ่มต้น), Pathumma (ตัวเก่า), หรือ Whisper large-v3 สำหรับคนพูดอังกฤษเยอะ ตัวไหนยังไม่ได้โหลดก็กดโหลดตรงนั้นได้เลย มี progress bar ให้ดู
- **ปิด pill คลื่นเสียงได้** ถ้ารู้สึกว่าเกะกะจอ
- **เปิดแอปอัตโนมัติตอนล็อกอิน** และ toggle เก็บ/ไม่เก็บ Recent
- **Cloud fallback (ต้องเปิดเอง — ค่าเริ่มต้นปิด)** — อยากใช้ engine cloud ของ Groq ต้องเปิด toggle แล้วใส่ API key ของตัวเองก่อนถึงจะโผล่มาให้เลือก เสียงจะออกจากเครื่องเฉพาะตอนเลือกใช้ engine ตัวนี้เท่านั้น ตัวอื่นรันในเครื่องล้วน ๆ

**Cleanup**
- เปิด/ปิดการแก้คำทั้งระบบ, **ตัดเสียงอืม/เอ่อ/um** (เปิดไว้ให้ตั้งแต่แรก), **สั่งจัดรูปแบบด้วยเสียง** — พูดว่า "ขึ้นบรรทัดใหม่" "ย่อหน้าใหม่" หรือ "bullet point" แล้วได้บรรทัดใหม่จริง ๆ (อันนี้ปิดไว้ก่อน เพราะบางทีเราก็ตั้งใจจะพิมพ์คำว่า "ขึ้นบรรทัดใหม่" จริง ๆ)
- **แอปที่ไม่ต้องแก้คำ (verbatim)** — เลือกแอปที่อยากให้วางตรงตามเสียงเป๊ะ ๆ ไม่ผ่านการแก้เลย เช่น terminal

**Replacements** — ตั้งคำพูดลัดของตัวเอง เช่น พูดว่า "อีเมลของผม" ให้พิมพ์ `me@example.com` ออกมาเลย (ทำงานหลังถอดเสียงเสร็จแล้ว)

**Vocabulary** — ใส่ชื่อคน ศัพท์เฉพาะ ตัวย่อที่ใช้บ่อย ให้ตัวถอดเสียงรู้จักไว้ก่อน จะได้ฟังถูกตั้งแต่แรก — เหมาะกับคำที่ STT ฟังผิดประจำจนตั้ง Replacements ก็ช่วยไม่ทัน

**Models** — เช็คว่าโหลดโมเดลไหนไปแล้ว กินที่เท่าไหร่ เก็บอยู่ตรงไหน กดโหลดใหม่/เช็คซ้ำได้

## รัน benchmark ซ้ำเอง

ตัวทดสอบวิ่งผ่าน**โค้ดจริงตัวเดียวกับที่ปล่อยให้โหลด** ไม่ใช่ของจำลอง:

```bash
# รัน benchmark ของ config ที่ ship บนทุกชุดทดสอบ:
# (repo ของโมเดลใช้ค่าเริ่มต้นที่ ship อยู่แล้ว — ตั้ง OLIV_TYPHOON_MLX_REPO
#  ชี้ไป path ในเครื่องหรือ HF repo อื่น เฉพาะตอนอยากสลับ weights ของ STT)
HF_HUB_DISABLE_XET=1 \
  sidecar/.venv/bin/python benchmark/eval_cleanup.py \
    --manifest data/manifest_all.jsonl --engine typhoon-turbo-mlx --out benchmark/eval_results/ship_main.json
sidecar/.venv/bin/python benchmark/semantic_score.py     # คะแนนความหมาย (LaBSE) จาก eval_results/*.json
sidecar/.venv/bin/python benchmark/build_report_data.py  # + เมตริกผิวข้อความ -> report_data.json
sidecar/.venv/bin/python benchmark/build_landing.py      # regenerate docs/index.html
```

Manifest: `benchmark/data/manifest_{all,holdout,d2}.jsonl` (264 คลิป; ไฟล์เสียงไม่อยู่ใน repo)
เมตริก: `benchmark/semantic_score.py` (LaBSE ตัดคำไทยก่อน embed เกณฑ์ผ่าน 0.80)

## สัญญาอนุญาต

- **โมเดล:** น้ำหนักของ Typhoon-whisper-turbo เป็น MIT สืบจาก [`typhoon-ai/typhoon-whisper-turbo`](https://huggingface.co/typhoon-ai/typhoon-whisper-turbo) ของ SCB 10X และ OpenAI Whisper — OLIV ใช้[ตัวที่แปลงเป็น MLX](https://huggingface.co/chayapats/typhoon-whisper-turbo-mlx) ของ weights ชุดนั้น เครดิตโมเดลทั้งหมดเป็นของผู้สร้างต้นทาง · ส่วนตัวช่วยแก้คำเป็นไปตามสัญญาอนุญาตของต้นทางเอง
- **แอป/โค้ด:** [MIT](LICENSE) — © 2026 Chayapat Sriwattanachote

ชื่อของบริการอื่น (Groq, Whisper ฯลฯ) เป็นของเจ้าของแต่ละราย · การเปรียบเทียบทำบนชุดทดสอบไทย–อังกฤษของเราเอง รันครั้งเดียว
