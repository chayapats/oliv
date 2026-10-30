<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/readme/hero-dark.png">
  <img src="docs/img/readme/hero-light.png" alt="OLIV พิมพ์ด้วยเสียงไทยปนอังกฤษบน Mac แอปถอดเสียงทั่วไปเขียนคำอังกฤษเป็นตัวไทย ส่วน OLIV พิมพ์ migrate, database, PostgreSQL เป็นภาษาอังกฤษให้" width="100%">
</picture>

# OLIV: พิมพ์ด้วยเสียงภาษาไทยบน Mac (Speech-to-Text ไทยปนอังกฤษ)

**กดปุ่มค้างไว้ พูดไทยปนอังกฤษ แล้ว OLIV จะพิมพ์ลงแอปที่คุณใช้อยู่ให้**<br>
แปลงเสียงเป็นข้อความแบบออฟไลน์บน Apple Silicon ใช้ฟรีและเป็นโอเพนซอร์ส

[![Latest release](https://img.shields.io/github/v/release/chayapats/oliv?color=57761f&label=release)](https://github.com/chayapats/oliv/releases/latest) [![macOS 14+ on Apple Silicon](https://img.shields.io/badge/macOS%2014%2B-Apple%20Silicon-241f11?logo=apple)](#ติดตั้ง) [![MIT license](https://img.shields.io/github/license/chayapats/oliv?color=57761f)](LICENSE) [![Downloads](https://img.shields.io/github/downloads/chayapats/oliv/total?color=57761f)](https://github.com/chayapats/oliv/releases) [![Greptile: The War on Bugs](https://www.greptile.com/badge.svg)](https://www.greptile.com/?utm_source=oss_badge&utm_medium=readme&utm_campaign=greptile_for_open_source)

<a href="https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg"><img src="https://img.shields.io/badge/%E0%B8%94%E0%B8%B2%E0%B8%A7%E0%B8%99%E0%B9%8C%E0%B9%82%E0%B8%AB%E0%B8%A5%E0%B8%94%E0%B8%AA%E0%B8%B3%E0%B8%AB%E0%B8%A3%E0%B8%B1%E0%B8%9A_macOS-OLIV.dmg_·_27_MB-57761f?style=for-the-badge&logo=apple&logoColor=white" alt="ดาวน์โหลด OLIV สำหรับ macOS (OLIV.dmg ขนาด 27 MB)" height="44"></a>

[**English**](README.md) · [Benchmark](https://chayapats.github.io/oliv/) · [OLIV vs Wispr Flow](https://chayapats.github.io/oliv/oliv-vs-wispr.html) · [Changelog](CHANGELOG.md)

</div>

<br>

<p align="center">
  <img src="docs/img/readme/demo.gif" alt="เดโมโหมดมืด: ใน Terminal ที่เปิด Claude Code ผู้ใช้กด Option ขวาค้างไว้แล้วพูดว่าตัว build fail เพราะ dependency version ไม่ตรง OLIV วางคำสั่งลงช่อง prompt โดยสะกดศัพท์เทคเป็นภาษาอังกฤษ Claude Code แก้ package.json ให้ จากนั้นพูดว่า commit code แล้ว push ขึ้น repo เลย แล้ว Claude Code ก็ commit และ push ให้" width="100%">
</p>

## ปัญหาที่ OLIV แก้

คนไทยสายเทคพูดไทยปนอังกฤษกันตลอด เช่น *"ตัว build fail เพราะ dependency version ไม่ตรง"* แต่แอปถอดเสียงภาษาไทยส่วนใหญ่จะสะกดคำอังกฤษออกมาเป็นตัวไทยตามเสียงที่ได้ยิน ผลที่ได้จึงเป็นแบบนี้

```text
ตัวบิวท์เฟลล์เพราะดิเพนเดนซี่เวอร์ชั่นไม่ตรง
```

แล้วคุณก็ต้องมานั่งแก้ทีละคำ OLIV เปลี่ยนเฉพาะคำพวกนั้นกลับเป็นภาษาอังกฤษ ไม่แตะส่วนที่เป็นภาษาไทย แล้ววางข้อความตรงตำแหน่งเคอร์เซอร์ให้ทันที ค่าเริ่มต้นทั้งการถอดเสียงและการเกลาข้อความทำงานในเครื่อง Mac ของคุณ

## จุดเด่น

- 🇹🇭 **ทำมาเพื่อไทยปนอังกฤษ** ใช้ [Typhoon Whisper Turbo](https://huggingface.co/typhoon-ai/typhoon-whisper-turbo) ซึ่งเป็น Whisper ที่ fine-tune สำหรับภาษาไทย ตามด้วยขั้นตอนเกลาข้อความที่คืนศัพท์เทคให้เป็นภาษาอังกฤษ
- 🔒 **ทำงานในเครื่องเป็นค่าเริ่มต้น** โหลดโมเดลครั้งเดียว จากนั้นใช้ออฟไลน์ได้เลย เสียงของคุณไม่ออกจากเครื่อง เว้นแต่คุณจะเปิดใช้ cloud engine เอง
- ⚡ **ราวหนึ่งวินาที** ค่ามัธยฐาน 1.0 วินาทีนับจากปล่อยปุ่มจนได้ข้อความ (วัดบน M4 Pro)
- ⌨️ **ใช้ได้กับทุกแอป** ไม่ว่าจะเป็น Slack, VS Code, Terminal ที่เปิด Claude Code, Notes หรือเบราว์เซอร์ เคอร์เซอร์อยู่ตรงไหน OLIV ก็วางให้ตรงนั้น
- 📖 **จำคำของคุณได้** ใส่ชื่อคนและศัพท์เฉพาะลง Dictionary แล้ว OLIV จะสะกดตามที่คุณกำหนด แม้โมเดลถอดเสียงจะสะกดชื่อไทยเพี้ยนไปเล็กน้อย
- 🔢 **จัดรูปแบบภาษาไทยให้** `สี่สิบห้า` เป็น `45`, `สองจุดสี่จุดหนึ่ง` เป็น `2.4.1` และ `มากมาก` เป็น `มากๆ`
- 🎧 **ไม่เอาเสียงเพลงมาปน** ระบบตัดเสียงสะท้อนจะหักเสียงที่ Mac กำลังเล่นออก เพลงจึงไม่กลายเป็นข้อความ
- 🆓 **ฟรี สัญญาอนุญาต MIT ไม่ต้องสมัครบัญชี** ไม่มีค่าสมาชิกรายเดือนและไม่มีการเก็บข้อมูลการใช้งาน

## ทำงานอย่างไร

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/readme/pipeline-dark.png">
  <img src="docs/img/readme/pipeline-light.png" alt="ขั้นตอนการทำงาน: กดปุ่มแล้วพูด, Typhoon Whisper Turbo ถอดเสียงด้วย MLX, Rust core แก้คำที่รู้จัก, Gemma E2B คืนคำอังกฤษ แล้ววางข้อความที่เคอร์เซอร์ ทั้งหมดทำงานบน Mac" width="100%">
</picture>

1. **พูด** กดปุ่ม push-to-talk ค้างไว้ (ค่าเริ่มต้นคือ Option ขวา) จะมีแถบคลื่นเสียงเล็กๆ ขึ้นมาบอกว่า OLIV กำลังฟังอยู่
2. **ถอดเสียง** Typhoon Whisper Turbo รันบน GPU ด้วย [MLX](https://github.com/ml-explore/mlx)
3. **แก้คำที่รู้จัก** Rust core ใช้พจนานุกรมในตัว การเทียบคำที่เสียงคล้ายกัน การจัดรูปแบบตัวเลขและ `ๆ` รวมถึง Dictionary ส่วนตัวของคุณ
4. **คืนคำอังกฤษ** โมเดลภาษาขนาดเล็กในเครื่อง ([Gemma E2B](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)) เปลี่ยนศัพท์เทคที่ถูกสะกดเป็นไทยกลับเป็นภาษาอังกฤษ ส่วนที่เหลือคงไว้ตามที่คุณพูด
5. **วาง** ข้อความถูกวางที่เคอร์เซอร์ด้วย ⌘V ถ้าเป็นแอปที่ตั้งเป็นโหมด verbatim เช่น Terminal หรือโปรแกรมจัดการรหัสผ่าน OLIV จะข้ามขั้นตอนเกลาข้อความ

## แม่นแค่ไหน

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/readme/chart-dark.png">
  <img src="docs/img/readme/chart-light.png" alt="กราฟแท่งสัดส่วนประโยคที่ความหมายถูกต้อง จาก 194 คลิปภาษาไทยปนอังกฤษ OLIV: โมเดลฟังเสียงอย่างเดียว 77% เมื่อรวมขั้นเกลาข้อความ 98%; Whisper large-v3 ในเครื่อง 84% เป็น 90%; Whisper large-v3 บน Groq 85% เป็น 91%; Pathumma 60% เป็น 88% ทุก engine วัดด้วยขั้นเกลาข้อความของ OLIV 0.2.2" width="100%">
</picture>

| ชุดทดสอบ | ความหมายถูกต้อง | จำนวนคลิป |
|---|---:|---:|
| **Held-out** (ศัพท์ใหม่ที่ไม่เคยใช้จูนระบบ) | **~95%** | 40 |
| บทพูดทั่วไป (ชุดที่ใช้จูน) | ~98% | 194 |
| ชุดยืนยันผล | ~97% | 30 |

- **ขั้นเกลาข้อความคือตัวสร้างความต่าง** ในชุด held-out ถ้าตัดขั้นนี้ออก ความแม่นจะเหลือ 60%
- **โมเดลฟังเสียงของ OLIV ไม่ใช่ตัวที่เก่งที่สุด** ถ้าเทียบแบบยังไม่เกลาข้อความ Whisper large-v3 ถอดเสียงได้ดีกว่าเล็กน้อย OLIV ชนะเมื่อดูทั้งระบบ โดยยังทำงานในเครื่องและมีขนาดราวครึ่งหนึ่ง ผลทั้งหมดวัดใหม่บนเวอร์ชัน 0.2.2 (28 ต.ค. 2026)
- **ชื่อเฉพาะวัดบน benchmark สาธารณะด้วย** บน [Thai ContextASR Bench](https://huggingface.co/datasets/wayu-ai/thai-contextasr-bench) (2,062 ประโยค จากผู้พูดหลายคน) OLIV 0.2.2 ถอดชื่อและศัพท์ที่อยู่ในรายการได้ถูก 63% เพิ่มจาก 46% ในเวอร์ชันก่อน ดู[วิธีวัดและผลลัพธ์](benchmark/contextasr.md)
- **ตัวเลขเหล่านี้มีข้อจำกัด** "ความหมายถูกต้อง" วัดด้วยความคล้ายเชิงความหมายของ LaBSE ที่ 0.80 ขึ้นไป ไม่ใช่ความถูกต้องทีละคำ และทุกคลิปอัดจากผู้พูดคนเดียว (ตัวผู้พัฒนา) จึงยังไม่ได้ทดสอบกับเสียงคนอื่น สำเนียงอื่น หรือห้องที่มีเสียงรบกวน ชื่อเฉพาะและตัวเลขอาจผิดได้แม้ความหมายจะนับว่าถูก ควรตรวจก่อนกดส่ง

ดูรายละเอียดเต็ม เคสที่พลาด คลิปเสียงจริง และวิธีวัดได้ที่ [หน้า benchmark](https://chayapats.github.io/oliv/)

## มีอะไรใหม่

**0.2.2: Dictionary เข้าใจการสะกดภาษาไทย** ชื่อและศัพท์ภาษาไทยใน Dictionary จะแก้คำที่สะกดเพี้ยนให้ (บางแคร์ → บางแค, พงศ์ → พงษ์) และชื่อที่ใส่เป็นภาษาอังกฤษจะแทนคำที่ถูกถอดเป็นตัวไทย (คลองเตย → Khlong Toei) รายการคำยาวๆ แทนคำผิดน้อยลง ส่วนการพูดตอนที่ Dictionary ว่างยังได้ผลเหมือนเดิมทุกอย่าง

**0.2.1: Dictionary เดียว sync ทุกเครื่อง** รวม Vocabulary กับ Replacements เป็น Dictionary เดียว ติดดาว เปิด/ปิดทีละคำ ค้นหา และนำเข้า/ส่งออก CSV ได้ ถ้าใช้ OLIV API จะ sync ข้ามเครื่อง และ OLIV แนะนำคำที่คุณแก้บ่อยให้ได้ โดยไม่เพิ่มคำใดจนกว่าคุณจะกดอนุมัติ

**0.2.0: Rust และ MLX แบบ native**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/readme/native-dark.png">
  <img src="docs/img/readme/native-light.png" alt="OLIV 0.2.0: ไฟล์ดาวน์โหลดจาก 123 MB เหลือ 26 MB, แอปที่ติดตั้งจาก 356 MiB เหลือ 85 MiB, เวลาเริ่ม worker จาก 44.8 ms เหลือ 3.5 ms, ค่ามัธยฐานจากเสียงเป็นข้อความจาก 1.12 วินาที เหลือ 0.87 วินาที" width="100%">
</picture>

OLIV 0.2.0 เอา Python ออกจากแอปทั้งหมด การประมวลผลข้อความและการเรียก API ใช้ Rust core ร่วมกัน ส่วน Whisper และ Gemma รันด้วย MLX แบบ native ใน Swift ความแม่นอยู่ในระดับเดียวกับ 0.1.x (WER เฉลี่ย 12.34% เทียบกับ 12.58% บนชุดทดสอบหลัก) และยังมาพร้อมหน้า Settings ใหม่ การเริ่ม push-to-talk ที่เร็วขึ้น และ OLIV API engine ที่เลือกเปิดใช้ได้ อ่านรายละเอียดทุกเวอร์ชันได้ใน [changelog](CHANGELOG.md) และ[บันทึกการย้ายระบบ](docs/native-runtime-migration.md)

## ฟีเจอร์

<p align="center">
  <img src="docs/img/readme/settings.png" alt="หน้าต่าง Settings ใหม่ของ OLIV ทั้งโหมดสว่างและโหมดมืด แสดงหน้า Dictation engine และ Text cleanup" width="100%">
</p>

| ฟีเจอร์ | ทำอะไรได้ |
|---|---|
| **Push-to-talk** | ตั้งปุ่มหลักและปุ่มสำรองได้ เลือกจากค่าที่เตรียมไว้หรือกดปุ่มที่ต้องการเอง และตั้งปุ่มแยกสำหรับยกเลิกการวางครั้งล่าสุดได้ |
| **โมเดลถอดเสียง** | Typhoon Whisper Turbo (ค่าเริ่มต้น ไทยและอังกฤษ), Pathumma หรือ Whisper large-v3 สำหรับคนที่พูดอังกฤษเป็นหลัก ดาวน์โหลดได้จาก Settings พร้อมแถบแสดงความคืบหน้า |
| **เกลาข้อความ** | คืนคำอังกฤษ ตัดคำเติมอย่าง อืม เอ่อ um จัดรูปแบบตัวเลขและ `ๆ` และรองรับคำสั่งเสียงอย่าง "ขึ้นบรรทัดใหม่" หรือ "ย่อหน้าใหม่" (ปิดไว้เป็นค่าเริ่มต้น) |
| **Dictionary** | ชื่อคน ตัวย่อ และศัพท์เฉพาะที่ช่วยให้ฟังถูกตั้งแต่แรก และตั้งคำแก้ให้คำพูดกลายเป็นข้อความที่กำหนดได้ เช่น "อีเมลของผม" → `me@example.com` คำภาษาไทยยังช่วยแก้คำที่สะกดเพี้ยนได้ด้วย (บางแคร์ → บางแค) ติดดาวคำสำคัญ นำเข้า/ส่งออก CSV และถ้าใช้ OLIV API จะ sync ไปทุกเครื่อง |
| **แอปแบบ verbatim** | เลือกแอปที่ต้องการให้วางข้อความดิบโดยไม่เกลา |
| **เสียง** | เลือกไมโครโฟนได้ ตัดเสียงสะท้อนจากลำโพง และลดเสียงแอปอื่นตอนพูด หูฟัง Bluetooth ยังเล่นเสียงคุณภาพเต็มได้ตามปกติ |
| **ประวัติล่าสุด** | ผลลัพธ์ 10 รายการล่าสุดในเมนู เก็บไว้ในหน่วยความจำเท่านั้น คลิกเพื่อคัดลอกอีกครั้งได้ |
| **Cloud engine (ไม่บังคับ)** | Groq หรือ OLIV API ที่โฮสต์เอง ปิดไว้เป็นค่าเริ่มต้น เสียงจะออกจากเครื่องเฉพาะตอนที่คุณเลือกใช้ engine นั้น key เก็บใน macOS Keychain |
| **อัปเดตอัตโนมัติ** | ทุก build เซ็นและผ่าน notarization ของ Apple อัปเดตผ่าน Sparkle |

## ติดตั้ง

1. **[ดาวน์โหลด OLIV.dmg](https://github.com/chayapats/oliv/releases/latest/download/OLIV.dmg)** (27 MB เซ็นและผ่าน notarization ของ Apple แล้ว)
2. เปิดไฟล์แล้วลาก **OLIV** ไปไว้ใน **Applications**
3. เปิด OLIV แล้วอนุญาตสิทธิ์ **Microphone** และ **Accessibility** (Accessibility ใช้สำหรับวางข้อความลงแอปอื่น)
4. ครั้งแรกที่เปิด OLIV จะดาวน์โหลดโมเดลจาก Hugging Face ประมาณ **5 GB** ครั้งเดียว
   - ถอดเสียง: [`chayapats/typhoon-whisper-turbo-mlx`](https://huggingface.co/chayapats/typhoon-whisper-turbo-mlx) ประมาณ 1.5 GB (Typhoon ของ SCB 10X ที่แปลงเป็น MLX)
   - เกลาข้อความ: [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit) ประมาณ 3.3 GB
5. กด **Option ขวา** ค้างไว้ พูด แล้วปล่อย

**สเปกที่ต้องมี:** Mac ชิป Apple Silicon (M1 ขึ้นไป) และ macOS 14 Sonoma ขึ้นไป ถ้าใช้ OLIV API engine ต้องมีอินเทอร์เน็ตและ API key แต่ไม่ต้องโหลดโมเดลลงเครื่อง

## Linux, Windows และ server ของคุณเอง

<a href="server/README.md"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/readme/server-hero-dark.png">
  <img src="docs/img/readme/server-hero-light.png" alt="OLIV Server: เครื่อง GPU เครื่องเดียว ทุกอุปกรณ์พูดแล้วพิมพ์ได้ client บน Mac, Linux และ Windows ต่อผ่าน HTTPS ไปยังเครื่อง GPU ที่รัน oliv-api, ถอดเสียง, เกลาข้อความด้วย Gemma และ dashboard" width="100%">
</picture></a>

แอป Mac ประมวลผลทุกอย่างในเครื่อง ถ้าอยากใช้บนคอมเครื่องอื่นด้วย ให้รัน pipeline เดียวกันไว้บนเครื่อง GPU ของคุณเองครั้งเดียว

- **[OLIV Server](server/README.md)** รันการถอดเสียงและเกลาข้อความบน Linux ที่มีการ์ด NVIDIA ผ่าน HTTPS API เดียว แยก key ให้แต่ละอุปกรณ์ และใช้ text core ที่เขียนด้วย Rust ตัวเดียวกับแอป Mac
- **[OLIV desktop](desktop/README.md)** คือ client ขนาดเล็กที่เขียนด้วย Rust สำหรับ Linux (Hyprland/Wayland) และ Windows 10/11 กด Shift ขวาค้างไว้ พูด แล้วปล่อย ข้อความจะถูกวางลงในแอปที่เปิดอยู่
- **แอป Mac** ก็ใช้ server ของคุณได้ ที่ Settings ▸ Cloud services ▸ OLIV API

## ความเป็นส่วนตัว

- เมื่อใช้ engine ในเครื่องซึ่งเป็นค่าเริ่มต้น เสียงจะถูกประมวลผลบน Mac และไม่ถูกอัปโหลด
- Cloud engine ปิดอยู่จนกว่าคุณจะเปิดใช้ ใส่ key และเลือก engine นั้นเอง
- ประวัติการพูดล่าสุดเก็บในหน่วยความจำเท่านั้น และถูกล้างเมื่อปิดแอป
- **Copy Diagnostics** สร้างรายงานสำหรับแจ้งปัญหาเป็นข้อความธรรมดา โดยไม่มีข้อความที่คุณพูดหรือ API key
- OLIV ไม่มี analytics และไม่เก็บข้อมูลการใช้งาน การเชื่อมต่อเครือข่ายมีเฉพาะตอนดาวน์โหลดโมเดล ตรวจหาอัปเดต และใช้ cloud engine ที่คุณเลือก

## คำถามที่พบบ่อย

<details>
<summary><b>OLIV ใช้แทน Wispr Flow หรือ Superwhisper สำหรับภาษาไทยได้ไหม</b></summary>

ได้ OLIV ใช้ฟรี เป็นโอเพนซอร์ส และเน้นภาษาไทยปนอังกฤษโดยเฉพาะ บนชุดทดสอบไทยปนอังกฤษ 264 คลิปของเรา OLIV ได้ความหมายถูกต้องโดยรวมสูงกว่า [Wispr Flow](https://chayapats.github.io/oliv/oliv-vs-wispr.html) (97% เทียบกับ 93%) และได้ข้อความเร็วกว่าเล็กน้อยหลังปล่อยปุ่ม (ค่ามัธยฐาน 1.0 วินาที เทียบกับ 1.4 วินาที) ส่วนประโยคที่มีศัพท์เทคหนาแน่น Wispr ดีกว่า (100% เทียบกับ 98%) ผลนี้มาจากผู้พูดคนเดียว ทดสอบครั้งเดียวเมื่อ 28 ต.ค. 2026
</details>

<details>
<summary><b>ใช้แบบออฟไลน์ได้ไหม</b></summary>

ได้ หลังดาวน์โหลดโมเดลครั้งแรกแล้ว engine ที่เป็นค่าเริ่มต้นไม่ต้องใช้อินเทอร์เน็ต
</details>

<details>
<summary><b>ใช้กับ Mac ชิป Intel, Windows หรือ Linux ได้ไหม</b></summary>

แอป Mac ต้องใช้ Apple Silicon เพราะรันโมเดลด้วย MLX ของ Apple ส่วนบน Windows 10/11 และ Linux (Hyprland) ใช้ [OLIV desktop client](desktop/README.md) คู่กับ [OLIV server](server/README.md) ที่คุณรันเองบนเครื่อง GPU หรือใช้ key ที่ผู้ดูแล server ให้มา
</details>

<details>
<summary><b>พูดภาษาอังกฤษล้วน หรือภาษาไทยล้วนได้ไหม</b></summary>

ได้ Typhoon Whisper Turbo รองรับทั้งภาษาไทย ภาษาอังกฤษ และการพูดปนกัน ถ้าพูดอังกฤษเป็นหลัก เปลี่ยนไปใช้ Whisper large-v3 ใน Settings ได้
</details>

<details>
<summary><b>ทำไมต้องให้สิทธิ์ Accessibility</b></summary>

เพื่อวางข้อความลงในแอปที่คุณใช้อยู่ OLIV ไม่อ่านหน้าจอของคุณ
</details>

## Build จากซอร์สโค้ด

ต้องใช้ Mac ชิป Apple Silicon ที่มี macOS 14 ขึ้นไป, Xcode, [Rust](https://rustup.rs) และ XcodeGen ไม่ต้องใช้ Python

```bash
brew install xcodegen ripgrep
xcodebuild -downloadComponent MetalToolchain
bash scripts/build_app.sh   # → build/OLIV.app
bash scripts/test.sh        # เทสต์ Rust, native runtime และ Swift
```

โครงสร้างโปรเจกต์:

| Path | คืออะไร |
|---|---|
| `macos/` | แอป Mac: UI ด้วย Swift และ inference ในเครื่องด้วย MLX |
| `rust/` | crate ที่ใช้ร่วมกัน รวมถึง `oliv-text-core` ซึ่งเป็น pipeline ข้อความที่ทุก client และ server ใช้ |
| `server/` | OLIV server สำหรับ self-host: รัน STT และ cleanup บนเครื่อง GPU ของคุณเอง แล้วให้ client ส่ง request มา ([server/README.md](server/README.md)) |
| `desktop/` | client สำหรับ Linux (Hyprland/Wayland) และ Windows ที่ต่อกับ OLIV server ([desktop/README.md](desktop/README.md)) |
| `benchmark/` | เครื่องมือวัดผลแบบ native |

อ่านวิธีรัน benchmark กับเสียงของคุณเองได้ที่ [CONTRIBUTING.md](CONTRIBUTING.md) และ [benchmark/README.md](benchmark/README.md)

## ร่วมพัฒนา

ยินดีรับ issue และ pull request ทั้งภาษาไทยและภาษาอังกฤษ กรุณาอ่าน [CONTRIBUTING.md](CONTRIBUTING.md) และ [Code of Conduct](CODE_OF_CONDUCT.md) ก่อน ถ้าพบปัญหาด้านความปลอดภัย กรุณาแจ้งแบบส่วนตัวตามขั้นตอนใน [SECURITY.md](SECURITY.md)

ถ้า OLIV ช่วยประหยัดเวลาคุณได้ กด ⭐ ให้หน่อยจะช่วยให้คนไทยคนอื่นเจอโปรเจกต์นี้ง่ายขึ้น

## เครดิตและสัญญาอนุญาต

- **โค้ด:** [MIT](LICENSE) © 2026 Chayapat Sriwattanachote
- **โมเดลถอดเสียง:** Typhoon Whisper Turbo โดย [SCB 10X](https://huggingface.co/typhoon-ai/typhoon-whisper-turbo) (MIT) พัฒนาต่อจาก OpenAI Whisper OLIV ใช้[เวอร์ชันที่แปลงเป็น MLX](https://huggingface.co/chayapats/typhoon-whisper-turbo-mlx) เครดิตของโมเดลเป็นของผู้พัฒนาต้นฉบับ
- **โมเดลเกลาข้อความ:** Gemma ภายใต้สัญญาอนุญาตของต้นทาง
- **ไลบรารี:** [MLX Swift](https://github.com/ml-explore/mlx-swift), [Sparkle](https://sparkle-project.org) และ Rust crate ตามรายการใน `rust/Cargo.lock` สัญญาอนุญาตของทั้งหมดรวมอยู่ในแอป

ชื่อบริการของบุคคลที่สาม เช่น Groq, Whisper และ Wispr Flow เป็นของเจ้าของแต่ละราย ผลเปรียบเทียบใช้ชุดทดสอบไทยปนอังกฤษของเราเองและทดสอบครั้งเดียว
