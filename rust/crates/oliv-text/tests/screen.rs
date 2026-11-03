//! Names on screen: `screen_text` through the local text path. Candidate
//! filtering is unit-tested in `screen.rs`, the stricter matching rules in
//! oliv-text-core.

use std::cell::Cell;

use oliv_pipeline::commands::initial_prompt;
use oliv_pipeline::dictate::{Options, clean_text};
use oliv_pipeline::llm::{Llm, LlmError, Prompt, Request};
use serde_json::{Value, json};

/// Replies with a fixed generation and counts calls.
struct Fixed(&'static str, Cell<usize>);

impl Fixed {
    fn new(reply: &'static str) -> Self {
        Fixed(reply, Cell::new(0))
    }
}

impl Llm for Fixed {
    fn generate(&self, _: &Request) -> Result<String, LlmError> {
        self.1.set(self.1.get() + 1);
        Ok(self.0.to_string())
    }
}

/// Echoes its input and counts calls.
#[derive(Default)]
struct Echo(Cell<usize>);

impl Llm for Echo {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        self.0.set(self.0.get() + 1);
        Ok(req.text.to_string())
    }
}

fn opts(body: Value) -> Options {
    let mut body = body;
    body["thai_format"] = json!(false);
    Options::from_json(body.as_object().unwrap(), Prompt::V2).unwrap()
}

/// Both entry points: the API-style `clean_text` and the sidecar's `local::clean`.
fn both(text: &str, o: &Options, llm: &dyn Llm) -> [String; 2] {
    [
        clean_text(text, o, llm).final_text,
        oliv_pipeline::local::clean(text, None, o, false, llm)
            .outcome
            .final_text,
    ]
}

#[test]
fn screen_text_is_validated_and_never_reaches_an_stt_prompt() {
    let o = opts(json!({
        "vocabulary": ["Kafka"],
        "screen_text": ["Reply to Kittiphan about the Grafana alert", "Settings"],
    }));
    assert_eq!(o.screen_terms, ["Kittiphan", "Grafana"]);
    assert_eq!(o.effective_vocabulary(), ["Kafka"]);
    assert_eq!(
        initial_prompt(None, &o.effective_vocabulary(), false).as_deref(),
        Some("Kafka")
    );
    for bad in [json!({"screen_text": "x"}), json!({"screen_text": [1]})] {
        assert!(Options::from_json(bad.as_object().unwrap(), Prompt::V2).is_err());
    }
    assert!(opts(json!({})).screen_terms.is_empty());
}

#[test]
fn a_screen_without_names_changes_nothing() {
    let plain = opts(json!({"dictionary": [{"word": "Grafana"}]}));
    let everyday = opts(json!({
        "dictionary": [{"word": "Grafana"}],
        "screen_text": ["Settings", "Cancel", "ตั้งค่า", "ส่งข้อความ", "Today"],
    }));
    assert!(everyday.screen_terms.is_empty());
    for text in [
        "รีสตาร์ทเซิร์ฟเวอร์แล้วเช็คล็อกในกราฟา",
        "คุณณรงค์พงศ์มาแล้ว",
        "เมื่อวานทีมแอนทรอปิกประกาศรุ่นใหม่",
    ] {
        let a = Echo::default();
        let b = Echo::default();
        assert_eq!(both(text, &plain, &a), both(text, &everyday, &b), "{text}");
        assert_eq!(a.0.get(), b.0.get(), "{text}");
    }
}

#[test]
fn names_on_screen_are_spelled_as_shown() {
    let o = opts(json!({"screen_text": ["ณรงค์พงษ์", "Anthropic"]}));
    for out in both("คุณณรงค์พงศ์มาแล้ว", &o, &Echo::default())
    {
        assert_eq!(out, "คุณณรงค์พงษ์มาแล้ว");
    }
    for out in both("เมื่อวานทีมแอนทรอปิกประกาศรุ่นใหม่", &o, &Echo::default())
    {
        assert_eq!(out, "เมื่อวานทีม Anthropic ประกาศรุ่นใหม่");
    }
}

#[test]
fn the_users_dictionary_outranks_the_screen() {
    // The user spells the name ณรงค์พงศ์; the screen shows ณรงค์พงษ์.
    let o = opts(json!({
        "dictionary": [{"word": "ณรงค์พงศ์"}],
        "screen_text": ["ณรงค์พงษ์"],
    }));
    assert_eq!(o.screen_terms, ["ณรงค์พงษ์"]);
    for out in both("คุณณรงค์พงศ์มาแล้ว", &o, &Echo::default())
    {
        assert_eq!(out, "คุณณรงค์พงศ์มาแล้ว");
    }
    // The same word in another case is the user's: no screen term is left.
    let o = opts(json!({
        "dictionary": [{"word": "Kittiphan"}],
        "screen_text": ["KITTIPHAN", "Reply to Kittiphan"],
    }));
    assert!(o.screen_terms.is_empty());
}

/// Echoes its input and keeps the hints it was given.
#[derive(Default)]
struct Hints(std::cell::RefCell<Vec<String>>);

impl Llm for Hints {
    fn generate(&self, req: &Request) -> Result<String, LlmError> {
        self.0.borrow_mut().extend(req.hints.iter().cloned());
        Ok(req.text.to_string())
    }
}

#[test]
fn screen_terms_are_never_llm_hints() {
    // Too far from Kubernetes to snap, close enough to hint the LLM.
    let text = "เราย้ายไปคูเบอเนตแล้ว";
    let llm = Hints::default();
    clean_text(text, &opts(json!({"vocabulary": ["Kubernetes"]})), &llm);
    assert_eq!(*llm.0.borrow(), ["Kubernetes"]);
    let llm = Hints::default();
    let out = clean_text(text, &opts(json!({"screen_text": ["Kubernetes"]})), &llm);
    assert!(llm.0.borrow().is_empty());
    assert!(
        !out.gate_reason.contains("vocab-hint"),
        "{}",
        out.gate_reason
    );
}

#[test]
fn the_llm_may_not_rewrite_a_name_shown_on_screen() {
    let o = opts(json!({"screen_text": ["ฐิติพงส์"]}));
    let llm = Fixed::new("ส่ง dashboard ให้ Thitipong ดูแล้ว");
    let out = clean_text("ส่ง แดชบอร์ด ให้ฐิติพงส์ดูแล้ว", &o, &llm);
    assert_eq!(llm.1.get(), 1);
    assert!(out.final_text.contains("ฐิติพงส์"), "{}", out.final_text);
}

#[test]
fn a_name_on_screen_never_stops_a_needed_cleanup() {
    // The misspelled name is what makes the text look garbled; once the
    // screen re-spells it, the cleanup model still runs as it would have.
    let text = "เจอกันที่สยามพารากอลนะ";
    let today = Echo::default();
    let before = clean_text(text, &opts(json!({})), &today);
    assert!(before.llm_ran, "{}", before.gate_reason);
    let screen = Echo::default();
    let after = clean_text(
        text,
        &opts(json!({"screen_text": ["สยามพารากอน"]})),
        &screen,
    );
    assert_eq!(after.final_text, "เจอกันที่สยามพารากอนนะ");
    assert!(after.llm_ran, "{}", after.gate_reason);
    assert_eq!(screen.0.get(), 1);
}
