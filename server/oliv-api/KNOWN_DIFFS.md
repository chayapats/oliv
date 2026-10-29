# จุดที่ Rust ตั้งใจให้ต่างจาก Oliv (Python)

golden ทุกไฟล์ใน `tests/golden/` (fixture สาธารณะ ดู `tests/golden/README.md`) ผ่าน 100% ไม่มีเคสไหนถูกลบหรือข้าม รายการข้างล่างเป็นพฤติกรรมที่ Rust ตั้งใจทำต่างจาก Python ส่วนใหญ่ golden ไม่ได้ครอบ เคส golden ที่ต่าง (§7, §11, §12, §13) อยู่ใน `tests/known_diffs/<ไฟล์ golden>` แต่ละบรรทัดมี `args`, `kwargs`, ค่าที่ golden คาดไว้ (`oliv`), ค่าของ Rust (`out`) และหัวข้อ (`why`) test แทนค่าที่คาดไว้ด้วย `out` และตรวจว่าแต่ละรายการตรงกับเคสเดียวพอดี และ `oliv` ยังตรงกับ golden

## 1. LLM ล้มเหลวหรือ timeout

| | Python (sidecar) | Rust (`pipeline::clean_ex`) |
|---|---|---|
| ข้อความ `final` | ข้อความก่อน cleanup ซึ่งผ่านแค่ fillers ทำให้ผลจาก dictionary และ vocab หายไปด้วย | ข้อความที่ผ่านขั้น deterministic ครบ: dictionary → vocab → Thai spacing → casing (เหมือนตอน guardrail ตีกลับ) |
| `guardrail_flag` | `""` | `"llmError->dict"` |
| `gate_reason`, `dict_hits`, `vocab_fired` | ว่าง / 0 | ค่าจริงจาก gate |
| `llm_ran` | `false` | `true` (มีการเรียกแล้วแต่ล้มเหลว) |
| `cleanup_error` | `"<ชนิด>: <ข้อความ>"` | ข้อความ error จาก `Llm::generate` |

**เหตุผล:** เป็นไปตามสัญญา HTTP เดิมของ server (ดู `docs/PUBLIC-API.md`) ที่กำหนดว่าถ้า Gemma timeout (>5 s) หรือ error ให้ใช้ข้อความที่ผ่านแค่ขั้น deterministic และการแก้ของ dictionary ไม่ควรหายเพราะ LLM ล่ม ใน golden ไม่มีเคสที่ LLM error เลย เคสนี้จึงครอบด้วย `tests/llm_fallback.rs` แทน

## 2. ชนิดข้อมูลในคำขอ

Python ไม่ตรวจชนิด ถ้า replacements มีค่าที่ไม่ใช่ string จะโยน `TypeError` ภายใน `apply_dictionary` แล้วข้ามการแทนที่ทั้งตาราง ส่วน `oliv-api` ตรวจทุก option ตอน parse (`Options::from_json`) ถ้าชนิดผิดจะตอบ 400 ทันที

## 3. STT คืนข้อความว่าง

ใน sidecar ถ้า STT คืน `""` จะได้ `final: ""` และ `no_speech: false` เพราะ gate ทำงานเฉพาะเมื่อ raw ไม่ว่าง ส่วน `/v1/dictate` ของ `oliv-api` ตอบ `no_speech: true, gate_reason: "no_speech"` ตามสัญญา HTTP ("ถ้าไม่เหลืออะไร") เพราะ VAD ของ `whisper_server.py` ตัดเสียงเงียบทิ้งหมดได้ โดย `/v1/clean` และ golden ไม่ได้รับผลกระทบ

## 4. forced-English re-decode ล้มเหลว

`stt::transcribe_maybe_redecode` ทำตาม `_transcribe_maybe_redecode` ของ sidecar คือถ้า `avg_logprob` เฉลี่ยของ decode แบบ auto ต่ำกว่า −0.30 จะ decode ใหม่โดยบังคับเป็นอังกฤษ แล้วใช้ผลนั้นเมื่อ `avg_logprob` ดีกว่าเดิมเกิน 0.02 จุดที่ต่างคือถ้า decode รอบที่สองล้มเหลว sidecar จะโยน error ออกไปทั้งคำขอ ส่วน `oliv-api` ใช้ข้อความจากรอบแรก เพราะข้อความต้องไม่หาย

vocabulary ไม่ถูกส่งเป็น initial prompt ของ STT (`stt::SEED_PROMPT = false`) ซึ่งตรงกับ `TyphoonTurboMLXBackend.seed_prompt = False` ของ Oliv รุ่นก่อนเคยส่งไป ทำให้ typhoon ถอดความวนซ้ำ (เมื่อส่ง prompt ผลบน eval แย่ลงอย่างเห็นได้ชัด) ส่วน header `X-Initial-Prompt` ของ `whisper_server.py` ยังใช้ได้

พฤติกรรมข้างบนใช้กับ `asr_profile = "turbo"` (ค่าเริ่มต้น) และ `"typhoon-ctx"` ส่วน Qwen3-ASR ไม่มีใน Oliv เมื่อเป็น `"qwen3asr"` (ตั้งใน `[api]` หรือส่งมาในคำขอ) `/v1/dictate` จะ decode แบบ auto ครั้งเดียว ส่ง vocabulary เป็น initial prompt และไม่ re-decode เป็นอังกฤษ เพราะบน eval การบังคับไทยและการ re-decode ได้ผลแย่กว่าอย่างเห็นได้ชัด

## 5. ตาราง Unicode

golden สร้างบน Python 3.12 ซึ่งใช้ Unicode 15.0 ส่วน crate ของ Rust (`unicode-general-category`, `regex`, `caseless`, `unicode-normalization`) อาจใช้ Unicode เวอร์ชันใหม่กว่า ผลจึงอาจต่างกันได้เฉพาะอักขระที่เพิ่งถูกกำหนดหลัง Unicode 15.0 ในจุดที่ใช้ category, `\w`, `\d` และ casefold ได้แก่ `metrics.normalize`, hallucination gate และตัวตัดคำ ทั้งนี้ไม่มีเคสใน golden หรือ differential fuzz ที่ได้รับผลกระทบ

## 6. `thai_format`: เลขที่ติดคำ, คำหลักเลขลอย ๆ และ `<ลักษณนาม><ลักษณนาม>ละ`

`thai_format.py` ของ Oliv มีบั๊กสามจุด Rust แก้ทั้งสามจุด

- **เลขติดคำข้างหน้า:** newmm ตัด `ที่สี่` หรือ `ที่หนึ่ง` เป็น token เดียว แล้ว `thaiword_to_num` อ่าน `หมื่น` ที่ขึ้นต้นเป็น 1 ผลคือ `อยู่ที่สี่หมื่นห้าพันบาท` กลายเป็น `อยู่ที่สี่15000บาท` (ค่าผิด) Rust (`split_glued_digit`) แยกเลขหลักเดียวท้าย token ออก เมื่อส่วนหน้าเป็นคำในพจนานุกรม และเลขนั้นรวมกับเลขที่ตามมาแล้ว `words_to_num` แปลงได้ จึงได้ `อยู่ที่45000บาท` ส่วน `ตีห้า` + `สี่สิบ` แปลงรวมไม่ได้จึงไม่แยก
- **คำหลักเลขลอย ๆ:** `ร้อย` `พัน` `หมื่น` `แสน` `ล้าน` ที่อยู่ตัวเดียวแปลงเป็นตัวเลขเหมือน Python ทุกตำแหน่ง (`แสนบาท` เป็น `100000บาท`, `ขายได้ร้อยครับ` เป็น `ขายได้100ครับ`, `ได้หมื่นวิว`, `ค่าห้องพัน`, `กดเองทีล้าน` เป็น `ที1000000`) ยกเว้นเมื่อคำถัดไป (ข้ามช่องว่าง) อยู่ในรายการสั้น ๆ `POWER_WORD_COLLOCATES` ที่ทำให้เป็นคำกริยาหรือคำวิเศษณ์: `แสน` + คำคุณศัพท์ (`แสนสวย`, `แสนดี`, `แสนแพง`, `แสนจะ` ...), `ร้อย` + `ละ`/`เรียง`/`มาลัย`/`แก้ว`/`กรอง`/`รัด` และ `พัน` + `แผล`/`ผ้า`/`กัน` ซึ่ง Python ได้ `100000สวย`, `100ละห้า`, `1000แผล`
- **`งวด งวดละ`:** `normalize_thai_spacing` ลบช่องว่างจนได้ `งวดงวดละ` แล้ว Python ยุบเป็น `งวดๆละ` Rust ไม่ยุบคู่คำซ้ำที่ตามด้วย `ละ`

golden ไม่มีเคสที่ต่าง เพราะ fixture สาธารณะไม่มี input แบบนี้ unit test ใน `src/thai_format.rs` ครอบทั้งสามจุด ผลจาก eval: คลิปที่เคยได้ `สี่15000` ถูกแก้ ส่วนคลิปที่ ASR ถอดผิดจนคำกลายเป็นคำหลักเลข (คำอังกฤษที่ฟังคล้าย `ร้อย` หรือ `ทีละ` ที่ถอดเป็น `ทีล้าน`) ได้ผลเหมือน Python เพราะกฎทั่วไปแก้ ASR ผิดแบบนี้ไม่ได้

## 7. `remove_fillers`: เครื่องหมายหลัง filler และ filler ไทยที่ติดคำ

`remove_fillers` ของ Oliv ใช้ regex ที่ต้องมีขอบคำ (`_GLUE`) ทั้งสองข้าง Rust ต่างจาก Python สามจุด

- **เครื่องหมายหลัง filler:** Python ลบแค่ตัว filler ทำให้ `Hmm, the latency ... Um, we should` เหลือ `, the latency ... , we should` Rust ลบ `,` `.` `…` `!` `?` `-` ที่ตามมาติดกันไปด้วย และถ้าลบเครื่องหมายไปแล้วจะลบช่องว่างที่ตามมาอีกหนึ่งตัว ยกเว้น filler ที่จบประโยค (ตามด้วย `.` `!` หรือ `?` ตัวเดียว แล้วจบข้อความหรือตามด้วยตัวพิมพ์ใหญ่) ซึ่งเก็บเครื่องหมายนั้นไว้และลบ `,` ข้างหน้าแทน (`We should do it, um.` เป็น `We should do it.`) ส่วน filler ที่ไม่มีเครื่องหมายตามมาได้ผลเหมือน Python
- **filler ที่ต่อด้วย `-`:** filler ที่มี `-` เชื่อมกับคำ (`uh-huh`, `mm-hmm`) เป็นคำตอบ ไม่ใช่ filler จึงไม่ถูกลบ (Python ได้ `-huh`)
- **filler ที่ลากเสียง:** ตัวสุดท้ายของ filler ซ้ำกี่ตัวก็ได้ (`เอ่ออ`, `อืมมมม`, `hmmm`, `Ummm`) ยกเว้น `er` เพราะ `err` เป็นคำ Python รู้จักแค่ `อืมม` `อ่าา` `uhh`
- **filler ไทยที่ติดคำ:** ภาษาไทยไม่เว้นวรรค และตัวอักษรไทยนับเป็น glue ทำให้ `เอ่อเดี๋ยว` `อืมกินข้าวก่อน` และ `ตัวนี้เอ่อ` ไม่ถูกลบ หลังผ่าน regex แล้ว Rust ตัดคำด้วย newmm (`keep_whitespace`) และลบ token ที่ตรงกับ filler ไทยทั้งคำ พร้อม token ที่ตามมาซึ่งเป็นตัวท้ายที่ลากเสียง (`เอ่อ` `ออ`) (นับใน `fillers_removed`) แล้วต่อ token ที่เหลือโดยไม่เติมช่องว่าง เฉพาะเมื่อ token ไทยอื่นทุกตัวในช่วงที่ไม่มีช่องว่างเดียวกันเป็นคำในพจนานุกรม ถ้ามีเศษคำ แปลว่า newmm ตัดผ่านคำที่สะกดเพี้ยน (`อ่ากาศ` ตัดเป็น `อ่า` `กา` `ศ`) จึงไม่ลบ คำที่มี filler เป็นส่วนหนึ่ง เช่น `อ่าน` `อ่าง` `เอ่อล้น` `อึมครึม` ยังอยู่ เพราะ newmm ตัดเป็นคำเดียว `เอ่อ` ที่เป็นคำกริยา (น้ำเอ่อขึ้นมา) ไม่ถูกลบเมื่อตามหลัง `น้ำ` `ตา` `น้ำตา` หรืออยู่หน้าคำที่ขึ้นต้นด้วย `ล้น` `คลอ` `ท่วม` `ท้น` `ขึ้น` (`น้ำตาเอ่อคลอ`, `น้ำเอ่อท่วมถนน`, `น้ำเริ่มเอ่อขึ้นมา`) งานนี้เป็นเส้นตรงตามจำนวน token (`/v1/clean` รับข้อความยาวเท่าไรก็ได้)
- **filler เพิ่ม:** `ฮึม` `ฮึ่ม` `อึม` `อึ่ม` ส่วน `เออ` และ `อะ` ไม่นับ เพราะเป็นคำจริง

golden ที่ต่าง: `fillers.jsonl` 5 เคส (`ER, well`, `Um... right`, `uh, okay`, `อืมมาก`, `เอ่อสวัสดีครับ` ใน `tests/known_diffs/fillers.jsonl`) และ `dictate.jsonl` 30 เคส (input ทั้งห้าในหกชุดตั้งค่าที่เปิด `remove_fillers`) ใน `dictate.jsonl` ค่าที่คาดไว้คือผลของ pipeline ส่วนที่เหลือ (`remove_fillers: false`) บนผลของ Rust จาก `known_diffs/fillers.jsonl` และ test ตรวจว่าจำนวนเคสตรงตามนี้

## 8. gate hallucination: ตัด decoder loop แทนการทิ้งทั้งประโยค

Python ส่ง `no_speech` ทันทีเมื่อ `_is_repetition_loop` เจอคำเดียวกันติดกัน 6 ครั้งขึ้นไป ทำให้เสียงพูดจริงที่อยู่ก่อน loop หายไปทั้งหมด เช่น `the latency is a bit high เราควร ต้อง ต้อง ×30` ได้ผลเป็นข้อความว่าง

Rust (`trim_repetition_loops`) ทำงานก่อน `text_hallucination` โดยยุบ token ที่ซ้ำกัน (casefold) ติดกันตั้งแต่ 6 ตัวให้เหลือตัวแรกตัวเดียว ถ้า token สุดท้ายถูกตัดกลางคำและเป็นส่วนต้นของคำที่วน (`ต` หลัง `ต้อง ×N`) ก็นับเป็นส่วนของ loop ด้วย token ที่เป็นตัวเลขล้วนหรือยาวตัวเดียว (`เบอร์ 0 8 1 1 1 1 1 1 2 3`, `รหัสผ่าน 1 1 1 1 1 1`) ไม่ถูกยุบ เพราะอาจเป็นเลขที่พูดจริง ยุบแล้วจะพิมพ์เลขผิดโดยไม่มีสัญญาณ จึงปล่อยให้ `text_hallucination` ตอบ `no_speech` เหมือน Python ถ้านอก loop เหลือตัวอักษรที่ไม่ใช่ช่องว่างน้อยกว่า 8 ตัว ผลยังเป็น `no_speech("hallucination")` เหมือน Python ไม่อย่างนั้นจะใช้ข้อความที่ตัดแล้วต่อ แล้วจึงตรวจ `text_hallucination` ตามเดิม คำบรรยายผีและ loop ที่ไม่เว้นวรรค (`คือคือคือ…`) จึงยังเป็น `no_speech` และข้อความสั้นกว่า 12 ตัวอักษรไม่ถูกแตะ เหมือน `_is_repetition_loop`

golden ไม่มีเคสที่ต่าง เพราะ `dictate.jsonl` ไม่มีเคส loop ส่วน test `trim_repetition_loops_only_fires_on_loops` ตรวจว่าการตัดเกิดเฉพาะกับ input ใน `repetition_loop.jsonl` ที่ Python ตอบ `true` ผลจาก eval: คลิปที่ typhoon-ctx วน loop ได้ข้อความจริงแทนข้อความว่าง ส่วน turbo ไม่เกิด loop จึงไม่เปลี่ยน

## 9. รวมตัวอักษรที่ STT สะกดทีละตัว (`asrfix::join_spelled`)

Oliv ไม่มีขั้นนี้ Qwen3-ASR มักเขียนตัวย่อทีละตัวอักษร (`G P U`, `C I`, `T T L`, `O M`) และอ่านรหัสเป็นคำ (`S three`, `R two`) ตัวอักษรเดี่ยวทำให้ gate ขึ้น `latin-crumb` และ guardrail นับ `G P U` เป็น 3 token จึงปฏิเสธ `GPU` ที่ LLM รวมให้ว่าสั้นเกินไป (`tooShort`)

Rust รวมให้ใน `clean_text` หลัง fillers และก่อน `clean_ex` (ทำแม้ปิด cleanup) เฉพาะเมื่อ `asr_profile` เป็น `qwen3asr` เพราะ turbo และ typhoon-ctx เขียนตัวย่อติดกันอยู่แล้ว และภาษาอังกฤษล้วนชนกับกฎได้ มีสองกฎ

- ตัวพิมพ์ใหญ่ ASCII ตัวเดียว 2 ถึง 6 ตัวที่คั่นด้วยช่องว่างหนึ่งช่อง และไม่ติดกับตัวอักษร ASCII ตัวเลข หรือ `'` จะรวมเป็นคำเดียว ยกเว้นคู่ที่มีแค่ `I`/`A` ส่วนชุดที่ยาวกว่า 6 ตัว (นับก่อนตัด `I`/`A` ท้าย) ไม่รวม และ `I`/`A` ตัวท้ายที่ตามด้วยคำพิมพ์เล็กไม่นับ เพราะเป็นสรรพนามหรือ article (`Vitamin C I think`, `option B I guess` ไม่เปลี่ยน) ชุดที่ตามด้วยคำ `or`/`and` (`Choose A B or C`) หรือติด `-` (`A B-tree`) เป็นรายการหรือคำประสม จึงไม่รวม ตัวอักษรที่มี combining mark ตามมา (`A` + U+0301) หรือสระบน/ล่างไทยตามมา ไม่นับเป็นตัวอักษรเดี่ยว
- ตัวอักษรเดี่ยวที่ไม่ใช่ `a`/`i` หรือตัวพิมพ์ใหญ่ 2-3 ตัว ตามด้วยคำตัวเลขอังกฤษ `zero` ถึง `nine` (ตัวพิมพ์ใดก็ได้) จะกลายเป็นตัวอักษรต่อด้วยเลข คำพิมพ์เล็กที่ยาว 2-3 ตัวไม่นับ และตัวพิมพ์ใหญ่ที่เป็นคำอังกฤษ (`NOT_CODES` เช่น `OK` `AM` `PM` `NO`) ก็ไม่นับ และคำตัวเลขที่ตามด้วยช่องว่างแล้วคำภาษาอังกฤษพิมพ์เล็กเป็นส่วนของประโยค (`plan B two days later`, `Press X one more time`, `Vitamin C one tablet`) ดังนั้น `for one`, `Cover eight`, `OK one more` และ `3 PM two days` ก็ไม่เปลี่ยน

golden ไม่มีเคสที่ต่าง เพราะ golden รันด้วย turbo ผลจาก eval: ข้อความจาก turbo และ typhoon-ctx ไม่มี input ที่เข้ากฎเลย ข้อเสียที่ยอมรับได้ (เฉพาะ qwen3asr) คือภาษาอังกฤษล้วนอย่าง `U S` จะกลายเป็น `US`

## 10. ถอดอักษร Cyrillic, kana และ Hangul ที่แทรกอยู่ในคำ (`foreign::romanize_embedded`)

Oliv ลบ kana, Hangul และ Han ด้วย `_strip_cjk` ส่วน Cyrillic ผ่านไปเฉย ๆ Qwen3-ASR บางครั้งเขียนพยางค์ภาษาอังกฤษเป็นอักษรต่างชาติกลางคำไทย (`рейтลิมิต`, `เช็กไทม์ของレスポン`, `มิ팅`) ผลคือคำหายไปก่อนถึง LLM หรือผู้ใช้เห็นอักษร Cyrillic และ gate ตอบ `clean-thai` จึงไม่เรียก LLM เลย

Rust ทำ `romanize_embedded` ใน `clean_text` ก่อน `strip_cjk` เฉพาะเมื่อ `asr_profile` เป็น `qwen3asr` (เหมือน `join_spelled`) และข้อความมีอักษรไทยหรือ ASCII ด้วย โมเดลตระกูล Whisper (turbo, typhoon-ctx) เขียน kana และ Hangul เฉพาะตอนหลอนคำบรรยายปิดท้าย (`ประชุมเสร็จแล้ว 감사합니다`, `ok ありがとう`) จึงถูกลบด้วย `strip_cjk` เหมือน Oliv ช่วงต่อเนื่องของอักษรต่างชาติที่ยาวไม่เกิน 6 ตัวจะถูกแทนด้วยอักษรโรมันทีละชุดอักษร (ช่วงที่ปน Cyrillic กับ kana เช่น `рейтレス` ได้ `reyt resu`) โดย Cyrillic ใช้ตาราง, kana ใช้ Hepburn พร้อม digraph ゃゅょ, っ ซ้ำพยัญชนะ และตัด ー, Hangul แยก jamo ตาม Revised Romanization แล้วเว้นวรรคจากอักษรไทยที่ติดกัน (kana และ Hangul เว้นจากตัวอักษร ASCII และตัวเลขที่ติดกันด้วย เช่น `ok 가ok` เป็น `ok ga ok` แต่ Cyrillic ที่อาจเป็นตัวหน้าตาเหมือน Latin ในคำอังกฤษไม่เว้น) สระบน/ล่างหรือวรรณยุกต์ไทยที่ตามช่วงนั้นมาไม่มีพยัญชนะให้เกาะจึงถูกตัดทิ้ง (`マイ่` เป็น `mai`)

kana และ Hangul ถูกถอดเฉพาะเมื่อติดกับอักษรไทยหรือ ASCII อย่างน้อยด้านหนึ่ง คำที่เว้นวรรคทั้งสองด้าน (`ขอบคุณครับ 감사합니다`, `ok 시청해 주셔서 감사합니다.`) เป็นคำบรรยายผี ไม่ใช่พยางค์ที่ติดคำ ถ้าข้อความมีช่วงที่จะถอดเกิน 3 ช่วงหรือรวมเกิน 12 ตัวจะไม่ถอดเลย ช่วงที่ยาวกว่า 6 ตัว ช่วงที่ปนกับ Han และข้อความที่ไม่มีไทยหรือ ASCII ไม่ถูกแตะ ทั้งหมดนี้จึงยังไปทาง `strip_cjk` (หรือ `no_speech`) ตามเดิม Han ไม่มีตารางพินอินจึงยังถูกลบ (`เจม玛`)

เมื่อถอดอักษรแล้ว `clean_text` ส่ง `force_llm = "foreign-script"` ให้ `clean_ex` ซึ่งเรียก LLM เสมอ เหตุผลนี้แทน `clean-thai` และต่อท้ายเหตุผลอื่นด้วย `+` ถ้า LLM ล้มเหลว ผลแบบ deterministic ก็ไม่มี kana หรือ Cyrillic เหลือ

golden ไม่มีเคสที่ต่าง เพราะ `dictate.jsonl` ไม่มี input ที่มีอักษรเหล่านี้ และ `strip_cjk.jsonl` เรียก `strip_cjk` ตรง ๆ ผลบน eval ของ turbo ไม่มีอักษรเหล่านี้เลย จึงไม่เปลี่ยน ส่วนคลิปของ typhoon-ctx ที่มี kana ติดคำไทยกลับไปเป็นแบบ Oliv (kana ถูกลบ)

## 11. guardrail `lost_spans`: คำที่ LLM รวม สะกดใหม่ หรือแปลงเป็นเลข และ span สั้นต้องรอดเป็นคำ

Oliv นับว่า span ภาษาอังกฤษใน dict text รอดถ้าตัวอักษรของมันเป็น substring ของ candidate ที่ตัดช่องว่างแล้ว หรือห่างจาก span ใน candidate ไม่เกิน 1 edit ผลคือ LLM ที่แก้ถูกถูกปฏิเสธเป็น `spanLoss` (`Elastic Sir Ch` -> `Elasticsearch` เพราะ `Sir` หาย, `True Put` -> `Trueput`, `Observableility` -> `Observability`, `S three` -> `S3`) และในทางกลับกัน span สั้นที่หายจริงกลับรอดเพราะตัวอักษรไปซ้อนอยู่ในคำอื่น (`PR` ใน `app proof`)

Rust เปลี่ยน 5 จุด

- span ที่อยู่ติดกันและคั่นด้วยช่องว่างอย่างเดียว (ไม่เกิน 4 ตัว) ถ้ารวมกันเป็นตัวพิมพ์เล็กแล้วตรงกับ span ใน candidate หรือยาวตั้งแต่ 6 ตัวและขึ้นต้นด้วยตัวเดียวกันโดยห่างไม่เกิน `max(1, len/5)` edit จะนับว่ารอดทั้งกลุ่ม (`My SQL` -> `MySQL`, `font end` -> `frontend`)
- span ยาวตั้งแต่ 8 ตัวรอดถ้า candidate มี span ที่ขึ้นต้นตัวเดียวกันและห่างไม่เกิน `len/5` edit
- คำตัวเลข `zero` ถึง `nine` รอดถ้า candidate มีเลขนั้น
- span ที่ตามด้วยสระบน/ล่างหรือวรรณยุกต์ไทยทันที (`โปรเจกtnี้`) เป็นพยางค์ไทยที่เพี้ยน ไม่ต้องรอด
- span ยาวไม่เกิน 3 ตัวต้องรอดเป็นคำ: เท่ากับ span ใน candidate หรือส่วนที่คั่นด้วย `/._+-` หรือเป็น span นั้นต่อด้วยตัวเลขหรือ `s` (`S3`, `PRs`) หรือเป็นท้ายของ span ที่ยาวกว่า (`GraphQL`, `CircleCI`) span ที่ไม่ใช่ตัวพิมพ์ใหญ่ล้วนยังรอดได้ถ้าเป็นต้นของ span ใน candidate (`go` -> `Golang`, `env` -> `environment`, `app` -> `application`) ส่วนตัวย่อพิมพ์ใหญ่ล้วน (`PR`, `UI`) ต้องรอดเป็นคำ หรือเป็นต้นของคำทับศัพท์ที่ LLM คืนให้ โดยคำใน candidate ขึ้นต้นด้วยตัวย่อนั้นตามตัวพิมพ์เดิม หรือมีตัวพิมพ์ใหญ่ต่อจากตัวอักษรของมัน (`AI อ็อปส์` -> `AIOps`, `ML โฟลว์` -> `MLflow`, `PG บาวน์เซอร์` -> `PgBouncer`, `SQLite`, `CICD`, `VSCode`) คำพิมพ์เล็กที่บังเอิญขึ้นต้นด้วยตัวอักษรเดียวกัน (`PR` -> `proof` หรือ `Proof`) ไม่นับ

`normalize_thai_spacing` ก็ไม่เว้นวรรคระหว่างตัวอักษร ASCII กับสระบน/ล่างหรือวรรณยุกต์ไทยที่ตามมา เพราะเครื่องหมายเหล่านี้ขึ้นต้นคำไม่ได้ Oliv ทำให้ `โปรเจกtnี้` กลายเป็น `โปรเจก tn ี้` ที่มี `ี้` ลอยอยู่

golden ต่างกัน 29 คู่ใน `lost_spans.jsonl` (`tests/known_diffs/lost_spans.jsonl`): span สั้นที่ตัวอักษรแค่ไปซ้อนอยู่ในคำอื่นของ candidate นับว่าหาย (`a`, `at`, `an`, `Let`, `P` เทียบกับ `completely unrelated`) และ span ยาวหรือกลุ่ม span ที่สะกดใกล้กันนับว่ารอด (`known-good` -> `known-go`, `short/ambiguous` -> `short/ambiguo`, `transient is` -> `transient`) `guardrail.jsonl`, `clean_ex.jsonl`, `dictate.jsonl` และ `spacing.jsonl` ไม่มีเคสที่ต่าง unit test ใน `src/guardrail.rs` ครอบตัวอย่างข้างบน

## 12. guardrail `thai_divergence`: คำทับศัพท์ที่ LLM คืนเป็นภาษาอังกฤษไม่นับว่าหาย และตัวเลขไทยที่ถูกแปลเป็นคำอังกฤษ

Oliv นับคำไทยจริง (ยาวตั้งแต่ 5 ตัว) ที่ไม่อยู่ใน candidate เป็น "เนื้อหาไทยที่หาย" รวมถึงคำทับศัพท์ที่อยู่ใน words_th (`ฟังก์ชัน`, `แฮนเดิล`, `รีพอร์ต`, `พายทอร์ช`) ซึ่ง LLM คืนเป็นภาษาอังกฤษถูกต้อง ผลคือ output ที่ดีถูกปฏิเสธเป็น `editDist` โดยเฉพาะกับ STT ที่ถอดภาษาอังกฤษเป็นอักษรไทยทั้งประโยค

Rust ไม่นับคำไทยที่หายเมื่อ candidate เพิ่ม span ภาษาอังกฤษ (ยาวตั้งแต่ 3 ตัว และไม่อยู่ใน dict text) ที่ `phonetic::fold` ห่างจาก `thai_fold` ของคำนั้นไม่เกิน 0.45 (`norm_dist`, `LOAN_FOLD_MAX`) จำนวน invented ไม่เปลี่ยน การแปลจริงยังโดนเพราะเสียงไม่ตรง (`พรุ่งนี้ประชุม...` -> `tomorrow meeting...` ยังหาย 6 คำ) และมีเช็กใหม่หลัง translation gloss: ถ้า dict text มีคำตัวเลขไทย (token ใน `SPOKEN_NUMBER_WORDS` หรือตัวเลขไทยทั้งคำอย่าง `หนึ่งร้อย`) ที่หายไปจาก candidate แล้ว candidate เพิ่มคำตัวเลขอังกฤษ (`one` ถึง `twenty`, `thirty` ถึง `ninety`, `hundred`, `thousand`, `million`) ที่ dict text ไม่มี จะ fallback เป็น `translate->dict` ไม่งั้นการคลาย editDist จะปล่อย `สามร้อยสี่สิบ มิลลิวินาที` -> `three hundred forty milliseconds` ผ่าน ตัวเลขไทยที่ยังอยู่ใน candidate เป็นคำทั้งคำ หรือถูกเขียนเป็นตัวเลขที่มีค่าเท่ากัน ไม่นับ คำทับศัพท์ที่มีเลขอังกฤษจึงผ่าน (`สองคนแบบวันทูวัน` -> `สองคนแบบ one-to-one`, `ทูเฟสคอมมิตสามรอบ` -> `two-phase commit สามรอบ`, `วันออนวันกับน้องสองคน` -> `one-on-one กับน้อง 2 คน`) แต่ตัวเลขที่เป็นแค่ส่วนหนึ่งของคำอื่นไม่นับว่ายังอยู่ (`ห้า` ใน `ห้าม`, `สาม` ใน `สามารถ`)

golden ต่างกัน 1 คู่ใน `thai_divergence.jsonl` (`tests/known_diffs/thai_divergence.jsonl`): `เปิดแอปพลิเคชั่นนี้ให้หน่อย` -> `completely unrelated` ได้ lost 1 แทน 2 เพราะ `completely` ที่ candidate เพิ่มมาเสียงใกล้ `แอปพลิเคชั่น` พอ (invented เท่าเดิม) `guardrail.jsonl`, `clean_ex.jsonl` และ `dictate.jsonl` ไม่มีเคสที่ต่าง ส่วนเช็ก `translate->dict` ครอบด้วย unit test ใน `src/guardrail.rs`

## 13. flag `ok+script` และ forced-English re-decode ที่ไม่ใช่ภาษาอังกฤษ

Oliv ไม่ตรวจอักษรใน output ของ LLM ส่วน Rust ยังรับ candidate เหมือนเดิม แต่ถ้ามีตัวอักษรนอกอักษรไทย, ASCII และ Latin (Latin-1 ถึง Extended-B และ Extended Additional) เช่น Devanagari, CJK, Cyrillic หรือ Arabic ที่ LLM เขียนเอง (เช่น `स्कीมา` ที่ควรเป็นคำทับศัพท์ไทย) flag จะเป็น `ok+script` แทน `ok` (`guardrail::SCRIPT_FLAG`) และ log ต่อคำขอของ `oliv-api` แสดงค่านี้ ข้อความไม่ถูกตัดและไม่ fallback เพราะบน eval ทั้งการตัดอักษรนั้นและการ fallback ไป dict text ให้ผลแย่ลงอย่างเห็นได้ชัด ไม่มีโค้ดส่วนไหนเทียบ `guardrail_flag == "ok"` golden ต่างกัน 23 เคสใน `guardrail.jsonl` (`tests/known_diffs/guardrail.jsonl`) ที่ candidate มีอักษรจีน ญี่ปุ่น หรือเกาหลี ข้อความเหมือนเดิม แต่ flag เป็น `ok+script` แทน `ok`

`stt::transcribe_maybe_redecode` ไม่ใช้ผล decode แบบบังคับอังกฤษ (ใช้ผล auto แทน) เมื่อผลนั้นมีอักษรเวียดนาม (U+1EA0..U+1EF9) หรือมีตัวอักษร Latin ที่ไม่ใช่ ASCII เกิน 2 ตัว (`Branch này merge xong rồi, but staging test vẫn fail` จาก Qwen3-ASR) ใน eval ของ turbo ไม่มีผล forced-en แบบนี้ ผลของ turbo จึงไม่เปลี่ยน

## 14. gate `profile-always`: profile ที่ไม่ใช่ turbo ไม่ข้าม LLM เมื่อเป็น `clean-thai`

เมื่อ `asr_profile` เป็น `qwen3asr` หรือ `typhoon-ctx` แล้ว gate ให้ `clean-thai` (ไม่มี dict hit, suspect token, loan compound หรือ latin crumb) `pipeline::clean_ex` จะรัน LLM ต่อด้วย gate reason `profile-always` เพราะสองโมเดลนี้เขียนคำทับศัพท์ด้วยพยางค์ไทยที่ถูกต้องตามพจนานุกรม (แคปค่า, เรทลิมิต, อัปโหลด) ซึ่ง signal ของ gate จับไม่ได้ ข้อความที่ไม่มีภาษาไทย (`no-thai`) ยังข้ามเหมือนเดิม และ reason จาก `force_llm` มาก่อน ส่วน turbo (ค่าเริ่มต้น) ไม่เปลี่ยน golden ทั้งหมดรันด้วย turbo จึงไม่มี case ที่ต่าง

## ส่วนที่ไม่ได้พอร์ต (อยู่นอก v1)

- คำสั่งจัดรูปแบบด้วยเสียง (B4, `format_commands`) และ `fuzzy_command_spans`
- gate ที่ต้องใช้เสียง ได้แก่ silence และ too_long (ถ้าต้องการจะทำฝั่ง `/v1/dictate`)
- ablation ด้วย `OLIV_CLEANUP_NO_LLM`

## พฤติกรรมของ Python ที่พอร์ตมาตรงตัวถึงจะดูแปลก

- `words_to_num` ถูก Oliv เรียกด้วย `str` ไม่ใช่ list ทำให้ `words.index("จุด") + 1` ไปชี้กลางคำว่า "จุด" ผลคือ input ใดก็ตามที่มี "จุด" จะโยน `ValueError` เสมอ ส่วน decimal ใน `thai_format` ประกอบเองจาก token จึงไม่กระทบ (เจอจาก differential fuzz)
- `royin` ของ pythainlp โยน `IndexError` เมื่อ `ฤ` รอดผ่าน vowel pass ไปได้ `phonetic._royin` จะคืน `""` ในกรณีนี้
- `ลบ` ผ่านตัวกรองอักขระตัวเลขของ `thai_format` และ `words_to_num("ลบ") == 0` จึงนับเป็นตัวเลข เลขติดลบที่ไม่มี "จุด" จะไม่ถูกแปลงเพราะน้อยกว่า 10 แต่ถ้ามี "จุด" จะได้เป็นทศนิยมติดลบ

## วิธีตรวจ

```sh
cd oliv-api
cargo test --release                      # golden ทั้งหมด + llm_fallback
# ชุด fixture อื่นที่ไม่ได้อยู่ใน git (schema เดียวกัน) ไฟล์ที่ไม่มีในชุดนั้นจะถูกข้าม
OLIV_GOLDEN_DIR=/path/to/fixtures cargo test --release
```

ผล differential fuzz (เครื่องมือเลิกใช้แล้วและไม่ได้เผยแพร่): สอง seed รวม 23,000 input ครอบ 17 ฟังก์ชัน ตรงกับ Python 100% หลังแก้ `words_to_num`
