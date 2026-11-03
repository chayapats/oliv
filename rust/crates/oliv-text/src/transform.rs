//! Voice editing: Command mode (apply a spoken instruction to selected text)
//! and translation mode (Thai dictation to English). One LLM call each.
//!
//! The cleanup guardrail (`guardrail.rs`) forbids rewriting; these modes ask
//! for it, so they get their own checks. Anything suspicious rejects the
//! generation and the caller keeps the user's text exactly as it was:
//! length out of bounds for the instruction, an English term, name, number,
//! URL or email address lost or invented, the wrong language, an answer to a
//! question instead of the rewritten question, or the model talking about
//! the task ("Here is…", "As an AI…").

use std::collections::HashSet;
use std::fmt;
use std::str::FromStr;
use std::sync::LazyLock;

use regex::Regex;
use serde::Serialize;

use crate::gate::latin_spans;
use crate::guardrail::lost_spans;
use crate::llm::LlmError;
use crate::prompts_transform::{COMMAND_V2, TRANSLATE_V2};
use crate::pyu::{is_blank, is_thai, lower, remove_ws, strip};
use crate::thai_format::apply_thai_format;
use crate::tokenize::word_tokenize;

/// Longest selection or dictation a transform accepts (characters). Longer
/// text is refused up front: a 2B model on a laptop takes too long and drifts.
pub const MAX_SOURCE_CHARS: usize = 2000;
/// Longest spoken instruction (characters).
pub const MAX_INSTRUCTION_CHARS: usize = 300;
/// Generation ceiling the native runtime enforces too.
pub const MAX_GENERATION_TOKENS: u32 = 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Rewrite the selection as the spoken instruction asks.
    Command,
    /// Thai dictation to English.
    Translate,
}

impl FromStr for Mode {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, String> {
        match s {
            "command" => Ok(Mode::Command),
            "translate" => Ok(Mode::Translate),
            other => Err(format!("unknown transform mode {other:?}")),
        }
    }
}

/// What the instruction asks for, as far as the checks care.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Intent {
    /// Shorter, a summary, bullet points.
    Shorten,
    /// An email or a longer, more detailed version.
    Expand,
    /// Into English.
    ToEnglish,
    /// Into Thai.
    ToThai,
    /// Same length class: politer, more formal, casual, typo fixes.
    Edit,
}

fn has_any(text: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| text.contains(n))
}

impl Intent {
    /// Classify a spoken instruction (Thai or English).
    pub fn of(instruction: &str) -> Intent {
        let i = lower(instruction);
        if has_any(&i, &["อังกฤษ", "english"]) {
            return Intent::ToEnglish;
        }
        if has_any(&i, &["ภาษาไทย", "เป็นไทย", "thai"]) {
            return Intent::ToThai;
        }
        if has_any(
            &i,
            &[
                "สั้น",
                "สรุป",
                "กระชับ",
                "ย่อ",
                "short",
                "summar",
                "concise",
                "tl;dr",
                "tldr",
                "brief",
                "trim",
                "bullet",
                "บูลเล็ต",
                "บุลเล็ต",
                "เป็นข้อ",
            ],
        ) {
            return Intent::Shorten;
        }
        if has_any(
            &i,
            &[
                "อีเมล",
                "อีเมล์",
                "email",
                "e-mail",
                "จดหมาย",
                "letter",
                "ขยาย",
                "ละเอียด",
                "ยาวขึ้น",
                "elaborate",
                "expand",
                "longer",
            ],
        ) {
            return Intent::Expand;
        }
        Intent::Edit
    }
}

/// Typo and spelling fixes may repair a misspelled English word (the check
/// then tolerates a near-miss of a source term).
fn fixes_spelling(instruction: &str) -> bool {
    has_any(
        &lower(instruction),
        &[
            "คำผิด",
            "สะกด",
            "พิมพ์ผิด",
            "typo",
            "spelling",
            "spell",
            "grammar",
            "ไวยากรณ์",
        ],
    )
}

/// One transform call.
#[derive(Clone, Copy, Debug)]
pub struct Request<'a> {
    pub mode: Mode,
    /// The spoken instruction (Command mode); ignored for translation.
    pub instruction: &'a str,
    /// The selected text (Command mode) or the cleaned dictation (translation).
    pub text: &'a str,
    /// A replacement template with `{instruction}` / `{text}` placeholders,
    /// for prompt evaluation only; the app never sets it.
    pub template: Option<&'a str>,
}

impl Request<'_> {
    pub fn intent(&self) -> Intent {
        match self.mode {
            Mode::Command => Intent::of(self.instruction),
            Mode::Translate => Intent::ToEnglish,
        }
    }

    /// The single user turn sent to the model.
    pub fn content(&self) -> String {
        let template = self.template.unwrap_or(match self.mode {
            Mode::Command => COMMAND_V2,
            Mode::Translate => TRANSLATE_V2,
        });
        template
            .replace("{instruction}", strip(self.instruction))
            .replace("{text}", strip(self.text))
    }

    /// Room for the answer: about one token per two Thai characters, more
    /// for an email, capped by the runtime.
    pub fn max_tokens(&self) -> u32 {
        let estimate = (self.text.chars().count() / 2 + 16) as u32;
        let budget = match self.intent() {
            Intent::Shorten => estimate + 64,
            Intent::Expand => estimate * 3 + 300,
            Intent::ToEnglish | Intent::ToThai => estimate * 2 + 96,
            Intent::Edit => estimate * 2 + 96,
        };
        budget.clamp(64, MAX_GENERATION_TOKENS)
    }
}

/// One model answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Generation {
    pub text: String,
    /// The model ended the answer itself. False when it was still writing at
    /// `max_tokens` (or the runtime could not say why it stopped): the text
    /// is only the start of an answer.
    pub finished: bool,
}

impl Generation {
    /// An answer the model ended itself.
    pub fn finished(text: impl Into<String>) -> Self {
        Generation {
            text: text.into(),
            finished: true,
        }
    }
}

/// Generates text for a prompt. Mocked in tests; the sidecar sends it to
/// the on-device model.
pub trait Generate {
    fn generate(&self, content: &str, max_tokens: u32) -> Result<Generation, LlmError>;
}

/// The result of one transform. `text` is the new text when `applied`, and
/// otherwise the caller's original, untouched.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Outcome {
    pub applied: bool,
    pub text: String,
    /// `ok`, or why nothing changed (`emptySelection`, `tooLong`,
    /// `noInstruction`, `noThai`, `llmError`, `unfinished`, or a guardrail
    /// reason).
    pub flag: String,
    pub intent: Intent,
    /// The model's raw generation, for evaluation. Never logged by the app.
    pub raw: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rejection(pub &'static str);

impl fmt::Display for Rejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.0)
    }
}

/// Run one transform: refuse bad input, generate, clean up the generation,
/// check it. Never returns an error: a failure keeps the original text.
pub fn transform(req: &Request, model: &dyn Generate) -> Outcome {
    let intent = req.intent();
    let keep = |flag: &str, raw: Option<String>| Outcome {
        applied: false,
        text: req.text.to_string(),
        flag: flag.to_string(),
        intent,
        raw,
    };
    if is_blank(req.text) {
        return keep("emptySelection", None);
    }
    if req.text.chars().count() > MAX_SOURCE_CHARS {
        return keep("tooLong", None);
    }
    match req.mode {
        Mode::Command => {
            if is_blank(req.instruction) {
                return keep("noInstruction", None);
            }
            if req.instruction.chars().count() > MAX_INSTRUCTION_CHARS {
                return keep("instructionTooLong", None);
            }
        }
        // Already English (or no Thai at all): nothing to translate.
        Mode::Translate if thai_share(req.text) == 0.0 => return keep("noThai", None),
        Mode::Translate => {}
    }
    let raw = match model.generate(&req.content(), req.max_tokens()) {
        // Cut off at the token limit. The checks below could pass the first
        // part of an answer (an edit needs 40% of the source's length, a
        // translation 30%), which would replace the whole text. A model that
        // ran on past its answer into the template did finish it, though.
        Ok(generation) if !generation.finished && !reached_a_stop(&generation.text) => {
            return keep("unfinished", Some(generation.text));
        }
        Ok(generation) => generation.text,
        Err(_) => return keep("llmError", None),
    };
    let candidate = clean_generation(&raw, req.text);
    let verdict = match req.mode {
        Mode::Command => check_command(req.instruction, req.text, &candidate),
        Mode::Translate => check_translation(req.text, &candidate),
    };
    match verdict {
        Ok(()) => Outcome {
            applied: true,
            text: candidate,
            flag: "ok".into(),
            intent,
            raw: Some(raw),
        },
        Err(Rejection(flag)) => keep(flag, Some(raw)),
    }
}

// MARK: Cleaning the generation

/// Chat-template markers and prompt labels the model may run on into.
const STOPS: [&str; 10] = [
    "<end_of_turn>",
    "<eos>",
    "<end_of_text>",
    "<|channel",
    "<turn|>",
    "END OF SELECTED TEXT",
    "\nINSTRUCTION:",
    "\nSELECTED TEXT:",
    "\nTHAI:",
    "\nEDITED TEXT:",
];

/// The answer ended at a chat-template marker or prompt label, whatever
/// the model wrote after it.
fn reached_a_stop(generation: &str) -> bool {
    STOPS.iter().any(|stop| generation.contains(stop))
}

/// Labels a model sometimes repeats at the start of its answer.
const LABELS: [&str; 6] = [
    "EDITED TEXT:",
    "ENGLISH:",
    "Edited text:",
    "English:",
    "Translation:",
    "OUTPUT:",
];

static PREAMBLE: LazyLock<Regex> = LazyLock::new(|| {
    // A first line that introduces the answer: "Here is the polite version:",
    // "Sure! Here's…:", "นี่คือข้อความที่สุภาพขึ้น:".
    Regex::new(
        r"(?i)^(?:sure|certainly|of course|okay|ok|here(?:'s| is| are)|below is|แน่นอน|ได้เลย|นี่คือ|ต่อไปนี้คือ|ข้อความที่)[^\n]{0,120}[:：]\s*\n",
    )
    .unwrap()
});

/// Strip what is not the edited text: template markers, a repeated label, a
/// one-line preamble, and quotes or a code fence around the whole answer
/// (unless the source had them).
pub fn clean_generation(generation: &str, source: &str) -> String {
    let mut t = generation;
    for stop in STOPS {
        if let Some(i) = t.find(stop) {
            t = &t[..i];
        }
    }
    let mut t = strip(t).to_string();
    for label in LABELS {
        if let Some(rest) = t.strip_prefix(label) {
            t = strip(rest).to_string();
        }
    }
    if let Some(m) = PREAMBLE.find(&t) {
        t = strip(&t[m.end()..]).to_string();
    }
    let source = strip(source);
    t = one_polite_particle(&t, source);
    if t.starts_with("```") && t.ends_with("```") && !source.starts_with("```") && t.len() > 6 {
        let inner = &t[3..t.len() - 3];
        // Drop a language tag on the opening fence line.
        let inner = match inner.find('\n') {
            Some(i) if !inner[..i].contains(' ') => &inner[i + 1..],
            _ => inner,
        };
        t = strip(inner).to_string();
    }
    for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("«", "»")] {
        if t.chars().count() > 2
            && t.starts_with(open)
            && t.ends_with(close)
            && !source.starts_with(open)
            && t[open.len()..t.len() - close.len()].find(close).is_none()
        {
            t = strip(&t[open.len()..t.len() - close.len()]).to_string();
        }
    }
    t
}

/// The model sometimes hedges the speaker's gender with "ค่ะ/ครับ". Keep
/// the particle the source uses; with none, drop the pair.
fn one_polite_particle(text: &str, source: &str) -> String {
    const PAIRS: [&str; 6] = [
        "ค่ะ/ครับ",
        "ครับ/ค่ะ",
        "คะ/ครับ",
        "ครับ/คะ",
        "ค่ะ / ครับ",
        "ครับ / ค่ะ",
    ];
    if !PAIRS.iter().any(|p| text.contains(p)) {
        return text.to_string();
    }
    let keep = if source.contains("ครับ") {
        "ครับ"
    } else if source.contains("ค่ะ") || source.contains("คะ") {
        "ค่ะ"
    } else {
        ""
    };
    let mut out = text.to_string();
    for pair in PAIRS {
        out = out.replace(pair, keep);
    }
    if keep.is_empty() {
        while out.contains("  ") {
            out = out.replace("  ", " ");
        }
        out = out.replace(" \n", "\n");
    }
    out
}

// MARK: Checks

/// Share of letters that are Thai (0 when there are no letters).
fn thai_share(text: &str) -> f64 {
    let letters: Vec<char> = text.chars().filter(|c| c.is_alphabetic()).collect();
    if letters.is_empty() {
        return 0.0;
    }
    letters.iter().filter(|c| is_thai(**c)).count() as f64 / letters.len() as f64
}

fn visible_len(text: &str) -> usize {
    text.chars().filter(|c| !c.is_whitespace()).count()
}

/// The model talking about the task, in any mode: meta framing, an AI
/// speaking as itself, a refusal of the task itself.
const META_VOICE: [&str; 27] = [
    "as an ai",
    "language model",
    "translation based on",
    "here is the translation",
    "here's the translation",
    "here is the english",
    "here's the english",
    "the translation is",
    "translated text",
    "edited text",
    "selected text",
    "i cannot translate",
    "i can't translate",
    "unable to translate",
    "cannot assist with",
    "can't assist with",
    "cannot fulfill",
    "can't fulfill",
    "please provide the text",
    "please provide the thai",
    "please provide the selected",
    "please provide the instruction",
    "ในฐานะ ai",
    "ในฐานะเอไอ",
    "ในฐานะผู้ช่วย",
    "ข้อความที่เลือก",
    "ข้อความที่แก้ไข",
];

/// Ordinary phrases that, in an edit within one language, mean the model
/// answered as an assistant when the selection never said them. A
/// translation produces them legitimately (ผมไปไม่ได้ → "I can't make it",
/// รบกวนส่งรายละเอียด → "Please provide the details"), so across languages
/// they don't count.
const ASSISTANT_PHRASES: [&str; 8] = [
    "please provide",
    "i understand the",
    "i'm sorry",
    "i am sorry",
    "i cannot",
    "i can't",
    "ขออภัย ฉัน",
    "ขออภัยค่ะ ฉัน",
];

/// How an assistant's reply opens ("Sure, I'll send it"): an answer to the
/// dictation, not its translation.
const REPLY_OPENERS: [&str; 10] = [
    "sure",
    "certainly",
    "of course",
    "absolutely",
    "no problem",
    "happy to help",
    "i'd be happy to",
    "i would be happy to",
    "i'll translate",
    "i will translate",
];

/// A source that itself opens by agreeing may be translated as "Sure, …".
const AGREEING_OPENERS: [&str; 18] = [
    "ได้",
    "แน่นอน",
    "โอเค",
    "ตกลง",
    "จัดไป",
    "ยินดี",
    "ไม่มีปัญหา",
    "ไม่เป็นไร",
    "เอาสิ",
    "เอาเลย",
    "ใช่",
    "ครับ",
    "ค่ะ",
    "ok",
    "okay",
    "sure",
    "yes",
    "yep",
];

/// Whether `text` opens with `word` as a whole word.
fn opens_with(text: &str, word: &str) -> bool {
    text.strip_prefix(word)
        .is_some_and(|rest| !rest.starts_with(|c: char| c.is_ascii_alphanumeric()))
}

/// The model speaking as an assistant instead of returning the user's text.
/// `cross_language` (a translation): ordinary first-person or polite English
/// is expected, so only meta framing and a reply's opener count.
fn assistant_voice(source: &str, out: &str, cross_language: bool) -> bool {
    let (s, o) = (lower(strip(source)), lower(strip(out)));
    let said = |p: &&str| o.contains(*p) && !s.contains(*p);
    if META_VOICE.iter().any(said) {
        return true;
    }
    if !cross_language {
        return ASSISTANT_PHRASES.iter().any(said);
    }
    REPLY_OPENERS.iter().any(|p| opens_with(&o, p))
        && !AGREEING_OPENERS.iter().any(|p| s.starts_with(p))
}

static NUMBER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[0-9๐-๙]+(?:[.,:][0-9๐-๙]+)*").unwrap());
static URLISH: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(?:https?://[^\s<>()]+[^\s<>().,!?]|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})",
    )
    .unwrap()
});
static CODE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?m)^\s*(?:SELECT|INSERT|UPDATE|DELETE|CREATE)\s+\S|^\s*(?:def|class|function|import|return)\s+\w|^\s*#include|;\s*$|\{\s*$|=>",
    )
    .unwrap()
});

static THOUSANDS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9]{1,3}(?:,[0-9]{3})+(?:[.:][0-9]+)*$").unwrap());

/// One written number in a canonical form, its parts kept in order so 1.2
/// and 2.1, or 14:30 and 30:14, stay different. Only equivalent spellings
/// meet: Thai digits read as Arabic (๑๒๐ = 120), thousands separators go
/// (340,000 = 340000), a time's `.` is its `:` (14.00 น. = 14:00), trailing
/// zero parts and leading zeros of the whole part go (14:00 = 14, 09 = 9).
fn number_key(token: &str) -> String {
    let mut parts: Vec<&str> = token.split(['.', ':']).collect();
    while parts.len() > 1 && parts.last().is_some_and(|p| p.chars().all(|c| c == '0')) {
        parts.pop();
    }
    let whole = parts[0].trim_start_matches('0');
    let whole = if whole.is_empty() { "0" } else { whole };
    std::iter::once(whole)
        .chain(parts[1..].iter().copied())
        .collect::<Vec<_>>()
        .join(":")
}

/// The numbers a text writes, in order, as `number_key`s. A comma outside
/// thousands grouping separates numbers (1,2,3 is three of them).
fn numbers(text: &str) -> Vec<String> {
    let mut all = Vec::new();
    for m in NUMBER.find_iter(text) {
        let token: String = m
            .as_str()
            .chars()
            .map(|c| match c {
                '๐'..='๙' => char::from_digit(c as u32 - '๐' as u32, 10).unwrap(),
                other => other,
            })
            .collect();
        if THOUSANDS.is_match(&token) {
            all.push(number_key(&token.replace(',', "")));
        } else {
            all.extend(token.split(',').filter(|p| !p.is_empty()).map(number_key));
        }
    }
    all
}

/// Numbers the source states: written digits plus spoken Thai numbers
/// (สามสิบ → 30) that the model may legitimately write as digits.
fn source_numbers(source: &str) -> HashSet<String> {
    let mut all: HashSet<String> = numbers(source).into_iter().collect();
    all.extend(numbers(&apply_thai_format(source).0));
    all
}

/// A whole number up to 12, which an output may add: "three" and "3", list
/// numbering, "9 a.m." or 09:00 for เก้าโมง.
fn is_small(key: &str) -> bool {
    !key.contains(':') && key.len() <= 2 && key.parse::<u32>().is_ok_and(|v| v <= 12)
}

/// A Thai clock-time phrase after `apply_thai_format`, which writes numbers
/// of two or more syllables as digits but leaves one-syllable ones (เก้า,
/// ห้า) as words. Branches, in the order they're tried at one position:
/// บ่าย(N)โมง, เที่ยงคืน, เที่ยง, ตีN, Nทุ่ม, Nนาฬิกา, Nโมง(เช้า|เย็น); each
/// optionally followed by "M นาที" or ครึ่ง.
static SPOKEN_TIME: LazyLock<Regex> = LazyLock::new(|| {
    const N: &str = "[0-9]{1,2}|หนึ่ง|สอง|สาม|สี่|ห้า|หก|เจ็ด|แปด|เก้า";
    Regex::new(&format!(
        r"(?:บ่าย\s*(?P<pm>{N})?\s*โมง|(?P<midnight>เที่ยงคืน)|(?P<noon>เที่ยง)|ตี\s*(?P<ti>{N})|(?P<thum>{N})\s*ทุ่ม|(?P<clock>{N})\s*นาฬิกา|(?P<mong>{N})\s*โมง\s*(?P<part>เช้า|เย็น)?)(?:\s*ตรง)?(?:\s*(?:(?P<min>{N})\s*นาที|(?P<half>ครึ่ง)))?"
    ))
    .unwrap()
});

fn thai_small_number(word: &str) -> Option<u32> {
    const WORDS: [&str; 9] = ["หนึ่ง", "สอง", "สาม", "สี่", "ห้า", "หก", "เจ็ด", "แปด", "เก้า"];
    word.parse()
        .ok()
        .or_else(|| WORDS.iter().position(|w| *w == word).map(|i| i as u32 + 1))
}

/// The clock times the source says in words (เก้าโมงสิบนาที → 9:10, บ่ายสาม
/// โมงครึ่ง → 15:30, also as 3:30), as `number_key`s. Only these exempt a
/// written time from `numberInvented`: the hour and the minutes both have to
/// be the ones said, and a quantity elsewhere can't supply the minutes.
fn spoken_times(source: &str) -> HashSet<String> {
    let formatted = apply_thai_format(source).0;
    let num =
        |c: &regex::Captures, name: &str| c.name(name).and_then(|m| thai_small_number(m.as_str()));
    let mut keys = HashSet::new();
    for c in SPOKEN_TIME.captures_iter(&formatted) {
        let hours: Vec<u32> = if c.name("pm").is_some() || c[0].starts_with("บ่าย") {
            vec![12 + num(&c, "pm").unwrap_or(1)]
        } else if c.name("midnight").is_some() {
            vec![0]
        } else if c.name("noon").is_some() {
            vec![12]
        } else if let Some(h) = num(&c, "ti") {
            vec![h]
        } else if let Some(h) = num(&c, "thum") {
            vec![18 + h]
        } else if let Some(h) = num(&c, "clock") {
            vec![h]
        } else if let Some(h) = num(&c, "mong") {
            match c.name("part").map(|m| m.as_str()) {
                Some("เย็น") => vec![h + 12],
                Some(_) => vec![h],
                // Plain N โมง: morning, or the evening for 1–6 (สองโมง = 14:00 too).
                None => vec![h, h + 12],
            }
        } else {
            continue;
        };
        let minutes = if c.name("half").is_some() {
            30
        } else {
            num(&c, "min").unwrap_or(0)
        };
        if minutes > 59 {
            continue;
        }
        for h in hours.into_iter().filter(|h| *h <= 24) {
            // The 24-hour form and the 12-hour one an English sentence uses.
            let twelve = match h % 12 {
                0 => 12,
                x => x,
            };
            for hour in [h, twelve] {
                keys.insert(number_key(&format!("{hour}:{minutes:02}")));
            }
        }
    }
    keys
}

/// Numbers in `out` that the source never stated, small ones aside. By
/// value: restating a figure the source gives (an email's subject and body)
/// invents nothing.
fn invented_numbers(source: &str, out: &str) -> Vec<String> {
    let have = source_numbers(source);
    let times = spoken_times(source);
    let mut invented: Vec<String> = numbers(out)
        .into_iter()
        .filter(|n| !have.contains(n) && !is_small(n) && !times.contains(n))
        .collect();
    invented.sort();
    invented.dedup();
    invented
}

/// Written numbers in the source missing from `out`, counted: a number the
/// source writes twice must appear twice.
fn lost_numbers(source: &str, out: &str) -> Vec<String> {
    let mut have = numbers(out);
    let mut lost = Vec::new();
    for n in numbers(source) {
        match have.iter().position(|h| *h == n) {
            Some(i) => {
                have.swap_remove(i);
            }
            None => lost.push(n),
        }
    }
    lost.sort();
    lost
}

/// URLs and email addresses must come through byte for byte.
fn lost_addresses(source: &str, out: &str) -> bool {
    URLISH.find_iter(source).any(|m| !out.contains(m.as_str()))
}

const THAI_QUESTION_ENDINGS: [&str; 9] = [
    "ไหม",
    "มั้ย",
    "มั๊ย",
    "หรือเปล่า",
    "รึเปล่า",
    "หรือยัง",
    "หรือไม่",
    "ป่ะ",
    "เหรอ",
];
const THAI_QUESTION_WORDS: [&str; 15] = [
    "อะไร",
    "ผู้ใด",
    "เหตุใด",
    "ที่ใด",
    "เมื่อใด",
    "ใดบ้าง",
    "ยังไง",
    "อย่างไร",
    "ทำไม",
    "เมื่อไร",
    "เมื่อไหร่",
    "ที่ไหน",
    "ใคร",
    "กี่",
    "ได้ไหม",
];
const THAI_POLITE_ENDINGS: [&str; 6] = ["ครับ", "คะ", "ค่ะ", "นะ", "จ๊ะ", "จ้ะ"];
const ENGLISH_QUESTION_STARTS: [&str; 20] = [
    "could", "can", "would", "will", "do", "does", "did", "is", "are", "was", "were", "what",
    "how", "why", "when", "where", "who", "which", "should", "may",
];

/// Question markers that stay interrogative wherever they appear.
const THAI_QUESTION_PHRASES: [&str; 6] = ["ได้ไหม", "ได้มั้ย", "หรือเปล่า", "รึเปล่า", "หรือยัง", "หรือไม่"];

/// A question by its punctuation, a question phrase, or a question word that
/// opens the text or its last clause, or ends it. A question word in the
/// middle is usually not one: ถ้ามีอะไรด่วน is "if anything is urgent".
fn is_question(text: &str) -> bool {
    let t = strip(text);
    if t.contains('?') || THAI_QUESTION_PHRASES.iter().any(|q| t.contains(q)) {
        return true;
    }
    let mut end = t.trim_end_matches(|c: char| !c.is_alphanumeric());
    loop {
        let before = end;
        for p in THAI_POLITE_ENDINGS {
            end = end.trim_end_matches(p).trim_end();
        }
        if end == before {
            break;
        }
    }
    let last = end.rsplit(char::is_whitespace).next().unwrap_or(end);
    THAI_QUESTION_ENDINGS.iter().any(|q| end.ends_with(q))
        || THAI_QUESTION_WORDS
            .iter()
            .any(|q| end.ends_with(q) || t.starts_with(q) || last.starts_with(q))
}

/// Whether a rewrite still asks something.
fn still_asks(out: &str) -> bool {
    if out.contains('?') || is_question(out) {
        return true;
    }
    let first = lower(strip(out))
        .split(|c: char| !c.is_alphanumeric())
        .find(|w| !w.is_empty())
        .map(str::to_string)
        .unwrap_or_default();
    ENGLISH_QUESTION_STARTS.contains(&first.as_str())
        || THAI_QUESTION_WORDS.iter().any(|q| out.contains(q))
}

/// Content words for the grounding check: Thai words and Latin words of two
/// or more letters, lowercased.
fn content_words(text: &str) -> HashSet<String> {
    word_tokenize(&lower(text), false)
        .into_iter()
        .map(|w| strip(&w).to_string())
        .filter(|w| w.chars().filter(|c| c.is_alphabetic()).count() >= 2)
        .collect()
}

/// Share of `from`'s content words that occur anywhere in `within` (spaces
/// ignored), so a word kept inside a longer one counts: ช้า in ล่าช้า.
fn found_in(from: &str, within: &str) -> f64 {
    let words = content_words(from);
    if words.is_empty() {
        return 0.0;
    }
    let hay = remove_ws(&lower(within));
    words.iter().filter(|w| hay.contains(w.as_str())).count() as f64 / words.len() as f64
}

/// (recall, precision): how much of the source the output keeps, and how
/// much of the output comes from the source.
fn overlap(source: &str, out: &str) -> (f64, f64) {
    (found_in(source, out), found_in(out, source))
}

fn has_code_fence(text: &str) -> bool {
    text.contains("```")
}

/// Code the source did not contain: the model wrote what the text asked for.
fn invented_code(source: &str, out: &str) -> bool {
    (has_code_fence(out) && !has_code_fence(source))
        || (CODE.is_match(out) && !CODE.is_match(source))
}

/// Latin spans lost from `source`. In mostly-English text only names, terms
/// and code count (ordinary words may be reworded): a span with a capital
/// after its first letter, a digit or a joiner, or a capitalised word that
/// does not start a sentence. In Thai text every English word is a term.
fn lost_terms(source: &str, out: &str, repair: bool) -> Vec<String> {
    let lost = lost_spans(source, out, repair);
    if thai_share(source) >= 0.3 {
        return lost;
    }
    let named = named_spans(source);
    lost.into_iter().filter(|s| named.contains(s)).collect()
}

fn named_spans(text: &str) -> HashSet<String> {
    let mut named = HashSet::new();
    for m in crate::gate::LATIN_SPAN_RE.find_iter(text) {
        let span = m.as_str();
        let before = text[..m.start()].trim_end();
        let sentence_start = before.is_empty() || before.ends_with(['.', '!', '?', ':', '\n']);
        let inner_capital = span.chars().skip(1).any(|c| c.is_ascii_uppercase());
        let marked = span
            .chars()
            .any(|c| c.is_ascii_digit() || "/._+-".contains(c));
        let capitalised = span.starts_with(|c: char| c.is_ascii_uppercase());
        if inner_capital || marked || (capitalised && !sentence_start) {
            named.insert(span.to_string());
        }
    }
    named
}

/// Checks shared by both modes, in order of how bad the failure is.
fn common_checks(source: &str, out: &str, cross_language: bool) -> Result<(), Rejection> {
    if is_blank(out) {
        return Err(Rejection("empty"));
    }
    if assistant_voice(source, out, cross_language) {
        return Err(Rejection("assistant"));
    }
    if invented_code(source, out) {
        return Err(Rejection("code"));
    }
    if lost_addresses(source, out) {
        return Err(Rejection("addressLost"));
    }
    Ok(())
}

/// Command mode: does `out` look like `source` edited as `instruction` asks?
pub fn check_command(instruction: &str, source: &str, out: &str) -> Result<(), Rejection> {
    let intent = Intent::of(instruction);
    common_checks(
        source,
        out,
        matches!(intent, Intent::ToEnglish | Intent::ToThai),
    )?;
    let (s_len, o_len) = (visible_len(source) as f64, visible_len(out) as f64);
    let (low, high) = match intent {
        Intent::Shorten => (0.05 * s_len, 1.1 * s_len + 10.0),
        Intent::Expand => (0.5 * s_len, 4.0 * s_len + 400.0),
        Intent::ToEnglish | Intent::ToThai => (0.3 * s_len, 3.5 * s_len + 40.0),
        Intent::Edit => (0.4 * s_len, 2.0 * s_len + 60.0),
    };
    if o_len < low {
        return Err(Rejection("tooShort"));
    }
    if o_len > high {
        return Err(Rejection("tooLong"));
    }
    // Language: kept unless the instruction asks for another one.
    let (s_thai, o_thai) = (thai_share(source), thai_share(out));
    match intent {
        Intent::ToEnglish if o_thai > 0.1 => return Err(Rejection("notEnglish")),
        Intent::ToThai if o_thai < 0.3 => return Err(Rejection("notThai")),
        Intent::ToEnglish | Intent::ToThai => {}
        _ if s_thai >= 0.3 && o_thai < 0.15 => return Err(Rejection("language")),
        _ if s_thai == 0.0 && o_thai > 0.1 => return Err(Rejection("language")),
        _ => {}
    }
    // Terms, names and code (Latin spans) survive, except into Thai. A
    // summary may drop some; a typo fix may repair one.
    if intent != Intent::ToThai {
        let spans = latin_spans(source).len();
        let lost = lost_terms(source, out, fixes_spelling(instruction)).len();
        let allowed = if intent == Intent::Shorten {
            spans / 2
        } else {
            0
        };
        if lost > allowed {
            return Err(Rejection("termLost"));
        }
    }
    if intent != Intent::Shorten && !lost_numbers(source, out).is_empty() {
        return Err(Rejection("numberLost"));
    }
    if !invented_numbers(source, out).is_empty() {
        return Err(Rejection("numberInvented"));
    }
    // Grounding: an edit keeps most of the source's words; a summary is
    // made of them. Answering the text, or following an instruction inside
    // it, fails both. Skipped across languages.
    if !matches!(intent, Intent::ToEnglish | Intent::ToThai) {
        let (recall, precision) = overlap(source, out);
        // Formal and casual rewrites swap much of the vocabulary
        // (ขอโทษ → ขออภัย), so the bar for an edit is low; a summary must
        // still be built from the source's words.
        let grounded = match intent {
            Intent::Shorten => precision >= 0.4,
            _ => recall >= 0.3,
        };
        if !grounded {
            return Err(Rejection("ungrounded"));
        }
    }
    if matches!(intent, Intent::Edit | Intent::ToEnglish | Intent::ToThai)
        && is_question(source)
        && !still_asks(out)
    {
        return Err(Rejection("answered"));
    }
    Ok(())
}

/// Translation mode: is `out` an English rendering of `source`?
pub fn check_translation(source: &str, out: &str) -> Result<(), Rejection> {
    common_checks(source, out, true)?;
    if thai_share(out) > 0.1 {
        return Err(Rejection("notEnglish"));
    }
    let (s_len, o_len) = (visible_len(source) as f64, visible_len(out) as f64);
    if o_len < 0.3 * s_len {
        return Err(Rejection("tooShort"));
    }
    if o_len > 3.5 * s_len + 40.0 {
        return Err(Rejection("tooLong"));
    }
    if !lost_terms(source, out, false).is_empty() {
        return Err(Rejection("termLost"));
    }
    if !lost_numbers(source, out).is_empty() {
        return Err(Rejection("numberLost"));
    }
    if !invented_numbers(source, out).is_empty() {
        return Err(Rejection("numberInvented"));
    }
    if is_question(source) && !still_asks(out) {
        return Err(Rejection("answered"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Fixed(&'static str);
    impl Generate for Fixed {
        fn generate(&self, _: &str, _: u32) -> Result<Generation, LlmError> {
            Ok(Generation::finished(self.0))
        }
    }
    /// Still writing when it reached the token limit.
    struct CutOff(&'static str);
    impl Generate for CutOff {
        fn generate(&self, _: &str, _: u32) -> Result<Generation, LlmError> {
            Ok(Generation {
                text: self.0.to_string(),
                finished: false,
            })
        }
    }
    struct Failing;
    impl Generate for Failing {
        fn generate(&self, _: &str, _: u32) -> Result<Generation, LlmError> {
            Err(LlmError("timeout".into()))
        }
    }
    /// Records what the model was asked, and answers with the source.
    #[derive(Default)]
    struct Recording(RefCell<Vec<(String, u32)>>);
    impl Generate for Recording {
        fn generate(&self, content: &str, max_tokens: u32) -> Result<Generation, LlmError> {
            self.0.borrow_mut().push((content.to_string(), max_tokens));
            Ok(Generation::finished("ok"))
        }
    }

    fn command<'a>(instruction: &'a str, text: &'a str) -> Request<'a> {
        Request {
            mode: Mode::Command,
            instruction,
            text,
            template: None,
        }
    }
    fn translate(text: &str) -> Request<'_> {
        Request {
            mode: Mode::Translate,
            instruction: "",
            text,
            template: None,
        }
    }

    #[test]
    fn intents_from_thai_and_english_instructions() {
        assert_eq!(Intent::of("ทำให้สุภาพขึ้น"), Intent::Edit);
        assert_eq!(Intent::of("สั้นลง"), Intent::Shorten);
        assert_eq!(Intent::of("สรุปเป็น bullet"), Intent::Shorten);
        assert_eq!(Intent::of("เขียนเป็นอีเมล"), Intent::Expand);
        assert_eq!(Intent::of("แปลเป็นภาษาอังกฤษ"), Intent::ToEnglish);
        assert_eq!(Intent::of("แปลเป็นภาษาไทย"), Intent::ToThai);
        assert_eq!(Intent::of("Make it shorter"), Intent::Shorten);
        assert_eq!(Intent::of("แก้คำผิด"), Intent::Edit);
        assert!(fixes_spelling("แก้คำผิด"));
        assert!(!fixes_spelling("ทำให้สุภาพขึ้น"));
    }

    #[test]
    fn prompt_carries_instruction_and_text_once() {
        let req = command("ทำให้สุภาพขึ้น", "  ส่งไฟล์มาด่วน  ");
        let content = req.content();
        assert!(content.contains("INSTRUCTION: ทำให้สุภาพขึ้น\n"));
        assert!(content.contains("SELECTED TEXT:\nส่งไฟล์มาด่วน\nEND OF SELECTED TEXT"));
        assert!(!content.contains("{text}") && !content.contains("{instruction}"));
        let content = translate("พรุ่งนี้ประชุม").content();
        assert!(content.ends_with("THAI: พรุ่งนี้ประชุม\nENGLISH:"));
    }

    #[test]
    fn generation_budget_grows_with_the_task() {
        let text = "ก".repeat(400);
        let shorter = command("สั้นลง", &text).max_tokens();
        let email = command("เขียนเป็นอีเมล", &text).max_tokens();
        assert!(shorter < email);
        assert_eq!(email, MAX_GENERATION_TOKENS.min(email));
        assert_eq!(command("สั้นลง", "สั้น").max_tokens(), 82);
        let long = "ก".repeat(MAX_SOURCE_CHARS);
        assert_eq!(
            command("เขียนเป็นอีเมล", &long).max_tokens(),
            MAX_GENERATION_TOKENS
        );
    }

    #[test]
    fn bad_input_never_reaches_the_model() {
        let model = Recording::default();
        for (req, flag) in [
            (command("สั้นลง", ""), "emptySelection"),
            (command("สั้นลง", "   \n"), "emptySelection"),
            (command("", "ส่งไฟล์มา"), "noInstruction"),
            (translate("Let's sync after lunch"), "noThai"),
        ] {
            let out = transform(&req, &model);
            assert_eq!((out.applied, out.flag.as_str()), (false, flag));
            assert_eq!(out.text, req.text);
        }
        let long = "ก".repeat(MAX_SOURCE_CHARS + 1);
        let out = transform(&command("สั้นลง", &long), &model);
        assert_eq!((out.applied, out.flag.as_str()), (false, "tooLong"));
        assert!(model.0.borrow().is_empty());
    }

    #[test]
    fn a_failed_or_rejected_transform_keeps_the_original() {
        let source = "ทำไม build บน CI ถึงพังทุกครั้งที่ push ขึ้น main";
        let out = transform(&command("ทำให้สุภาพขึ้น", source), &Failing);
        assert_eq!((out.applied, out.flag.as_str()), (false, "llmError"));
        assert_eq!(out.text, source);
        // An answer to the question instead of the politer question.
        let answer = Fixed(
            "build บน CI พังเพราะ cache ของ dependency ไม่ตรงกับ lockfile ให้ลบ cache แล้ว push ขึ้น main ใหม่",
        );
        let out = transform(&command("ทำให้สุภาพขึ้น", source), &answer);
        assert!(!out.applied);
        assert_eq!(out.text, source);
        assert!(out.raw.is_some());
    }

    #[test]
    fn a_good_rewrite_is_applied_after_cleaning() {
        let source = "ส่งไฟล์ deck มาด่วนเลย ลูกค้าจะเอาบ่ายนี้";
        let model = Fixed(
            "EDITED TEXT: รบกวนช่วยส่งไฟล์ deck มาให้หน่อยนะครับ ลูกค้าต้องการภายในบ่ายนี้ครับ<end_of_turn>",
        );
        let out = transform(&command("ทำให้สุภาพขึ้น", source), &model);
        assert_eq!(out.flag, "ok");
        assert!(out.applied);
        assert_eq!(
            out.text,
            "รบกวนช่วยส่งไฟล์ deck มาให้หน่อยนะครับ ลูกค้าต้องการภายในบ่ายนี้ครับ"
        );
    }

    #[test]
    fn cleaning_drops_wrappers_but_not_content() {
        let src = "ส่งไฟล์มา";
        assert_eq!(
            clean_generation("\"รบกวนส่งไฟล์มาครับ\"", src),
            "รบกวนส่งไฟล์มาครับ"
        );
        assert_eq!(
            clean_generation("“รบกวนส่งไฟล์มาครับ”", src),
            "รบกวนส่งไฟล์มาครับ"
        );
        assert_eq!(
            clean_generation("Here is a more polite version:\nรบกวนส่งไฟล์มาครับ", src),
            "รบกวนส่งไฟล์มาครับ"
        );
        assert_eq!(clean_generation("```\n- a\n- b\n```", src), "- a\n- b");
        assert_eq!(clean_generation("```text\n- a\n- b\n```", src), "- a\n- b");
        // Bullets and paragraphs survive (no cut at a blank line).
        assert_eq!(
            clean_generation("เรียนคุณต้น\n\nขอลาป่วยครับ\n\nขอบคุณครับ", src),
            "เรียนคุณต้น\n\nขอลาป่วยครับ\n\nขอบคุณครับ"
        );
        // A quote inside is not a wrapper.
        assert_eq!(clean_generation("\"a\" and \"b\"", src), "\"a\" and \"b\"");
        // The model running on into the template is cut.
        assert_eq!(
            clean_generation("Hello.\nTHAI: สวัสดี\nENGLISH: Hi", src),
            "Hello."
        );
    }

    #[test]
    fn command_checks_terms_numbers_and_addresses() {
        let src = "ยอดขายเดือนนี้ 1.2 ล้านบาท โตขึ้น 15% แต่ค่าโฆษณาบน Facebook เพิ่มเป็น 340,000 บาท";
        let formal = "ยอดขายประจำเดือนนี้อยู่ที่ 1.2 ล้านบาท เติบโตขึ้นร้อยละ 15 อย่างไรก็ตาม ค่าโฆษณาบน Facebook เพิ่มขึ้นเป็น 340,000 บาท";
        assert_eq!(check_command("ทางการขึ้น", src, formal), Ok(()));
        let no_term = formal.replace("Facebook", "เฟซบุ๊ก");
        assert_eq!(
            check_command("ทางการขึ้น", src, &no_term),
            Err(Rejection("termLost"))
        );
        let lost = formal.replace("340,000", "สามแสนสี่หมื่น");
        assert_eq!(
            check_command("ทางการขึ้น", src, &lost),
            Err(Rejection("numberLost"))
        );
        let invented = format!("{formal} คาดว่าเดือนหน้าจะถึง 2 ล้านบาท หรือ 2,500,000 บาท");
        assert_eq!(
            check_command("ทางการขึ้น", src, &invented),
            Err(Rejection("numberInvented"))
        );
        let src = "ส่งรายละเอียดมาที่ hr@example.com ได้เลย";
        assert_eq!(
            check_command("ทางการขึ้น", src, "กรุณาส่งรายละเอียดมาที่ hr@example.co ได้เลยครับ"),
            Err(Rejection("addressLost"))
        );
    }

    #[test]
    fn command_checks_follow_the_intent() {
        let src = "วันนี้ประชุมกับทีม data เรื่อง pipeline ใหม่ สรุปว่าจะย้ายจาก Airflow ไป Dagster ภายในไตรมาสหน้า แต่ต้องเขียน test ให้ครบก่อน แล้วก็ต้องคุยกับทีม infra เรื่อง cost ด้วย";
        let summary =
            "- ทีม data จะย้าย pipeline จาก Airflow ไป Dagster ไตรมาสหน้า\n- ต้องเขียน test ให้ครบก่อน";
        assert_eq!(check_command("สรุปเป็น bullet", src, summary), Ok(()));
        // "Shorter" that grew is rejected; so is a translation nobody asked for.
        let longer = format!("{src} ซึ่งเป็นเรื่องสำคัญมากสำหรับทุกคนในทีมของเราในตอนนี้และอนาคต");
        assert_eq!(
            check_command("สั้นลง", src, &longer),
            Err(Rejection("tooLong"))
        );
        let english = "The data team will move the pipeline from Airflow to Dagster next quarter, after writing tests and discussing cost with infra.";
        assert_eq!(
            check_command("สั้นลง", src, english),
            Err(Rejection("language"))
        );
        assert_eq!(check_command("แปลเป็นภาษาอังกฤษ", src, english), Ok(()));
        // A typo fix may repair a misspelled English word.
        assert_eq!(
            check_command(
                "แก้คำผิด",
                "ลูกค้าอยากได้ dashbaord ที่โชว์ยอดขายรายวัน",
                "ลูกค้าอยากได้ dashboard ที่โชว์ยอดขายรายวัน"
            ),
            Ok(())
        );
    }

    #[test]
    fn command_rejects_answers_and_followed_instructions() {
        let q = "ใครเป็นคนลบ database ตัว staging เมื่อคืน";
        assert_eq!(
            check_command(
                "ทางการขึ้น",
                q,
                "ขอทราบว่าผู้ใดเป็นผู้ลบ database ของ staging เมื่อคืนนี้ครับ"
            ),
            Ok(())
        );
        assert_eq!(
            check_command(
                "ทางการขึ้น",
                q,
                "database ตัว staging ถูกลบเมื่อคืนโดยทีม infra ระหว่างการย้ายระบบ"
            ),
            Err(Rejection("answered"))
        );
        let ask = "เขียน function Python ที่เรียงลำดับ list ให้หน่อย";
        let code = "```python\ndef sort_list(items):\n    return sorted(items)\n```";
        assert!(check_command("ทำให้สุภาพขึ้น", ask, code).is_err());
        let followed = "def sort_list(items): return sorted(items) # function Python list";
        assert!(check_command("ทำให้สุภาพขึ้น", ask, followed).is_err());
        assert_eq!(
            check_command(
                "ทำให้สุภาพขึ้น",
                ask,
                "รบกวนช่วยเขียน function Python ที่เรียงลำดับ list ให้หน่อยได้ไหมครับ"
            ),
            Ok(())
        );
        assert_eq!(
            check_command(
                "ทำให้สุภาพขึ้น",
                "ส่งไฟล์มา",
                "As an AI, I cannot send files. รบกวนส่งไฟล์มาครับ"
            ),
            Err(Rejection("assistant"))
        );
    }

    #[test]
    fn translation_checks() {
        let src = "ช่วย review PR ที่ผมเปิดไว้เมื่อเช้าหน่อยได้ไหมครับ";
        assert_eq!(
            check_translation(src, "Could you review the PR I opened this morning?"),
            Ok(())
        );
        // A reply, not a translation: refused for opening like one.
        assert_eq!(
            check_translation(src, "Sure, I'll review your PR this afternoon."),
            Err(Rejection("assistant"))
        );
        assert_eq!(
            check_translation(src, "I'll review your PR this afternoon."),
            Err(Rejection("answered"))
        );
        assert_eq!(
            check_translation(src, "ช่วย review PR หน่อยครับ"),
            Err(Rejection("notEnglish"))
        );
        assert_eq!(
            check_translation(
                src,
                "Could you review the pull request I opened this morning?"
            ),
            Err(Rejection("termLost"))
        );
        let src = "ตอนนี้ memory ของ pod ขึ้นไปถึง 95% แล้ว";
        assert_eq!(
            check_translation(src, "The pod's memory is now up to 95%."),
            Ok(())
        );
        assert_eq!(
            check_translation(src, "The pod's memory is now up to 59%."),
            Err(Rejection("numberLost"))
        );
        // Spoken Thai numbers may become digits.
        assert_eq!(
            check_translation(
                "ตอนนี้ CI ใช้เวลารันประมาณยี่สิบนาที",
                "CI currently takes about 20 minutes to run."
            ),
            Ok(())
        );
    }

    #[test]
    fn translation_through_transform() {
        let out = transform(
            &translate("เดี๋ยวผม deploy ตัว hotfix ขึ้น production ตอนห้าโมงนะครับ"),
            &Fixed("I'll deploy the hotfix to production at 5 p.m.\n\nTHAI: x"),
        );
        assert!(out.applied, "{}", out.flag);
        assert_eq!(out.text, "I'll deploy the hotfix to production at 5 p.m.");
        let out = transform(
            &translate("เขียน SQL query ที่ดึงลูกค้าที่ซื้อมากกว่าสามครั้ง"),
            &Fixed("```sql\nSELECT customer_id FROM orders GROUP BY 1 HAVING COUNT(*) > 3;\n```"),
        );
        assert!(!out.applied);
        assert_eq!(out.text, "เขียน SQL query ที่ดึงลูกค้าที่ซื้อมากกว่าสามครั้ง");
    }

    /// An answer cut off at the token limit is refused even when its first
    /// part would pass every check: it would replace the whole text.
    #[test]
    fn an_answer_cut_off_at_the_token_limit_is_never_applied() {
        let src = "ส่งไฟล์ deck มาด่วนเลย ลูกค้าจะเอาบ่ายนี้ แล้วก็ช่วยเช็ค budget ของเดือนหน้าด้วย ถ้ามีปัญหาอะไรโทรหาผมได้เลย";
        let cut =
            "รบกวนช่วยส่งไฟล์ deck มาให้หน่อยนะครับ ลูกค้าต้องการภายในบ่ายนี้ครับ นอกจากนี้รบกวนช่วยตรวจสอบ budget";
        assert_eq!(check_command("ทำให้สุภาพขึ้น", src, cut), Ok(()));
        let out = transform(&command("ทำให้สุภาพขึ้น", src), &CutOff(cut));
        assert_eq!((out.applied, out.flag.as_str()), (false, "unfinished"));
        assert_eq!(out.text, src, "the selection stays as it was");
        assert_eq!(out.raw.as_deref(), Some(cut));

        let src = "ช่วยส่ง deck กับ budget ให้ทีม marketing ก่อนพรุ่งนี้เช้านะครับ เพราะลูกค้าอยากเห็นตัวเลขทั้งหมดก่อนประชุม และจะถามเรื่องแผนของไตรมาสหน้าด้วย";
        let cut = "Please send the deck and budget to the marketing team before tomorrow morning, because the client wants to see all the figures before the";
        assert_eq!(check_translation(src, cut), Ok(()));
        let out = transform(&translate(src), &CutOff(cut));
        assert_eq!((out.applied, out.flag.as_str()), (false, "unfinished"));
        assert_eq!(out.text, src, "the transcript is pasted instead");
        // The same words, ended by the model, are a translation.
        assert!(transform(&translate(src), &Fixed(cut)).applied);
        // So is an answer the model ended with a template marker before
        // running on into the limit.
        let out = transform(
            &translate(src),
            &CutOff(
                "Please send the deck and budget to the marketing team before tomorrow morning.\nTHAI: ช่วยส่ง",
            ),
        );
        assert!(out.applied, "{}", out.flag);
        assert_eq!(
            out.text,
            "Please send the deck and budget to the marketing team before tomorrow morning."
        );
    }

    #[test]
    fn english_text_may_be_reworded_but_names_stay() {
        let src = "hey can u send me the slides from yesterday, need them asap";
        assert_eq!(
            check_command(
                "ทำให้สุภาพขึ้น",
                src,
                "Could you please send me the slides from yesterday? I need them as soon as possible."
            ),
            Ok(())
        );
        let src = "Please ask Somchai to update the README before we merge into main.";
        assert_eq!(
            check_command(
                "make it more polite",
                src,
                "Could you kindly ask Somchai to update the readme file before we merge it?"
            ),
            Ok(())
        );
        assert_eq!(
            check_command(
                "make it more polite",
                src,
                "Could you kindly ask him to update the documentation before we merge it?"
            ),
            Err(Rejection("termLost"))
        );
    }

    #[test]
    fn register_changes_are_grounded_answers_are_not() {
        assert_eq!(
            check_command(
                "เขียนให้เป็นทางการ",
                "งานนี้แอบช้าไปหน่อยนะ ขอโทษจริงๆ เดี๋ยวรีบปั่นให้เสร็จ",
                "ขออภัยที่งานนี้ล่าช้า ขออนุญาตดำเนินการให้เสร็จโดยเร็วที่สุด"
            ),
            Ok(())
        );
        assert_eq!(
            check_command(
                "ทำให้สุภาพขึ้น",
                "ช่วยสรุปข่าวเศรษฐกิจวันนี้ให้หน่อย",
                "วันนี้ตลาดหุ้นปรับตัวลดลงเล็กน้อย นักลงทุนจับตาการประชุมธนาคารกลางสัปดาห์หน้า"
            ),
            Err(Rejection("ungrounded"))
        );
    }

    #[test]
    fn hedged_polite_particles_become_one() {
        assert_eq!(
            clean_generation("รบกวนส่งไฟล์มาด้วยค่ะ/ครับ", "ส่งไฟล์มาครับ"),
            "รบกวนส่งไฟล์มาด้วยครับ"
        );
        assert_eq!(
            clean_generation("รบกวนส่งไฟล์มาด้วยค่ะ/ครับ", "ส่งไฟล์มาค่ะ"),
            "รบกวนส่งไฟล์มาด้วยค่ะ"
        );
        assert_eq!(
            clean_generation("รบกวนส่งไฟล์มาด้วยครับ/ค่ะ", "ส่งไฟล์มา"),
            "รบกวนส่งไฟล์มาด้วย"
        );
        assert_eq!(
            clean_generation("เรียน ทีม Acme ครับ/ค่ะ ขอเลื่อน demo", "ขอเลื่อน demo กับทีม Acme"),
            "เรียน ทีม Acme ขอเลื่อน demo"
        );
    }

    #[test]
    fn numbers_compare_by_value() {
        assert_eq!(
            lost_numbers("ประชุม 14.00 น.", "ประชุมเวลา 14:00"),
            Vec::<String>::new()
        );
        assert_eq!(
            lost_numbers("งบ 340,000 บาท", "budget 340000 baht"),
            Vec::<String>::new()
        );
        assert_eq!(lost_numbers("งบ ๑๒๐ บาท", "120 baht"), Vec::<String>::new());
        assert_eq!(
            invented_numbers("ตีหนึ่งถึงตีสาม", "01:00–03:00"),
            Vec::<String>::new()
        );
        assert_eq!(
            invented_numbers("ห้าโมง", "at 2026"),
            vec!["2026".to_string()]
        );
    }

    #[test]
    fn spoken_times_may_be_written_as_clock_times() {
        let none = Vec::<String>::new();
        let invented = |s: &str, o: &str| invented_numbers(s, o);
        assert_eq!(
            invented("ประชุมตอนเก้าโมงสิบนาที", "The meeting is at 9:10."),
            none
        );
        assert_eq!(
            invented("ประชุมตอนเก้าโมงครึ่ง", "The meeting is at 9:30."),
            none
        );
        assert_eq!(invented("ประชุมตอนบ่ายสามโมงสิบห้านาที", "at 15:15"), none);
        assert_eq!(invented("ประชุมตอนบ่ายสามโมงสิบห้านาที", "at 3:15 p.m."), none);
        assert_eq!(invented("นัดสองทุ่มครึ่ง", "at 8:30 p.m."), none);
        assert_eq!(invented("นัดสองทุ่มครึ่ง", "at 20:30"), none);
        assert_eq!(invented("ตื่นตีห้ายี่สิบนาที", "Up at 5:20."), none);
        assert_eq!(invented("ประชุม 14 นาฬิกา 30 นาที", "at 14:30"), none);
        // The hour and the minutes both have to be the ones said.
        assert_eq!(
            invented("ประชุมตอนเก้าโมงสิบนาที", "at 8:10"),
            vec!["8:10".to_string()]
        );
        assert_eq!(
            invented("ประชุมตอนเก้าโมงสิบนาที", "at 9:20"),
            vec!["9:20".to_string()]
        );
        // A quantity elsewhere can't supply the minutes.
        assert_eq!(
            invented("ซื้อของ 10 ชิ้น ตอนเก้าโมง", "Bought 10 items at 9:10."),
            vec!["9:10".to_string()]
        );
        // A decimal is not a time: 1.2 → 2.1 stays refused.
        assert_eq!(
            invented("ยอดขาย 1.2 ล้านบาท", "Sales were 2.1 million baht."),
            vec!["2:1".to_string()]
        );
        assert_eq!(
            check_translation("ประชุมตอนเก้าโมงสิบนาที", "The meeting is at 9:10."),
            Ok(())
        );
        assert!(check_translation("ประชุมตอนเก้าโมงสิบนาที", "The meeting is at 8:10.").is_err());
    }

    #[test]
    fn numbers_keep_the_order_of_their_parts() {
        // A decimal or a time with its parts swapped is a different number.
        assert_eq!(
            lost_numbers("ยอดขาย 1.2 ล้านบาท", "ยอดขาย 2.1 ล้านบาท"),
            vec!["1:2".to_string()]
        );
        assert_eq!(
            invented_numbers("ยอดขาย 1.2 ล้านบาท", "ยอดขาย 2.1 ล้านบาท"),
            vec!["2:1".to_string()]
        );
        assert_eq!(
            lost_numbers("ประชุม 14:30 น.", "Meeting at 30:14."),
            vec!["14:30".to_string()]
        );
        let src = "ยอดขายเดือนนี้ 1.2 ล้านบาท ประชุมสรุปตอน 14:30";
        assert_eq!(
            check_command(
                "ทางการขึ้น",
                src,
                "ยอดขายประจำเดือนนี้อยู่ที่ 2.1 ล้านบาท ประชุมสรุปเวลา 14:30"
            ),
            Err(Rejection("numberLost"))
        );
        assert_eq!(
            check_translation(
                src,
                "Sales this month were 1.2 million baht; the review meeting is at 30:14."
            ),
            Err(Rejection("numberLost"))
        );
        // A summary may drop numbers, but not change one.
        assert_eq!(
            check_command("สรุปสั้นๆ", src, "ยอดขาย 2.1 ล้านบาท"),
            Err(Rejection("numberInvented"))
        );
        assert_eq!(check_command("สรุปสั้นๆ", src, "ยอดขาย 1.2 ล้านบาท"), Ok(()));
        // Equivalent spellings still match.
        assert_eq!(
            lost_numbers(
                "เริ่ม ๐๙.๓๐ น. งบ ๑,๒๐๐ บาท",
                "starts 09:30, budget 1200 baht"
            ),
            Vec::<String>::new()
        );
        // A comma outside thousands grouping separates numbers.
        assert_eq!(
            numbers("ข้อ 1,2,3 และ 1,234,567"),
            ["1", "2", "3", "1234567"]
        );
        // A number written twice is counted twice.
        assert_eq!(
            lost_numbers("สาขา 3 มีพนักงาน 3 คน", "Branch 3 has 4 staff."),
            vec!["3".to_string()]
        );
        assert_eq!(
            invented_numbers(
                "งบ 340,000 บาท",
                "Subject: 340,000 baht\n\nThe budget is 340,000 baht."
            ),
            Vec::<String>::new()
        );
    }

    #[test]
    fn translations_may_say_ordinary_english_but_not_answer() {
        for (thai, english) in [
            (
                "พรุ่งนี้ผมไปประชุมไม่ได้ครับ",
                "I cannot attend the meeting tomorrow.",
            ),
            ("รบกวนส่งรายละเอียดมาด้วยครับ", "Please provide the details."),
            ("ขอโทษครับ วันนี้ผมไปไม่ได้", "I'm sorry, I can't make it today."),
            ("ได้เลยครับ เดี๋ยวส่งไฟล์ให้", "Sure, I'll send you the file."),
        ] {
            assert_eq!(check_translation(thai, english), Ok(()), "{english}");
        }
        for english in [
            "Sure, I'll send you the file right away.",
            "Of course! I'll send it now.",
            "As an AI language model, I can't send files.",
            "Here is the translation: please send me the file.",
        ] {
            assert_eq!(
                check_translation("ส่งไฟล์มาให้หน่อย", english),
                Err(Rejection("assistant")),
                "{english}"
            );
        }
        // "Surely" is not "Sure".
        assert_eq!(
            check_translation("คงส่งไฟล์มาแล้วแหละ", "Surely they've sent the file by now."),
            Ok(())
        );
        // Command mode into English is a translation too.
        assert_eq!(
            check_command(
                "แปลเป็นภาษาอังกฤษ",
                "พรุ่งนี้ผมไปประชุมไม่ได้ครับ",
                "I can't attend the meeting tomorrow."
            ),
            Ok(())
        );
        // Within one language the stricter list stays.
        assert_eq!(
            check_command(
                "make it more polite",
                "send me the file",
                "I'm sorry, I cannot send files. Could you send me the file?"
            ),
            Err(Rejection("assistant"))
        );
    }

    #[test]
    fn questions() {
        assert!(is_question("ส่งไฟล์มาได้ไหมครับ"));
        assert!(is_question("ทำไม build พัง"));
        assert!(is_question("Is it ready?"));
        assert!(is_question("ใครเป็นคนลบ database ตัว staging เมื่อคืน"));
        assert!(is_question("deploy เสร็จหรือยังครับ"));
        assert!(is_question("ตัวนี้ใช้ยังไง"));
        assert!(!is_question("ส่งไฟล์มาด่วนเลย"));
        // A question word inside a clause is not a question.
        assert!(!is_question(
            "ผมจะลาพักร้อนวันที่ 23 ถึง 27 ธันวาคม ถ้ามีอะไรด่วนติดต่อคุณสมศักดิ์ได้เลยครับ"
        ));
        assert!(!is_question(
            "ลูกค้าถามว่าจะได้ของเมื่อไหร่ ช่วยตอบเขาหน่อยว่าน่าจะส่งได้วันอังคาร"
        ));
        assert!(still_asks("Could you send the file"));
        assert!(!still_asks("The build failed because of a cache."));
    }
}
