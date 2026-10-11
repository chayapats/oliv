# ผลแก้ความช้าตอนกดเริ่มอัดเสียง

ตรวจและแก้เมื่อ 8 ตุลาคม 2026 บน macOS 27.2 (26B5101f), Apple Silicon

อาการที่ผู้ใช้ยืนยันคือกดปุ่มแล้วรอกว่าจะเริ่มอัดเสียง เส้นทางก่อนเรียก OLIV API
เป็นต้นเหตุ: แอปเปิด VoiceProcessingIO บนเธรด UI และแสดง HUD หลังเปิดเสร็จ
Core Audio log ของแอปที่ติดตั้งพบ `Timeout waiting for streams` สองครั้ง
ในรอบแรก ก่อนเริ่มไมค์แบบ HAL ที่เวลา 20:37:58.769 จาก log เริ่มเปิด
20:37:55.448 รวมประมาณ 3.321 วินาที รอบ HAL ถัดมามีช่วงเปิด 80–87 ms
ตัวเลขจาก log เป็นช่วงตั้งค่าอุปกรณ์ถึงเริ่ม I/O ไม่ใช่การจับเวลาจากคีย์บอร์ด

## สิ่งที่แก้

- แสดง Getting the mic ready ทันที แล้วเปิด/ปิดไมค์บนคิวเบื้องหลังเดียวกัน
- Snapshot ไมค์, echo cancellation, ducking และขีดจำกัดเสียงตอนกดปุ่ม
  การเปลี่ยน Settings ระหว่างเปิดไม่เปลี่ยนการอัดเสียงรอบนั้น
- ปล่อยปุ่มระหว่างเปิดแล้วกลับเป็น idle ทันที ยกเลิกคำขอ ตรวจการยกเลิก
  ก่อนเริ่มหน่วยรับเสียง และไม่เก็บเฟรมเพิ่มเมื่อปล่อยปุ่ม
- จัดลำดับ cleanup และป้องกันคำสั่งหยุดที่มาช้าจากรอบเก่าไปหยุดรอบใหม่
- จำเส้นทาง AEC ที่ล้มเหลวใน UserDefaults โดยผูกกับ UID ของ input/output
  และเวอร์ชัน/build ของ macOS เก็บไม่เกิน 16 เส้นทาง ไม่มีเสียงหรือข้อความ
  เปลี่ยนอุปกรณ์หรือ macOS จะลองใหม่; สลับ Cancel speaker echo ปิด/เปิดเพื่อ retry ได้
  เส้นทางที่ยังไม่เคยตรวจอาจต้องจ่ายเวลาเปิด AEC ในครั้งแรก
- เพิ่มเวลาเริ่มรับเสียงและ backend ที่ใช้จริงใน Copy Diagnostics

คง Swift/Core Audio ไว้ เพราะเวลาเสียใน system calls ของ macOS และการจัดคิว
UI การเรียก system calls เดิมจาก Rust ไม่ข้ามช่วงตั้งค่าอุปกรณ์นี้

## ผลวัดกับไมค์จริง

ใช้ signed app ผ่าน `--mic-probe` ไม่บันทึก WAV และไม่เรียก API ถอดเสียง
จับเวลาเริ่มเรียก `AudioCapture.start()` ถึงเฟรมแรกที่ใช้ได้
จึงแยกจากเวลาแสดง HUD และการส่ง hotkey event ผ่าน main queue

Probe แรกพบ AEC เปิดได้ช้า 1.330 s หนึ่งรอบ และรอบถัดมาล้มเหลวจน fallback
เป็น HAL ที่ 2.607 s การล้มเหลวถูกจำไว้ จากนั้นเปิด process ใหม่แล้วใช้ HAL
ทันทีทั้งสามรอบ มี first-live 102–111 ms

วัดซ้ำจาก `/Applications/OLIV.app` ที่ติดตั้ง โดยเปิด echo cancellation และ
ducking ตามค่าเริ่มต้น ไมค์ built-in และอัดรอบละ 0.25 s:

| รอบ | เปิดไมค์ | เฟรมแรกที่ใช้ได้ | ปิดไมค์ | Backend |
|---|---:|---:|---:|---|
| 1 | 105 ms | 115 ms | 14 ms | HAL |
| 2 | 88 ms | 97 ms | 12 ms | HAL |
| 3 | 94 ms | 104 ms | 11 ms | HAL |

ตัวเลขนี้เป็นผลของเครื่องและเส้นทางเสียงที่ตรวจ โดยมี failed-route cache แล้ว
ไม่ใช่ค่ารับรองสำหรับไมค์ทุกชนิดหรือเส้นทาง AEC ที่เพิ่งเปลี่ยน

ข้อมูลดิบ: `build/startup-fix/first-launch-timings.json`,
`relaunch-timings.json`, `installed-timings.json`, `installed-final-timings.json`

## Validation และการติดตั้ง

- ชุด XCTest หลัก 257 tests ผ่าน
- หลังเพิ่มกรณี race อีกหนึ่งกรณี ตรวจ CaptureWorker, AudioCapture,
  VoiceProcessingFailures และ OutputDucker ซ้ำ 97 tests ผ่าน
- Release build ผ่าน และตรวจ `codesign --verify --deep --strict` ผ่าน
- ใช้ Developer ID และ designated requirement เดิมเพื่อรักษาสิทธิ์ที่มีอยู่
- รุ่นก่อนแก้อยู่ที่ `build/local-app-backups/2026-10-08-microphone-startup/OLIV.app`
- Engine ที่ผู้ใช้เลือกยังเป็น `oliv-api`; ไม่ได้เปลี่ยน API URL/key หรือ server

ข้อจำกัด: ไม่ได้ทดสอบ hotkey-to-HUD แบบจับเวลาบนหน้าจอจริง การตอบสนองและ
ลำดับ start/release/stop ตรวจด้วย integration tests ที่จำลอง Core Audio เปิดช้า
ส่วนเวลาอุปกรณ์รับเสียงตรวจด้วยไมค์จริงตามตารางข้างต้น
