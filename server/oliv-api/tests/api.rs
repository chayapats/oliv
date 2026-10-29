//! oliv-api routes with mocked STT and LLM (no network; the HTTP round trip
//! uses a loopback listener).

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::{Arc, Mutex};

use base64::Engine;
use oliv_pipeline::api::{App, bind, serve};
use oliv_pipeline::dictate::AsrProfile;
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request};
use oliv_pipeline::stt::{Stt, Transcript};
use serde_json::{Value, json};

const TOKEN: &str = "t0k3n-0123456789abcdef0123456789abcdef";

/// One scripted decode: (text, avg_logprob) or an error.
type Decode = Result<(String, Option<f64>), String>;
/// Every STT call as (initial prompt, language).
type Calls = Arc<Mutex<Vec<(Option<String>, Option<String>)>>>;

/// Answers the auto decode with `auto` and a forced-English decode with `en`, and
/// records every call as (initial prompt, language).
struct FakeStt {
    auto: Decode,
    en: Decode,
    calls: Calls,
}

impl Stt for FakeStt {
    fn transcribe(
        &self,
        wav: &[u8],
        prompt: Option<&str>,
        language: Option<&str>,
    ) -> Result<Transcript, String> {
        assert_eq!(wav, sample_wav());
        self.calls
            .lock()
            .unwrap()
            .push((prompt.map(str::to_string), language.map(str::to_string)));
        let d = match language {
            None => &self.auto,
            Some("en") => &self.en,
            Some(l) => panic!("unexpected language {l}"),
        };
        d.clone()
            .map(|(text, avg_logprob)| Transcript { text, avg_logprob })
    }
}

/// Echoes a canned generation and records which prompt was used.
struct FakeLlm {
    generation: String,
    seen: Arc<Mutex<Vec<Prompt>>>,
}

impl Llm for FakeLlm {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        self.seen.lock().unwrap().push(req.prompt);
        Ok(self.generation.clone())
    }

    fn healthy(&self) -> bool {
        false
    }
}

struct Harness {
    app: App,
    stt_calls: Calls,
    llm_prompts: Arc<Mutex<Vec<Prompt>>>,
}

/// A confident auto decode of `stt` (no re-decode).
fn harness(stt: Result<&str, &str>, generation: &str) -> Harness {
    let auto = stt
        .map(|t| (t.to_string(), Some(-0.1)))
        .map_err(str::to_string);
    harness_stt(auto, Err("no forced-en decode expected".into()), generation)
}

fn harness_stt(auto: Decode, en: Decode, generation: &str) -> Harness {
    let stt_calls = Arc::new(Mutex::new(Vec::new()));
    let llm_prompts = Arc::new(Mutex::new(Vec::new()));
    let app = App {
        auth: oliv_pipeline::auth::Auth::legacy(TOKEN.into()),
        admission: Arc::new(oliv_pipeline::admission::Admission::default()),
        prompt: Prompt::V3,
        asr_profile: AsrProfile::Turbo,
        llm_timeout_s: 5,
        stt: Box::new(FakeStt {
            auto,
            en,
            calls: Arc::clone(&stt_calls),
        }),
        llm: Box::new(FakeLlm {
            generation: generation.into(),
            seen: Arc::clone(&llm_prompts),
        }),
        busy: Mutex::new(()),
        dictionaries: oliv_pipeline::dictionary_store::DictionaryStore::in_memory(),
        asr_gate: oliv_pipeline::stage_gate::StageGate::new(1),
    };
    Harness {
        app,
        stt_calls,
        llm_prompts,
    }
}

fn auth() -> Option<&'static str> {
    Some("Bearer t0k3n-0123456789abcdef0123456789abcdef")
}

fn sample_wav() -> Vec<u8> {
    let mut w = b"RIFF".to_vec();
    w.extend_from_slice(&38u32.to_le_bytes());
    w.extend_from_slice(b"WAVEfmt ");
    w.extend_from_slice(&16u32.to_le_bytes());
    for n in [1u16, 1] {
        w.extend_from_slice(&n.to_le_bytes());
    }
    for n in [16000u32, 32000] {
        w.extend_from_slice(&n.to_le_bytes());
    }
    for n in [2u16, 16] {
        w.extend_from_slice(&n.to_le_bytes());
    }
    w.extend_from_slice(b"data");
    w.extend_from_slice(&2u32.to_le_bytes());
    w.extend_from_slice(&0i16.to_le_bytes());
    w
}
fn wav_b64() -> String {
    base64::engine::general_purpose::STANDARD.encode(sample_wav())
}

fn post(h: &Harness, path: &str, body: Value) -> (u16, Value) {
    h.app
        .handle("POST", path, auth(), body.to_string().as_bytes())
}

const DICT_HIT: &str = "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา";

#[test]
fn health_needs_no_token() {
    let h = harness(Ok(""), "");
    let (code, v) = h.app.handle("GET", "/health", None, b"");
    assert_eq!(code, 200);
    assert_eq!(v["ok"], true);
    assert_eq!(v, json!({"ok":true}));
    let (code, v) = h.app.handle("GET", "/v1/status", auth(), b"");
    assert_eq!(code, 200);
    assert_eq!(v["whisper"], true);
    assert_eq!(v["gemma"], false);
    assert!(v["version"].is_string());
    assert_eq!(v["prompt"], "v3");
    assert_eq!(v["asr_profile"], "turbo");
    assert_eq!(v["llm_timeout"], 5);
}

#[test]
fn token_required() {
    let h = harness(Ok("x"), "");
    let body = json!({"text": "x"}).to_string();
    for bad in [None, Some("Bearer nope"), Some(TOKEN), Some("Basic abc")] {
        let (code, v) = h.app.handle("POST", "/v1/clean", bad, body.as_bytes());
        assert_eq!(code, 401, "{bad:?}");
        assert_eq!(v["ok"], false);
    }
    let (code, _) = h.app.handle("POST", "/v1/dictate", None, b"{}");
    assert_eq!(code, 401);
}

#[test]
fn routing() {
    let h = harness(Ok("x"), "");
    assert_eq!(h.app.handle("GET", "/nope", auth(), b"").0, 404);
    assert_eq!(h.app.handle("GET", "/v1/clean", auth(), b"").0, 405);
    assert_eq!(h.app.handle("POST", "/health", None, b"").0, 405);
    assert_eq!(
        h.app.handle("POST", "/v1/clean", auth(), b"not json").0,
        400
    );
    assert_eq!(h.app.handle("POST", "/v1/clean", auth(), b"[1]").0, 400);
}

#[test]
fn dictate_runs_stt_then_pipeline() {
    let h = harness(Ok(DICT_HIT), "restart server แล้วเช็ค log ใน Grafana");
    let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["ok"], true);
    assert_eq!(v["raw"], DICT_HIT);
    assert_eq!(v["final"], "restart server แล้วเช็ค log ใน Grafana");
    assert_eq!(v["llm_ran"], true);
    assert_eq!(v["guardrail_flag"], "ok");
    assert_eq!(v["dict_hits"], 3);
    assert_eq!(v["no_speech"], false);
    assert_eq!(v["cleanup_error"], Value::Null);
    for k in ["t_stt", "t_cleanup"] {
        assert!(v[k].is_f64(), "{k}");
    }
    for k in [
        "gate_reason",
        "fillers_removed",
        "replacements_fired",
        "thai_format_fired",
        "vocab_fired",
    ] {
        assert!(!v[k].is_null(), "{k}");
    }
    assert_eq!(v["stt_redecoded"], false);
    // server default prompt; one auto-language decode without an initial prompt
    assert_eq!(*h.llm_prompts.lock().unwrap(), vec![Prompt::V3]);
    assert_eq!(*h.stt_calls.lock().unwrap(), vec![(None, None)]);
}

#[test]
fn dictate_options() {
    let h = harness(Ok(DICT_HIT), "restart server แล้วเช็ค log ใน Grafana");
    let body = json!({
        "wav_b64": wav_b64(),
        "prompt": "v4",
        "vocabulary": [" Kafka ", "", "Grafana"],
        "replacements": {"Grafana": "กราฟาน่า"},
    });
    let (code, v) = post(&h, "/v1/dictate", body);
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["final"], "restart server แล้วเช็ค log ในกราฟาน่า");
    assert_eq!(v["replacements_fired"], 1);
    assert_eq!(*h.llm_prompts.lock().unwrap(), vec![Prompt::V4]);
    // Oliv's typhoon backend has seed_prompt = False: vocabulary never primes STT
    // (it repetition-loops on Vault/Cassandra); the post-STT vocab pass uses it.
    assert_eq!(*h.stt_calls.lock().unwrap(), vec![(None, None)]);
}

const EN_GARBLE: &str = "PREASE REBASE YOUR BRANCH ON TOP OF THE MEANN BEFORE MERCHING.";
const EN_GOOD: &str = "please rebase your branch on top of main before merging";

fn ok(t: &str, lp: Option<f64>) -> Decode {
    Ok((t.to_string(), lp))
}

#[test]
fn unconfident_decode_is_redone_in_english() {
    let h = harness_stt(
        ok(EN_GARBLE, Some(-0.45)),
        ok(EN_GOOD, Some(-0.2)),
        "never used",
    );
    let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["raw"], EN_GOOD);
    assert_eq!(v["final"], EN_GOOD);
    assert_eq!(v["stt_redecoded"], true);
    assert_eq!(
        *h.stt_calls.lock().unwrap(),
        vec![(None, None), (None, Some("en".into()))]
    );
}

#[test]
fn english_decode_must_beat_auto_by_the_margin() {
    // _REDECODE_MARGIN = 0.02: -0.44 is not better enough than -0.45
    let h = harness_stt(
        ok(EN_GARBLE, Some(-0.45)),
        ok(EN_GOOD, Some(-0.44)),
        "never used",
    );
    let (_, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
    assert_eq!(v["raw"], EN_GARBLE);
    assert_eq!(v["stt_redecoded"], false);
    assert_eq!(h.stt_calls.lock().unwrap().len(), 2);
}

#[test]
fn vietnamese_english_decode_keeps_the_auto_text() {
    let vi = "Branch này merge xong rồi, but staging test vẫn fail.";
    let h = harness_stt(ok(EN_GARBLE, Some(-0.45)), ok(vi, Some(-0.2)), "never used");
    let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["raw"], EN_GARBLE);
    assert_eq!(v["stt_redecoded"], false);
    assert_eq!(h.stt_calls.lock().unwrap().len(), 2);
}

#[test]
fn no_redecode_when_confident_or_unknown() {
    // _REDECODE_MIN_LOGPROB = -0.30 is itself confident enough; None = no segments
    for lp in [Some(-0.30), None] {
        let h = harness_stt(
            ok("สวัสดี", lp),
            Err("must not be called".into()),
            "never used",
        );
        let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
        assert_eq!(code, 200, "{v}");
        assert_eq!(v["raw"], "สวัสดี");
        assert_eq!(v["stt_redecoded"], false);
        assert_eq!(h.stt_calls.lock().unwrap().len(), 1, "{lp:?}");
    }
}

#[test]
fn failed_english_decode_keeps_the_auto_text() {
    let h = harness_stt(
        ok(EN_GARBLE, Some(-0.9)),
        Err("stt: timeout".into()),
        "never used",
    );
    let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["ok"], true);
    assert_eq!(v["raw"], EN_GARBLE);
    assert_eq!(v["stt_redecoded"], false);
}

#[test]
fn typhoon_ctx_redecodes_like_turbo() {
    let h = harness_stt(
        ok(EN_GARBLE, Some(-0.45)),
        ok(EN_GOOD, Some(-0.2)),
        "never used",
    );
    let body = json!({"wav_b64": wav_b64(), "asr_profile": "typhoon-ctx"});
    let (code, v) = post(&h, "/v1/dictate", body);
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["raw"], EN_GOOD);
    assert_eq!(v["stt_redecoded"], true);
}

#[test]
fn qwen3asr_decodes_once_with_vocabulary_context() {
    let mut h = harness_stt(
        ok(EN_GARBLE, Some(-0.9)),
        Err("must not be called".into()),
        "never used",
    );
    h.app.asr_profile = AsrProfile::Qwen3Asr;
    let body = json!({"wav_b64": wav_b64(), "vocabulary": [" Kafka ", "", "Grafana"]});
    let (code, v) = post(&h, "/v1/dictate", body);
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["raw"], EN_GARBLE);
    assert_eq!(v["stt_redecoded"], false);
    assert_eq!(
        *h.stt_calls.lock().unwrap(),
        vec![(Some("Kafka, Grafana".into()), None)]
    );
}

#[test]
fn request_profile_overrides_the_server() {
    let mut h = harness_stt(
        ok(EN_GARBLE, Some(-0.45)),
        ok(EN_GOOD, Some(-0.2)),
        "never used",
    );
    h.app.asr_profile = AsrProfile::Qwen3Asr;
    let body = json!({"wav_b64": wav_b64(), "asr_profile": "turbo"});
    let (_, v) = post(&h, "/v1/dictate", body);
    assert_eq!(v["stt_redecoded"], true);

    h.app.asr_profile = AsrProfile::Turbo;
    h.stt_calls.lock().unwrap().clear();
    let body = json!({"wav_b64": wav_b64(), "asr_profile": "qwen3asr"});
    let (_, v) = post(&h, "/v1/dictate", body);
    assert_eq!(v["raw"], EN_GARBLE);
    assert_eq!(*h.stt_calls.lock().unwrap(), vec![(None, None)]);
}

#[test]
fn cleanup_off_is_verbatim() {
    let h = harness(Ok("อืม  สวัสดี"), "never used");
    let body = json!({"wav_b64": wav_b64(), "cleanup": false, "remove_fillers": false,
                      "thai_format": false});
    let (_, v) = post(&h, "/v1/dictate", body);
    assert_eq!(v["final"], "อืม  สวัสดี");
    assert!(h.llm_prompts.lock().unwrap().is_empty());
}

#[test]
fn stt_failure_is_the_only_not_ok() {
    let h = harness(Err("stt: connection refused"), "");
    let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
    assert_eq!(code, 502);
    assert_eq!(v["ok"], false);
    assert_eq!(v["error"], "speech recognition failed; retry later");
}

#[test]
fn no_speech() {
    for (raw, reason) in [
        ("   ", "no_speech"),
        ("謝謝觀看", "no_speech"),
        ("Thanks for watching!", "hallucination"),
    ] {
        let h = harness(Ok(raw), "never used");
        let (code, v) = post(&h, "/v1/dictate", json!({"wav_b64": wav_b64()}));
        assert_eq!(code, 200);
        assert_eq!(v["ok"], true);
        assert_eq!(v["no_speech"], true, "{raw}");
        assert_eq!(v["final"], "");
        assert_eq!(v["gate_reason"], reason);
        assert_eq!(v["raw"], raw, "raw stays the real STT output");
    }
}

#[test]
fn bad_requests() {
    let h = harness(Ok("x"), "");
    for body in [
        json!({}),
        json!({"wav_b64": "%%%"}),
        json!({"wav_b64": ""}),
        json!({"wav_b64": wav_b64(), "cleanup": "yes"}),
        json!({"wav_b64": wav_b64(), "vocabulary": "Kafka"}),
        json!({"wav_b64": wav_b64(), "replacements": {"a": 1}}),
        json!({"wav_b64": wav_b64(), "prompt": "v9"}),
        json!({"wav_b64": wav_b64(), "asr_profile": "latin"}),
        json!({"wav_b64": wav_b64(), "asr_profile": true}),
    ] {
        let (code, v) = post(&h, "/v1/dictate", body.clone());
        assert_eq!(code, 400, "{body}");
        assert_eq!(v["ok"], false);
    }
    assert_eq!(post(&h, "/v1/clean", json!({"text": 5})).0, 400);
}

#[test]
fn clean_skips_stt() {
    let h = harness(
        Err("must not be called"),
        "restart server แล้วเช็ค log ใน Grafana",
    );
    let (code, v) = post(&h, "/v1/clean", json!({"text": DICT_HIT, "prompt": "V2"}));
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["raw"], DICT_HIT);
    assert_eq!(v["final"], "restart server แล้วเช็ค log ใน Grafana");
    assert_eq!(v["t_stt"], 0.0);
    assert_eq!(*h.llm_prompts.lock().unwrap(), vec![Prompt::V2]);
}

fn http(addr: &str, req: &str) -> String {
    let mut s = TcpStream::connect(addr).unwrap();
    s.write_all(req.as_bytes()).unwrap();
    let mut out = String::new();
    s.read_to_string(&mut out).unwrap();
    out
}

#[test]
fn http_round_trip() {
    let server = bind("127.0.0.1:0").unwrap();
    let addr = server.local_addr().unwrap().to_string();
    let app = Arc::new(harness(Ok("สวัสดีครับ"), "").app);
    std::thread::spawn(move || serve(app, server));

    let r = http(
        &addr,
        "GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
    );
    assert!(r.starts_with("HTTP/1.1 200"), "{r}");
    assert!(r.contains("application/json"));

    let body = json!({"wav_b64": wav_b64()}).to_string();
    let r = http(
        &addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        ),
    );
    assert!(r.starts_with("HTTP/1.1 401"), "{r}");

    let r = http(
        &addr,
        &format!(
            "POST /v1/dictate HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: Bearer {TOKEN}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        ),
    );
    assert!(r.starts_with("HTTP/1.1 200"), "{r}");
    let json_start = r.find("\r\n\r\n").unwrap() + 4;
    let v: Value = serde_json::from_str(&r[json_start..]).unwrap();
    assert_eq!(v["final"], "สวัสดีครับ");

    let r = http(
        &addr,
        &format!(
            "POST /v1/clean HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: Bearer {TOKEN}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            oliv_pipeline::api::MAX_BODY + 1
        ),
    );
    assert!(r.starts_with("HTTP/1.1 413"), "{r}");
}

// --- personal dictionary --------------------------------------------------

fn get(h: &Harness, path: &str) -> (u16, Value) {
    h.app.handle("GET", path, auth(), b"")
}

fn sync(h: &Harness, ops: Value) -> (u16, Value) {
    post(h, "/v1/dictionary", json!({ "ops": ops }))
}

fn upsert(id: &str, word: &str, correction: Option<&str>, starred: bool) -> Value {
    json!({"op": "upsert", "entry": {"id": id, "word": word, "correction": correction, "starred": starred}})
}

#[test]
fn dictionary_sync_round_trip() {
    let h = harness(Ok("x"), "");
    let (code, v) = get(&h, "/v1/dictionary");
    assert_eq!(code, 200, "{v}");
    assert_eq!(
        (v["revision"].clone(), v["entries"].clone()),
        (json!(0), json!([]))
    );
    assert_eq!(v["max_entries"], 1000);

    let (code, v) = sync(
        &h,
        json!([
            upsert("a", "SHA256", None, true),
            upsert("b", "Koolify", Some("koolify"), false),
            upsert("c", "sha256", None, false),
        ]),
    );
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["revision"], 1);
    assert_eq!(v["entries"].as_array().unwrap().len(), 2);
    assert_eq!(
        v["rejected"],
        json!([{"index": 2, "id": "c", "reason": "duplicate"}])
    );
    assert_eq!(v["entries"][1]["correction"], "koolify");

    let (_, v) = sync(&h, json!([{"op": "delete", "id": "b"}]));
    assert_eq!(v["revision"], 2);
    let (_, v) = get(&h, "/v1/dictionary");
    assert_eq!(v["entries"][0]["word"], "SHA256");
    assert_eq!(v["entries"].as_array().unwrap().len(), 1);
}

#[test]
fn dictionary_route_rejects_bad_requests() {
    let h = harness(Ok("x"), "");
    assert_eq!(h.app.handle("PUT", "/v1/dictionary", auth(), b"{}").0, 405);
    assert_eq!(h.app.handle("GET", "/v1/dictionary", None, b"").0, 401);
    assert_eq!(
        h.app.handle("POST", "/v1/dictionary", auth(), b"nope").0,
        400
    );
    assert_eq!(h.app.handle("GET", "/v1/dictionary", auth(), b"{}").0, 413);
    let (code, v) = sync(
        &h,
        json!([{"op": "upsert", "entry": {"id": "a", "word": "!!!"}}]),
    );
    assert_eq!(code, 400, "{v}");
    assert!(v["error"].as_str().unwrap().starts_with("ops[0]:"), "{v}");
    let (_, v) = get(&h, "/v1/dictionary");
    assert_eq!(v["revision"], 0, "a rejected request changes nothing");
}

#[test]
fn dictate_applies_the_stored_dictionary() {
    let h = harness(Ok("ใช้ SHA สองห้าหก กับ koolify"), "never used");
    sync(
        &h,
        json!([
            upsert("a", "SHA256", None, false),
            upsert("b", "Koolify", Some("koolify"), false)
        ]),
    );
    let (code, v) = post(
        &h,
        "/v1/dictate",
        json!({"wav_b64": wav_b64(), "thai_format": false}),
    );
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["final"], "ใช้ SHA256 กับ Koolify");
    assert_eq!(v["dictionary_revision"], 1);
    assert!(v["dict_hits"].as_u64().unwrap() >= 2, "{v}");
}

#[test]
fn llm_that_romanizes_a_fixed_thai_name_is_rejected() {
    // The user fixed สมชัย → สมชาย; the LLM then wrote it in Latin script.
    let h = harness(Ok("คุณสมชัยมาไหม"), "คุณ Somchai มาไหม");
    sync(&h, json!([upsert("a", "สมชาย", Some("สมชัย"), false)]));
    let (code, v) = post(&h, "/v1/clean", json!({"text": "คุณสมชัยมาไหม"}));
    assert_eq!(code, 200, "{v}");
    assert_eq!(v["llm_ran"], true);
    assert_eq!(v["guardrail_flag"], "dictionary->dict");
    assert_eq!(v["final"], "คุณสมชายมาไหม");
}

#[test]
fn qwen3asr_context_puts_starred_dictionary_words_first() {
    let mut h = harness_stt(
        ok(EN_GARBLE, Some(-0.9)),
        Err("must not be called".into()),
        "x",
    );
    h.app.asr_profile = AsrProfile::Qwen3Asr;
    sync(
        &h,
        json!([
            upsert("a", "Grafana", None, false),
            upsert("b", "Koolify", None, true)
        ]),
    );
    let body = json!({"wav_b64": wav_b64(), "cleanup": false, "vocabulary": ["Kafka", "grafana"]});
    let (code, v) = post(&h, "/v1/dictate", body);
    assert_eq!(code, 200, "{v}");
    assert_eq!(
        *h.stt_calls.lock().unwrap(),
        vec![(Some("Koolify, Grafana, Kafka".into()), None)]
    );
}

#[test]
fn dictionary_over_http_needs_no_content_type_for_get() {
    let server = bind("127.0.0.1:0").unwrap();
    let addr = server.local_addr().unwrap().to_string();
    let app = Arc::new(harness(Ok("x"), "").app);
    std::thread::spawn(move || serve(app, server));

    let r = http(
        &addr,
        &format!(
            "GET /v1/dictionary HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: Bearer {TOKEN}\r\n\r\n"
        ),
    );
    assert!(r.starts_with("HTTP/1.1 200"), "{r}");

    let body = json!({"ops": [upsert("a", "Grafana", None, false)]}).to_string();
    let r = http(
        &addr,
        &format!(
            "POST /v1/dictionary HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: Bearer {TOKEN}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        ),
    );
    assert!(r.starts_with("HTTP/1.1 200"), "{r}");
    assert!(r.contains("\"revision\":1"), "{r}");

    let r = http(
        &addr,
        &format!(
            "POST /v1/dictionary HTTP/1.1\r\nHost: x\r\nConnection: close\r\nAuthorization: Bearer {TOKEN}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            oliv_pipeline::api::MAX_DICTIONARY_BODY + 1
        ),
    );
    assert!(r.starts_with("HTTP/1.1 413"), "{r}");
}
