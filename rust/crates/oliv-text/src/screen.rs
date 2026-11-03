//! Names on screen: likely names and terms picked out of the visible text of
//! the window the user dictates into, used for ONE dictation as transient
//! vocabulary that ranks below the user's Dictionary.
//!
//! The Mac app sends the window's text as `screen_text` snippets (capped there
//! too); [`candidates`] keeps what looks like a name: CamelCase, acronyms,
//! letters with digits, capitalized words that are not everyday English, short
//! Thai labels (a name in a list, a sender) and, in running Thai text, words
//! outside the dictionary or after a title such as คุณ. Everyday words and
//! interface labels are dropped, and at most [`MAX_TERMS`] are kept.
//! [`correct`] then runs the vocabulary passes over them with the user's own
//! words protected and closer matches required (`phonetic::Guard`). Measured
//! on Thai ContextASR Bench lists sent as screen text and on a noisy synthetic
//! window (`benchmark/contextasr.md`). Pure and in memory: nothing here
//! stores, logs or sends text.

use std::collections::{HashMap, HashSet};

use crate::data::{THAI_STOPWORDS, is_thai_word};
use crate::dictionary::token_spans;
use crate::phonetic::{Guard, correct_with_thai_vocab_guarded, correct_with_vocab_guarded};
use crate::pyu::{casefold, has_thai, is_alpha, is_space, is_thai, strip};
use crate::user_dictionary::dedupe_key;

/// Most candidates kept for one dictation.
pub const MAX_TERMS: usize = 50;
/// Most snippets and characters read from one request; the rest is ignored.
pub const MAX_SNIPPETS: usize = 500;
pub const MAX_CHARS: usize = 20_000;
/// Longest candidate, in chars (names, not sentences).
const MAX_TERM_CHARS: usize = 40;
/// Longest multi-word name ("Pimchanok Saelee", "ศุภณัฐ ทองดี",
/// "University of Chiang Mai").
const MAX_PHRASE_WORDS: usize = 4;
/// A Thai run this short that stands alone and holds a word outside the
/// dictionary is taken whole (a name in a list, a chat header).
const MAX_THAI_RUN_CHARS: usize = 30;
/// A snippet this short reads as a label (a name, a sender, a header), not
/// running text.
const MAX_LABEL_WORDS: usize = 4;
const MAX_LABEL_CHARS: usize = 60;
/// Most newmm tokens in a Thai label chunk taken as one name.
const MAX_LABEL_TOKENS: usize = 5;
/// Fewest letters in a Thai candidate, and in one the LLM may not rewrite.
const MIN_THAI_LETTERS: usize = 3;
const MIN_GUARDED_LETTERS: usize = 4;

/// Snippets as the request carries them, cut to [`MAX_SNIPPETS`] and
/// [`MAX_CHARS`] (a cut snippet ends at a char boundary).
pub fn bounded(snippets: &[String]) -> Vec<String> {
    let mut left = MAX_CHARS;
    let mut out = Vec::new();
    for s in snippets.iter().take(MAX_SNIPPETS) {
        if left == 0 {
            break;
        }
        let cut: String = s.chars().take(left).collect();
        left -= cut.chars().count();
        out.push(cut);
    }
    out
}

/// Candidate terms from on-screen text, most frequent first (then first
/// seen), at most [`MAX_TERMS`], without words the user already listed
/// (`listed`: dictionary words and request vocabulary; the user's spelling
/// wins).
pub fn candidates(snippets: &[String], listed: &[String]) -> Vec<String> {
    let listed: HashSet<String> = listed.iter().map(|w| dedupe_key(w)).collect();
    let mut found: Vec<String> = Vec::new();
    for snippet in bounded(snippets) {
        found.extend(snippet_candidates(&snippet));
    }
    // (count, first index, spelling) per identity; the first spelling wins.
    let mut tally: HashMap<String, (usize, usize, String)> = HashMap::new();
    for (i, term) in found.into_iter().enumerate() {
        let key = dedupe_key(&term);
        if listed.contains(&key) {
            continue;
        }
        tally.entry(key).or_insert((0, i, term)).0 += 1;
    }
    let mut ranked: Vec<(usize, usize, String)> = tally.into_values().collect();
    ranked.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    ranked
        .into_iter()
        .take(MAX_TERMS)
        .map(|(_, _, t)| t)
        .collect()
}

// ---------------------------------------------------------------------------
// Matching

/// The vocabulary passes over on-screen `terms`, after the user's own
/// (`listed`) have run: Latin-term snapping, then Thai re-spelling, each
/// leaving every occurrence of a listed word untouched and matching more
/// closely than for the user's words ([`Guard::transient`]). The pass that
/// writes a Thai name in its listed Latin romanization (คลองเตย → Khlong
/// Toei) does not run: a name on screen keeps the script the user spoke in.
/// Returns the text, the number of terms that fired, and the gate hits
/// (letter-changing Latin snaps, as for the user's vocabulary).
pub fn correct(text: &str, listed: &[String], terms: &[String]) -> (String, usize, usize) {
    if terms.is_empty() || text.is_empty() {
        return (text.to_string(), 0, 0);
    }
    let guard = |mask| Guard {
        protected: mask,
        transient: true,
    };
    let mask = protected(text, listed);
    let (latin, n1, subs) = correct_with_vocab_guarded(text, terms, guard(&mask));
    let hits = subs
        .iter()
        .filter(|(src, dst)| src.to_lowercase() != dst.to_lowercase())
        .count();
    let mask = protected(&latin, listed);
    let (out, n2, _) = correct_with_thai_vocab_guarded(&latin, terms, guard(&mask));
    (out, n1 + n2, hits)
}

/// The LLM guard's term list: `listed`, then the on-screen Thai terms long
/// enough not to turn up inside other words. The cleanup model may not
/// rewrite those where they appear (it romanizes Thai names otherwise).
pub fn with_screen(listed: &[String], screen: &[String]) -> Vec<String> {
    let guarded = screen
        .iter()
        .filter(|t| has_thai(t) && letters(t) >= MIN_GUARDED_LETTERS);
    listed.iter().chain(guarded).cloned().collect()
}

/// Chars of `text` inside an occurrence of a listed word: Latin words ignore
/// case and sit on Latin word boundaries ("AI" is not in "MAIL"), Thai words
/// match exactly.
fn protected(text: &str, listed: &[String]) -> Vec<bool> {
    let t: Vec<char> = text.chars().collect();
    let mut mask = vec![false; t.len()];
    let fold = |c: char| c.to_lowercase().next().unwrap_or(c);
    let folded: Vec<char> = t.iter().map(|&c| fold(c)).collect();
    let latin = |c: char| c.is_ascii_alphanumeric();
    for word in listed.iter().map(|w| strip(w)).filter(|w| !w.is_empty()) {
        let w: Vec<char> = word.chars().map(fold).collect();
        if w.len() > t.len() {
            continue;
        }
        for i in 0..=t.len() - w.len() {
            let j = i + w.len();
            if folded[i..j] != w[..]
                || (latin(t[i]) && i > 0 && latin(t[i - 1]))
                || (latin(t[j - 1]) && j < t.len() && latin(t[j]))
            {
                continue;
            }
            mask[i..j].iter_mut().for_each(|m| *m = true);
        }
    }
    mask
}

// ---------------------------------------------------------------------------
// Words of one snippet

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Script {
    Latin,
    Thai,
    /// Digits only, other scripts, or Latin with accents: never a candidate.
    Other,
}

#[derive(Debug)]
struct Word {
    text: String,
    script: Script,
    /// Separated from the previous word by exactly one space (can form a
    /// multi-word name with it).
    joined: bool,
    /// First word of the snippet or of a sentence.
    initial: bool,
}

/// Split a snippet into Latin words (letters/digits with inner `.`, `-`, `'`),
/// Thai runs and other runs, remembering how each attaches to the previous.
fn words(snippet: &str) -> Vec<Word> {
    let chars: Vec<char> = snippet.chars().collect();
    let mut out: Vec<Word> = Vec::new();
    let mut i = 0;
    let mut gap = String::new();
    let mut initial = true;
    let latin = |c: char| c.is_alphanumeric() && !is_thai(c);
    while i < chars.len() {
        let c = chars[i];
        let start = i;
        let script = if is_thai(c) && c.is_alphabetic() || is_thai_mark(c) {
            while i < chars.len() && (is_thai(chars[i]) && !chars[i].is_ascii()) {
                i += 1;
            }
            Script::Thai
        } else if latin(c) {
            while i < chars.len()
                && (latin(chars[i])
                    || (matches!(chars[i], '.' | '-' | '\'' | '’')
                        && i + 1 < chars.len()
                        && latin(chars[i + 1])
                        && i > start))
            {
                i += 1;
            }
            let w: String = chars[start..i].iter().collect();
            if w.chars()
                .all(|c| c.is_ascii_alphanumeric() || ".-'’".contains(c))
                && w.chars().any(|c| c.is_ascii_alphabetic())
            {
                Script::Latin
            } else {
                Script::Other
            }
        } else {
            gap.push(c);
            if matches!(c, '.' | '!' | '?' | ':' | ';' | '\n' | '•' | '|') {
                initial = true;
            }
            i += 1;
            continue;
        };
        out.push(Word {
            text: chars[start..i].iter().collect(),
            script,
            joined: !out.is_empty() && gap == " ",
            initial,
        });
        gap.clear();
        initial = false;
    }
    out
}

/// Thai vowel/tone marks that can begin a run after an odd split.
fn is_thai_mark(c: char) -> bool {
    matches!(c, '\u{e31}' | '\u{e34}'..='\u{e3a}' | '\u{e47}'..='\u{e4e}')
}

// ---------------------------------------------------------------------------
// Latin

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Latin {
    /// API, KKP: 2–6 capitals.
    Acronym,
    /// SHA256, H100.
    Alnum,
    /// GitHub, iPhone, LaunchDarkly.
    Camel,
    /// Somchai, Grafana: capitalized and not everyday English.
    Capitalized,
}

fn latin_kind(w: &str) -> Option<Latin> {
    let core: String = w.chars().filter(char::is_ascii_alphanumeric).collect();
    let letters = core.chars().filter(char::is_ascii_alphabetic).count();
    if core.chars().count() < 2 || letters == 0 {
        return None;
    }
    let first = core.chars().next()?;
    let has_digit = core.chars().any(|c| c.is_ascii_digit());
    let upper = core.chars().filter(char::is_ascii_uppercase).count();
    let camel = core
        .chars()
        .zip(core.chars().skip(1))
        .any(|(a, b)| a.is_ascii_lowercase() && b.is_ascii_uppercase());
    if has_digit {
        return first.is_ascii_alphabetic().then_some(Latin::Alnum);
    }
    if upper == letters {
        let common = COMMON_ACRONYMS.contains(&core.as_str());
        return ((2..=6).contains(&letters) && !common).then_some(Latin::Acronym);
    }
    if camel {
        return Some(Latin::Camel);
    }
    let capitalized = first.is_ascii_uppercase() && upper == 1 && letters >= 3;
    (capitalized && !is_common_english(&core)).then_some(Latin::Capitalized)
}

/// Lowercase words that sit inside a multi-word name. Not "and": it joins
/// two names ("Somchai and Kittiphan") more often than it names one.
const NAME_CONNECTORS: [&str; 5] = ["of", "de", "the", "van", "von"];

/// Latin candidates: runs of up to [`MAX_PHRASE_WORDS`] name-like words joined
/// by single spaces become one name ("Khlong Toei"); its parts are not offered
/// alone, since a part (Khlong) can sound like an everyday Thai word (คลอง).
fn latin_candidates(words: &[Word], out: &mut Vec<String>) {
    let short = words.len() <= MAX_PHRASE_WORDS;
    let mut i = 0;
    while i < words.len() {
        let kind = (words[i].script == Script::Latin)
            .then(|| latin_kind(&words[i].text))
            .flatten();
        let Some(kind) = kind else {
            i += 1;
            continue;
        };
        // Once a name has started, any title-case word continues it ("CP
        // All", "Google Street View"), as does a connector before one
        // ("University of Chiang Mai").
        let continues = |k: usize| {
            k < words.len()
                && words[k].joined
                && words[k].script == Script::Latin
                && (latin_kind(&words[k].text).is_some()
                    || words[k].text.starts_with(|c: char| c.is_ascii_uppercase()))
        };
        let mut j = i + 1;
        while j - i < MAX_PHRASE_WORDS {
            if continues(j) {
                j += 1;
            } else if j - i + 2 <= MAX_PHRASE_WORDS
                // In running text a sentence opener does not start a name
                // through a connector ("Shares of OLIV Labs"); a short label
                // does ("Bank of America").
                && !(j == i + 1 && words[i].initial && !short)
                && j + 1 < words.len()
                && words[j].joined
                && NAME_CONNECTORS.contains(&words[j].text.as_str())
                && continues(j + 1)
            {
                j += 2;
            } else {
                break;
            }
        }
        let phrase: Vec<&str> = words[i..j].iter().map(|w| w.text.as_str()).collect();
        // A capitalized word opening a sentence is only a name when the
        // snippet is a short label (a sender, a contact) or it is not alone.
        let lone_initial = j == i + 1 && kind == Latin::Capitalized && words[i].initial;
        if !lone_initial || short {
            push(out, &phrase.join(" "));
        }
        i = j;
    }
}

// ---------------------------------------------------------------------------
// Thai

/// Titles that precede a person's name in Thai ("คุณสมชาย", "ดร.ศุภณัฐ").
const THAI_TITLES: [&str; 17] = [
    "คุณ",
    "นาย",
    "นาง",
    "นางสาว",
    "น.ส.",
    "ดร.",
    "ดร",
    "พี่",
    "น้อง",
    "อาจารย์",
    "ครู",
    "หมอ",
    "ผศ.",
    "รศ.",
    "ศ.",
    "พญ.",
    "นพ.",
];

/// A newmm token outside the Thai dictionary that is not punctuation, a
/// number or a stopword: evidence of a name, a brand or a transliteration.
fn unknown(tok: &str) -> bool {
    tok.chars().any(|c| is_thai(c) && c.is_alphabetic())
        && !is_thai_word(tok)
        && !THAI_STOPWORDS.contains(tok)
        && !tok.chars().all(|c| c.is_numeric() || !c.is_alphabetic())
}

fn is_stop(tok: &str) -> bool {
    THAI_STOPWORDS.contains(tok)
}

/// Thai candidates from one run (Thai has no spaces between words):
///
/// - a short run that holds an unknown word and no stopword is taken whole
///   (a name standing alone: "ฐิติพงส์", "ศุภณัฐ ทองดี" with its neighbor);
/// - the words after a title (คุณ, นาย, ดร.) up to a stopword, when one of
///   them is unknown;
/// - inside running text, consecutive unknown words.
///
/// Runs made only of dictionary words (ตั้งค่า, ส่งข้อความ) are everyday
/// text and are dropped.
fn thai_run_candidates(run: &str) -> (Option<String>, Vec<String>) {
    let toks: Vec<String> = token_spans(run).into_iter().map(|(_, _, t)| t).collect();
    let toks: Vec<&str> = toks
        .iter()
        .map(String::as_str)
        .filter(|t| !t.chars().all(is_space))
        .collect();
    let any_unknown = toks.iter().any(|t| unknown(t));
    let any_stop = toks.iter().any(|t| is_stop(t));
    let whole = (any_unknown && !any_stop && run.chars().count() <= MAX_THAI_RUN_CHARS)
        .then(|| run.to_string());
    let mut parts = Vec::new();
    let mut k = 0;
    while k < toks.len() {
        if THAI_TITLES.contains(&toks[k]) && k + 1 < toks.len() {
            // The whole name after the title, where newmm split it into a
            // known head and an unknown tail (ศุภ + ณัฐ). Names made only
            // of dictionary words (สมชาย) are already spelled right by ASR,
            // and "พี่กินข้าว" is not a name.
            let after: Vec<&str> = toks[k + 1..]
                .iter()
                .take_while(|t| !is_stop(t) && !THAI_TITLES.contains(t))
                .take(3)
                .copied()
                .collect();
            // The name ends at its last unknown word (คุณศุภณัฐ|เรื่อง).
            if let Some(last) = after.iter().rposition(|t| unknown(t)) {
                parts.push(after[..=last].concat());
                k += 2 + last;
                continue;
            }
            k += 1;
            continue;
        }
        if unknown(toks[k]) {
            let mut j = k;
            while j < toks.len() && unknown(toks[j]) {
                j += 1;
            }
            parts.push(toks[k..j].concat());
            k = j;
            continue;
        }
        k += 1;
    }
    (whole, parts)
}

/// Thai candidates of a snippet.
///
/// A label-like snippet (a name in a list, a sender, a header: at most
/// [`MAX_LABEL_WORDS`] words) gives each Thai chunk whole when it reads as a
/// name: a few tokens, at most one stopword (names split into syllables such
/// as มา|โน|ช), and not an everyday interface word. Neighboring chunks
/// separated by single spaces form one multi-word name. Many Thai names are
/// dictionary words (เฟซบุ๊ก, จตุจักร), so labels are not checked against
/// the dictionary; the re-spelling pass only ever changes a span that sounds
/// the same and is spelled almost the same.
///
/// Running text gives what [`thai_run_candidates`] finds inside each run.
fn thai_candidates(words: &[Word], label: bool, out: &mut Vec<String>) {
    let mut i = 0;
    while i < words.len() {
        if words[i].script != Script::Thai {
            i += 1;
            continue;
        }
        if label {
            let mut name = Vec::new();
            let mut j = i;
            while j < words.len()
                && name.len() < MAX_PHRASE_WORDS
                && words[j].script == Script::Thai
                && (j == i || words[j].joined)
                && reads_as_name(&words[j].text)
            {
                name.push(words[j].text.as_str());
                j += 1;
            }
            if !name.is_empty() {
                push(out, &name.join(" "));
                i = j;
                continue;
            }
        }
        if THAI_TITLES.contains(&words[i].text.as_str())
            && i + 1 < words.len()
            && words[i + 1].joined
            && words[i + 1].script == Script::Thai
        {
            let (_, parts) =
                thai_run_candidates(&format!("{}{}", words[i].text, words[i + 1].text));
            parts.iter().for_each(|p| push(out, p));
            i += 2;
            continue;
        }
        let (whole, parts) = thai_run_candidates(&words[i].text);
        match whole {
            Some(w) => push(out, &w),
            None => parts.iter().for_each(|p| push(out, p)),
        }
        i += 1;
    }
}

/// A Thai chunk of a label that reads as a name rather than a phrase.
fn reads_as_name(chunk: &str) -> bool {
    let n = chunk.chars().count();
    if !(2..=MAX_THAI_RUN_CHARS).contains(&n) || is_common_thai(chunk) {
        return false;
    }
    let toks: Vec<String> = token_spans(chunk).into_iter().map(|(_, _, t)| t).collect();
    let stops = toks.iter().filter(|t| is_stop(t)).count();
    // "ส่งข้อความ" is a button made of interface words, not a name.
    let everyday = toks.iter().all(|t| is_stop(t) || is_common_thai(t));
    toks.len() <= MAX_LABEL_TOKENS && stops <= 1 && !everyday
}

fn snippet_candidates(snippet: &str) -> Vec<String> {
    let words = words(snippet);
    let label = words.len() <= MAX_LABEL_WORDS && snippet.chars().count() <= MAX_LABEL_CHARS;
    let mut out = Vec::new();
    latin_candidates(&words, &mut out);
    thai_candidates(&words, label, &mut out);
    out
}

/// Keep a candidate that is a usable dictionary-style field and not an
/// everyday word.
fn push(out: &mut Vec<String>, term: &str) {
    let t = strip(term);
    let n = t.chars().count();
    if !(2..=MAX_TERM_CHARS).contains(&n) || crate::user_dictionary::clean_field(t).is_none() {
        return;
    }
    if THAI_STOPWORDS.contains(t) || is_common_thai(t) {
        return;
    }
    // A Thai name has a few letters; shorter runs (เจ, วี, ด์) are syllables
    // and fragments that turn up inside other words.
    if has_thai(t) && letters(t) < MIN_THAI_LETTERS {
        return;
    }
    out.push(t.to_string());
}

/// Letters, not counting Thai vowel and tone marks (Unicode L*, unlike
/// `char::is_alphabetic`, which counts the marks too).
fn letters(t: &str) -> usize {
    t.chars().filter(|&c| is_alpha(c)).count()
}

// ---------------------------------------------------------------------------
// Everyday words

/// Thai interface words and greetings that label a screen without naming
/// anything.
#[rustfmt::skip]
const COMMON_THAI: &[&str] = &[
    "กลับ", "กลุ่ม", "กิจกรรม", "การแจ้งเตือน", "การประชุม", "ก่อนหน้า", "ขอบคุณ", "ข้อความ",
    "ความช่วยเหลือ", "ครับ", "ค่ะ", "ค้นหา", "คัดลอก", "งาน", "ช่วยเหลือ", "ช่อง", "ชื่อ",
    "เชิญ", "แชท", "แชร์", "ดาวน์โหลด", "ตกลง", "ตอบกลับ", "ตั้งค่า", "ตาราง", "ถัดไป",
    "ทั้งหมด", "ทั่วไป", "ทีม", "เครื่องมือ", "แทรก", "บันทึก", "บันทึกย่อ", "ปฏิทิน", "ประชุม",
    "ปิด", "เปิด", "โปรไฟล์", "ไฟล์", "เพิ่ม", "เมนู", "เมื่อวาน", "ยกเลิก", "ยืนยัน", "รูปแบบ",
    "รูปภาพ", "ลบ", "ล่าสุด", "วันที่", "วันนี้", "วาง", "วิดีโอ", "เวลา", "ส่ง", "ส่งต่อ",
    "สถานะ", "สนทนา", "สมาชิก", "สวัสดี", "เสร็จ", "เสร็จสิ้น", "เสียง", "หน้า", "หน้าต่าง",
    "หน้าแรก", "ใหม่", "อัปโหลด", "ออกจากระบบ", "ออนไลน์", "ออฟไลน์", "เอกสาร", "แก้ไข",
    "เข้าสู่ระบบ", "โครงการ", "โทร", "โน้ต", "พรุ่งนี้", "มุมมอง",
];

fn is_common_thai(word: &str) -> bool {
    COMMON_THAI.contains(&word)
}

/// Acronyms that are everyday words, not names.
const COMMON_ACRONYMS: [&str; 6] = ["OK", "AM", "PM", "TV", "FYI", "ASAP"];

fn is_common_english(word: &str) -> bool {
    COMMON_ENGLISH
        .binary_search(&casefold(word).as_str())
        .is_ok()
}

/// Everyday English that is capitalized on screen without being a name:
/// sentence openers, greetings, interface labels, days and months.
#[rustfmt::skip]
const COMMON_ENGLISH: &[&str] = &[
    "a", "about", "above", "accept", "account", "accounts", "action", "actions", "active",
    "activity", "add", "added", "address", "admin", "after", "again", "agenda", "ago", "all",
    "allow", "already", "also", "always", "an", "and", "another", "answer", "any", "anyone",
    "anything", "app", "apply", "apps", "april", "archive", "are", "around", "as", "ask", "at",
    "attach", "attachment", "attachments", "audio", "august", "available", "away", "back",
    "before", "below", "best", "bold", "bookmarks", "both", "but", "button", "by", "calendar",
    "call", "calls", "can", "cancel", "cannot", "channel", "channels", "chat", "chats", "check",
    "choose", "clear", "click", "close", "code", "comment", "comments", "company", "complete",
    "confirm", "connect", "contact", "contacts", "continue", "copy", "could", "create",
    "created", "current", "customize", "daily", "dark", "date", "day", "days", "dear",
    "december", "default", "delete", "deleted", "description", "details", "did", "direct",
    "disable", "do", "document", "documents", "does", "done", "down", "download", "downloads",
    "draft", "drafts", "due", "each", "edit", "edited", "email", "empty", "enable", "end",
    "enter", "error", "even", "event", "events", "every", "everyone", "everything", "example",
    "exit", "export", "favorites", "february", "feedback", "file", "files", "filter", "find",
    "first", "flag", "folder", "folders", "follow", "for", "format", "forward", "free",
    "friday", "from", "full", "general", "get", "go", "good", "great", "group", "groups", "had",
    "has", "have", "he", "hello", "help", "her", "here", "hey", "hi", "hide", "his", "history",
    "home", "hour", "hours", "how", "however", "i", "if", "import", "in", "inbox", "info",
    "information", "insert", "into", "invite", "is", "it", "italic", "item", "items", "its",
    "january", "join", "july", "june", "just", "keep", "language", "last", "later", "learn",
    "leave", "less", "let", "light", "like", "link", "links", "list", "load", "loading",
    "local", "location", "lock", "log", "login", "logout", "main", "make", "manage", "march",
    "mark", "may", "maybe", "me", "meeting", "meetings", "members", "mentions", "menu",
    "message", "messages", "minute", "minutes", "monday", "month", "more", "most", "move",
    "much", "must", "mute", "my", "name", "never", "new", "news", "next", "no", "none", "not",
    "note", "notes", "nothing", "notifications", "november", "now", "october", "of", "off",
    "offline", "oh", "okay", "old", "on", "once", "one", "online", "only", "open", "options",
    "or", "order", "other", "our", "out", "over", "owner", "page", "pages", "password", "paste",
    "pause", "people", "photo", "photos", "pin", "pinned", "play", "please", "post", "posts",
    "preferences", "preview", "previous", "print", "privacy", "private", "profile", "project",
    "projects", "public", "quick", "quit", "random", "read", "really", "recent", "redo",
    "refresh", "regards", "remind", "reminder", "reminders", "remove", "rename", "replies",
    "reply", "report", "request", "reset", "resolve", "restore", "results", "review", "right",
    "saturday", "save", "saved", "schedule", "search", "second", "section", "see", "select",
    "send", "sent", "september", "set", "settings", "share", "shared", "she", "should", "show",
    "sidebar", "sign", "since", "size", "skip", "so", "some", "someone", "something", "sorry",
    "sort", "start", "started", "status", "still", "stop", "subject", "submit", "such",
    "sunday", "support", "sure", "switch", "sync", "system", "table", "tag", "tags", "task",
    "tasks", "team", "teams", "text", "than", "thank", "thanks", "that", "the", "their", "them",
    "then", "there", "these", "they", "this", "those", "thread", "threads", "through",
    "thursday", "time", "title", "to", "today", "together", "tomorrow", "too", "tools", "top",
    "trash", "try", "tuesday", "turn", "type", "undo", "unread", "untitled", "up", "update",
    "updated", "upload", "us", "use", "user", "users", "very", "video", "view", "was", "we",
    "wednesday", "week", "weekly", "welcome", "well", "were", "what", "when", "where", "which",
    "while", "who", "why", "will", "window", "with", "without", "work", "would", "write",
    "year", "yes", "yesterday", "yet", "you", "your",
];

#[cfg(test)]
mod tests {
    use super::*;

    fn cands(snippets: &[&str]) -> Vec<String> {
        let s: Vec<String> = snippets.iter().map(|s| s.to_string()).collect();
        candidates(&s, &[])
    }

    #[test]
    fn common_english_is_sorted_and_lowercase() {
        assert!(COMMON_ENGLISH.windows(2).all(|p| p[0] < p[1]));
        assert!(
            COMMON_ENGLISH
                .iter()
                .all(|w| w.chars().all(|c| c.is_ascii_lowercase()))
        );
    }

    #[test]
    fn words_track_spacing_and_sentences() {
        let w = words("Hi Somchai. Meet Pimchanok Saelee,ok");
        let texts: Vec<&str> = w.iter().map(|w| w.text.as_str()).collect();
        assert_eq!(
            texts,
            ["Hi", "Somchai", "Meet", "Pimchanok", "Saelee", "ok"]
        );
        assert!(w[0].initial && !w[1].initial && w[2].initial);
        assert!(w[1].joined && !w[2].joined && w[4].joined && !w[5].joined);
        assert_eq!(words("José")[0].script, Script::Other);
        assert_eq!(words("2026")[0].script, Script::Other);
    }

    #[test]
    fn latin_names_and_terms_are_kept_everyday_words_dropped() {
        let c = cands(&[
            "Thanks for the update, please ask Kittiphan about the GitHub issue.",
            "The SHA256 of the iPhone build is attached. Call me at 5 PM, OK?",
            "Settings",
            "Inbox",
        ]);
        assert_eq!(c, ["Kittiphan", "GitHub", "SHA256", "iPhone"]);
        // Everyday words, numbers and accented words are not names.
        assert!(cands(&["Today", "New Message", "2026", "OK", "José"]).is_empty());
    }

    #[test]
    fn multi_word_names_stay_whole() {
        let c = cands(&[
            "Pimchanok Saelee",
            "Meeting with Somchai Jaidee at Khlong Toei.",
            "She studied at the University of Chiang Mai.",
            "Shares of OLIV Labs rose, said Somchai and Kittiphan.",
        ]);
        assert_eq!(
            c,
            [
                "Pimchanok Saelee",
                "Somchai Jaidee",
                "Khlong Toei",
                "University of Chiang Mai",
                "OLIV Labs",
                "Somchai",
                "Kittiphan"
            ]
        );
        // A part alone could sound like an everyday Thai word (Khlong/คลอง).
        assert!(!c.iter().any(|t| t == "Khlong"));
    }

    #[test]
    fn a_capitalized_word_opening_a_sentence_needs_a_short_label() {
        // Sentence openers in running text are not names...
        assert!(cands(&["Unfortunately the build failed again this morning."]).is_empty());
        // ...but a short label is (a sender, a contact).
        assert_eq!(cands(&["Somchai"]), ["Somchai"]);
    }

    #[test]
    fn thai_labels_are_taken_whole_and_running_text_only_by_its_names() {
        // Labels: names in a list, a chat header. Dictionary words count here
        // (many Thai names are in the dictionary), interface words do not.
        assert_eq!(
            cands(&["ฐิติพงส์", "จตุจักร", "ศุภณัฐ ทองดี", "ตั้งค่า", "ค่ะ"]),
            ["ฐิติพงส์", "จตุจักร", "ศุภณัฐ ทองดี"]
        );
        // Running text: the name after a title and unknown words, never the
        // sentence itself.
        let c = cands(&["เมื่อวานผมคุยกับคุณศุภณัฐเรื่องงานที่จะส่งให้ลูกค้าพรุ่งนี้นะครับ"]);
        assert_eq!(c, ["ศุภณัฐ"]);
        let c = cands(&["วันนี้ไปกินข้าวกับเพื่อนที่ร้านใหม่ อร่อยมาก แล้วก็ไปดูหนังต่อ"]);
        assert!(c.is_empty(), "{c:?}");
    }

    #[test]
    fn short_thai_runs_are_not_names() {
        assert!(cands(&["เจ", "วี", "หุ้น", "ด์"]).is_empty());
        assert_eq!(cands(&["ต้นกล้า"]), ["ต้นกล้า"]);
        // Only longer Thai terms are kept from the cleanup model's rewrites.
        let s = |t: &[&str]| t.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(
            with_screen(&s(&["Grafana"]), &s(&["ฐิติพงส์", "ดาร์", "Kittiphan"])),
            ["Grafana", "ฐิติพงส์"]
        );
    }

    #[test]
    fn most_frequent_first_capped_and_listed_words_left_to_the_user() {
        let mut snippets: Vec<String> = (0..80).map(|i| format!("Project{i}")).collect();
        snippets.extend(["Kittiphan", "Kittiphan", "Grafana"].map(String::from));
        let listed = ["grafana".to_string()];
        let c = candidates(&snippets, &listed);
        assert_eq!(c.len(), MAX_TERMS);
        assert_eq!(c[0], "Kittiphan");
        assert_eq!(c[1], "Project0");
        // The user's Dictionary already has it: their spelling wins.
        assert!(!c.iter().any(|t| t.eq_ignore_ascii_case("grafana")));
    }

    #[test]
    fn snippets_and_characters_are_bounded() {
        let many: Vec<String> = (0..MAX_SNIPPETS + 10).map(|i| format!("Name{i}")).collect();
        assert_eq!(bounded(&many).len(), MAX_SNIPPETS);
        let long = vec!["ก".repeat(MAX_CHARS - 2), "Grafana Kittiphan".to_string()];
        let b = bounded(&long);
        assert_eq!(b[1], "Gr");
        assert_eq!(
            b.iter().map(|s| s.chars().count()).sum::<usize>(),
            MAX_CHARS
        );
    }

    #[test]
    fn listed_words_are_protected_on_latin_boundaries() {
        let listed = ["AI".to_string(), "ณัฐพงศ์".to_string()];
        let mask = protected("MAIL AI ของณัฐพงศ์", &listed);
        let marked: String = "MAIL AI ของณัฐพงศ์"
            .chars()
            .zip(&mask)
            .filter(|(_, m)| **m)
            .map(|(c, _)| c)
            .collect();
        assert_eq!(marked, "AIณัฐพงศ์");
    }
}
