# Personal dictionary

> In Thai. Summary: the server keeps one personal dictionary per *profile*, applies it to every `/v1/dictate` and `/v1/clean`, and clients sync it with `GET/POST /v1/dictionary`. Matching logic lives in `oliv-text-core` (`user_dictionary`), shared with the Mac's local engine.

Dictionary ส่วนตัว (เทียบเท่า Dictionary ของ Wispr Flow) เก็บบน server ต่อ *profile* แล้ว sync ไปทุกเครื่อง ทุกคำขอ `/v1/dictate` และ `/v1/clean` ใช้ dictionary ของผู้เรียกให้เองโดยไม่ต้องส่งมาใน request

logic ที่ใช้จับคู่และแก้ข้อความอยู่ใน crate `oliv-text-core` ([`rust/crates/oliv-text-core`](../../rust/crates/oliv-text-core), module `user_dictionary`) ซึ่ง Mac ใช้กับ local engine ด้วย ผลบน server กับบนเครื่องจึงเหมือนกัน

## Entry

| field | ความหมาย |
|---|---|
| `id` | client เป็นคนสร้าง (เช่น UUID) ยาว 1–64 ตัว ใช้ได้เฉพาะ `A-Z a-z 0-9 - _` |
| `word` | คำที่ต้องการให้พิมพ์ออกมา ตรงตัวอักษรเป๊ะ ยาว 1–100 ตัว ต้องมีตัวอักษรหรือตัวเลขอย่างน้อยหนึ่งตัว |
| `correction` | สิ่งที่พูดหรือที่ STT ได้ยิน ซึ่งต้องแปลงเป็น `word` ถ้าเป็น `null` จะเป็นคำศัพท์อย่างเดียว ใช้ bias STT กับ fuzzy match |
| `enabled` | ค่าเริ่มต้น `true` |
| `starred` | ค่าเริ่มต้น `false` คำที่ star จะขึ้นก่อนใน context ของ STT ซึ่งตัดที่ 960 ตัวอักษร |
| `source` | `manual` (ค่าเริ่มต้น), `import` หรือ `autoLearn` |
| `updated_at` | เวลาที่ server เขียนล่าสุด (ms) client ส่งมาไม่ได้ |

ถ้า entry สองอันมี `word` กับ `correction` เดียวกันจะถือว่าซ้ำ (Latin ไม่สนตัวพิมพ์เล็ก/ใหญ่ ไทยต้องตรงตัว) ส่วน `SHA256` แบบคำศัพท์อย่างเดียวกับ `SHA256 ← ชาสองห้าหก` เป็นคนละ entry กัน แต่ละ profile มีได้สูงสุด 1000 entry

## ผลต่อ pipeline

1. dictionary ในตัว แล้วตามด้วย **correction ของผู้ใช้**: เลือกคำที่ยาวที่สุดก่อน ไม่ทับกัน ไม่ตัดกลางคำไทยจริง ฝั่ง Latin ไม่สนตัวพิมพ์และต้องตรงขอบคำ (`teh` ไม่ไปแก้ใน `tehran`)
2. **คำที่มีตัวเลขพูดเป็นภาษาไทย**: `SHA สองห้าหก`, `SHA สองร้อยห้าสิบหก` หรือ `SHA256 สองห้าหก` จะกลายเป็น `SHA256` แต่ต้องได้ค่าเท่ากับตัวเลขในคำเท่านั้น
3. fuzzy vocabulary โดยใช้คำใน dictionary (star ก่อน) แล้วตามด้วย `vocabulary` จาก request ตัวเลขต้องตรงกัน (`SHA` จะไม่ถูกแก้เป็น `SHA256`)
4. gate และ LLM แล้วตามด้วย guardrail
5. **guard ของ dictionary**: ถ้าคำใน dictionary อยู่ในข้อความที่ส่งให้ LLM แต่หายไปจากคำตอบ (เช่น LLM เขียน `สมชาย` เป็น `Somchai`) จะใช้ข้อความก่อนเข้า LLM แทน และตั้ง `guardrail_flag = "dictionary->dict"`
6. correction ที่รวมกับ `replacements` ของ request (เลือกคำที่ยาวกว่าก่อน ถ้ายาวเท่ากัน dictionary ชนะ) แล้วแปลงตัวเลขไทยซ้ำอีกรอบ ขั้นนี้ทำงานแม้ `cleanup:false` เหมือน `replacements` เดิม
7. thai_format

Qwen3-ASR ได้คำใน dictionary เป็น context ของการถอดเสียง โดยคำที่ star ขึ้นก่อน

## API

ทุก route ต้องใช้ `Authorization: Bearer <key>` ที่มี scope `dictate` (key ที่ dictate ได้ก็จัดการ dictionary ของตัวเองได้) การ sync ไม่กินคิว inference และไม่นับ quota ต่อนาที/วันของ key

### `GET /v1/dictionary`

```json
{"ok": true, "revision": 7, "max_entries": 1000, "rejected": [],
 "entries": [{"id": "6F1C…", "word": "SHA256", "correction": null, "enabled": true,
              "starred": true, "source": "manual", "updated_at": 1761300000000}]}
```

`entries` เรียงตามลำดับที่ผู้ใช้เพิ่ม (แก้ไขแล้วลำดับไม่เปลี่ยน) ส่วน `revision` เพิ่มทุกครั้งที่มีการเปลี่ยนแปลง

### `POST /v1/dictionary`

`Content-Type: application/json` ขนาดไม่เกิน 512 KiB และไม่เกิน 1000 op

```json
{"ops": [
  {"op": "upsert", "entry": {"id": "6F1C…", "word": "SHA256", "starred": true}},
  {"op": "upsert", "entry": {"id": "A01B…", "word": "Koolify", "correction": "คูลิฟาย"}},
  {"op": "delete", "id": "9C2D…"}
]}
```

- ทำทั้งชุดใน transaction เดียว ตามลำดับ ถ้า id ซ้ำ entry ล่าสุดชนะ (last writer wins) `upsert` ที่ส่งซ้ำและ `delete` id ที่ไม่มีอยู่จะไม่เปลี่ยนอะไร จึง retry ได้ปลอดภัย
- ถ้า op ใดรูปแบบผิด จะตอบ `400` พร้อม `ops[i]: …` และไม่ทำอะไรเลยทั้งชุด
- op ที่รูปแบบถูกแต่ทำไม่ได้จะอยู่ใน `rejected: [{"index", "id", "reason"}]` โดย reason เป็น `duplicate` (word+correction ซ้ำกับ entry อื่น) หรือ `limit` (เต็ม 1000 แล้ว) ส่วน op อื่นในชุดยังทำต่อตามปกติ
- ตอบกลับเป็น snapshot ทั้งก้อน รูปแบบเดียวกับ `GET`

### ใน reply ของ dictate/clean

`"dictionary_revision": 7` คือ revision ที่ใช้กับคำขอนั้น เมื่อไม่ตรงกับ cache ของ client ให้ `GET` ใหม่ ถ้าเป็น `null` แปลว่า store ใช้ไม่ได้ชั่วคราวและคำขอนั้นทำงานโดยไม่มี dictionary (dictation จะไม่ล้มเพราะเรื่องนี้)

## วิธีที่ client ควร sync (Mac, iPhone, Linux, Windows)

1. เก็บ cache ไว้ในเครื่อง ได้แก่ `revision`, `entries` และคิว op ที่ยังไม่ได้ส่ง (persist ไว้ด้วย)
2. เมื่อผู้ใช้แก้ไข ให้แก้ cache ทันทีแล้วต่อ op เข้าคิว จากนั้นพยายาม `POST` ถ้าสำเร็จให้แทน cache ด้วย snapshot ที่ได้กลับมา เอา op ที่ส่งแล้วออกจากคิว และแจ้งผู้ใช้ถ้ามี `rejected`
3. ตอนเปิดแอป กลับมา foreground หรือเมื่อ `dictionary_revision` ไม่ตรง ให้ส่งคิวที่ค้างก่อน (ถ้ามี) แล้วค่อย `GET`
4. ตอน offline หรือใช้ local engine (Mac) ให้ใช้ cache ของตัวเอง
5. ครั้งแรกที่ sync ให้ upsert entry เดิมทั้งหมดในเครื่องขึ้นไป รวมถึง vocabulary/replacements รุ่นเก่า entry ที่ซ้ำจะกลับมาเป็น `duplicate` ซึ่งไม่เป็นปัญหา หลังจากนั้นเลิกส่ง `vocabulary`/`replacements` ใน request ได้เลย เพราะ server ใช้ dictionary แทน (server ยังรองรับสอง field นี้สำหรับ client รุ่นเก่า)
6. ถ้า `/v1/dictionary` ตอบ `404` แปลว่า server เป็นรุ่นเก่า ให้ทำงานแบบเดิม คือส่ง vocabulary/replacements ที่ derive จาก cache ไปกับ request

## Profile: ใช้ dictionary เดียวกันหลายเครื่อง

key ออกแยกตามเครื่อง ส่วน profile คือ dictionary ของแต่ละคน key ที่ยังไม่ link จะเป็น profile ของตัวเอง ถ้าต้องการให้ iPhone ใช้ dictionary เดียวกับ Mac:

```sh
~/oliv/bin/oliv-keys --root ~/oliv list                              # ดู key ID
~/oliv/bin/oliv-keys --root ~/oliv profile link <iphone-key-id> <mac-key-id>
~/oliv/bin/oliv-keys --root ~/oliv profile list
~/oliv/bin/oliv-keys --root ~/oliv profile unlink <iphone-key-id>   # กลับไปใช้ profile ของตัวเอง
```

`PROFILE` เป็นชื่ออะไรก็ได้ (ASCII ยาว 1–64 ตัว) การ link ไปที่ ID ของอีก key หมายถึงใช้ dictionary ของ key นั้น entry ของ profile เดิมยังอยู่ครบ ไม่ถูกลบ

## Storage

ข้อมูลอยู่ใน `ROOT/dictionary/dictionary.sqlite3` (directory mode 0700, ไฟล์ mode 0600, WAL) ตอนนี้ schema เป็น version 1 (`PRAGMA user_version`) และ migration อยู่ใน `oliv-api/src/dictionary_store.rs` การ link profile เก็บไว้ที่นี่ ไม่ได้เก็บใน key store ดังนั้น `api-keys.json` ไม่เปลี่ยน และยัง rollback ไปใช้ binary รุ่นเก่าได้ (binary เก่าจะไม่สนไฟล์นี้)

backup: ใช้ `sqlite3 dictionary.sqlite3 ".backup dictionary-YYYYMMDD.sqlite3"` ในขณะที่ server รันอยู่ได้เลย
