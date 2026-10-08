# ข้อมูลภาษาไทยจาก pythainlp 5.3.4

คัดลอกจาก `pythainlp/corpus/` ของ pythainlp 5.3.4 (Apache-2.0, ดู `LICENSE-pythainlp`) ไม่ได้แก้ไขอะไร

| ไฟล์ | ใช้แทน | จำนวน | sha256 |
|---|---|---:|---|
| `words_th.txt` | `pythainlp.corpus.thai_words()` — พจนานุกรมของ newmm และเซ็ตคำจริงที่ gate / guardrail / dictionary / thai_format ใช้ | 62,101 | `4bf0ab93…235bda` |
| `stopwords_th.txt` | `pythainlp.corpus.thai_stopwords()` — ใช้ใน `phonetic._has_stopword` | 1,030 | `da7fb61b…abc73` |

วิธีโหลดให้ได้เซ็ตเดียวกับ pythainlp: อ่าน UTF-8 (ตัด BOM ถ้ามี) → แยกบรรทัด → ทิ้งบรรทัดว่าง → เป็นเซ็ต ไม่ต้อง strip และไม่มีคอมเมนต์ ตรวจแล้วว่าทั้งสองไฟล์ไม่มีช่องว่างหัวท้าย ไม่มี `#` และการแยกด้วย `\n` ให้ผลเท่ากับ `str.splitlines()`
