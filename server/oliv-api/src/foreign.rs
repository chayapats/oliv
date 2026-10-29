//! Romanizes short Cyrillic, kana and Hangul runs that Qwen3-ASR writes inside
//! Thai or English words (`рейтลิมิต`, `เช็กไทม์ของレスポン`, `มิ팅`). Not in Oliv:
//! `strip_cjk` deletes kana/Hangul and Cyrillic passes through, so either the
//! word is lost or the user sees it, and the gate calls the text clean-thai.
//! Only for the qwen3asr profile (`dictate::clean_text`). Kana and Hangul are
//! romanized only when glued to a Thai or ASCII letter; a space-delimited word
//! (`ขอบคุณครับ 감사합니다`), a long run, a run touching Han, text with more
//! foreign runs or chars than a word would have, and text with no Thai or
//! ASCII letters are left for `strip_cjk`, so caption hallucinations still
//! end stripped or as no speech.

use crate::hallucination::is_cjk;
use crate::pyu::is_thai;
use crate::spacing::is_thai_mark;

/// Longest run that is romanized; longer ones look like a foreign caption.
const MAX_RUN: usize = 6;
/// Most runs, and foreign chars in them, that one text may have romanized.
const MAX_RUNS: usize = 3;
const MAX_CHARS: usize = 12;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Script {
    Cyrillic,
    Kana,
    Hangul,
}

fn script(c: char) -> Option<Script> {
    match c {
        '\u{0400}'..='\u{04ff}' => Some(Script::Cyrillic),
        '\u{3040}'..='\u{30ff}' => Some(Script::Kana),
        '\u{ac00}'..='\u{d7af}' => Some(Script::Hangul),
        _ => None,
    }
}

fn is_foreign(c: char) -> bool {
    script(c).is_some() || is_cjk(c)
}

fn is_letter(c: char) -> bool {
    is_thai(c) || c.is_ascii_alphabetic()
}

/// A run's same-script pieces in Latin, or None when it is left alone: too
/// long, touching Han or an unknown char, or kana/Hangul with a space or the
/// text edge on both sides (a whole foreign word, not a glued syllable).
fn romanize_run(t: &[char], i: usize, j: usize) -> Option<Vec<(Script, String)>> {
    let run = &t[i..j];
    if run.len() > MAX_RUN {
        return None;
    }
    let glued = (i > 0 && is_letter(t[i - 1])) || t.get(j).is_some_and(|&c| is_letter(c));
    let mut pieces = Vec::new();
    let mut k = 0;
    while k < run.len() {
        let s = script(run[k])?;
        let n = run[k..]
            .iter()
            .take_while(|&&c| script(c) == Some(s))
            .count();
        if s != Script::Cyrillic && !glued {
            return None;
        }
        let latin = match s {
            Script::Cyrillic => cyrillic(&run[k..k + n]),
            Script::Kana => kana(&run[k..k + n]),
            Script::Hangul => hangul(&run[k..k + n]),
        }?;
        if latin.is_empty() {
            return None;
        }
        pieces.push((s, latin));
        k += n;
    }
    Some(pieces)
}

/// Replaces each foreign run of at most `MAX_RUN` chars with Latin, one
/// same-script piece at a time, spaced off from adjacent Thai (and, for kana
/// and Hangul, from adjacent Latin letters, digits and the other pieces). A
/// Thai mark left after the run has nothing to sit on and is dropped. Returns
/// `(new_text, fired)`; byte-identical passthrough when nothing fires.
pub fn romanize_embedded(text: &str) -> (String, bool) {
    let applies = text.chars().any(|c| script(c).is_some())
        && text.chars().any(|c| is_thai(c) || c.is_ascii_alphabetic());
    if !applies {
        return (text.to_string(), false);
    }
    let t: Vec<char> = text.chars().collect();
    // (start, end, pieces) of every run that is romanized.
    let mut runs = Vec::new();
    let mut i = 0;
    while i < t.len() {
        if !is_foreign(t[i]) {
            i += 1;
            continue;
        }
        let j = i + t[i..].iter().take_while(|&&c| is_foreign(c)).count();
        if let Some(pieces) = romanize_run(&t, i, j) {
            runs.push((i, j, pieces));
        }
        i = j;
    }
    let chars: usize = runs.iter().map(|(i, j, _)| j - i).sum();
    if runs.is_empty() || runs.len() > MAX_RUNS || chars > MAX_CHARS {
        return (text.to_string(), false);
    }
    let mut out = String::with_capacity(text.len());
    let mut copied = 0;
    for (i, mut j, pieces) in runs {
        out.extend(&t[copied..i]);
        // A Cyrillic run can be homoglyphs inside a Latin word (`rаte`); kana
        // and Hangul are whole syllables, kept off Latin too.
        let apart =
            |s: Script, c: char| is_thai(c) || (s != Script::Cyrillic && c.is_ascii_alphanumeric());
        let (first, last) = (pieces[0].0, pieces[pieces.len() - 1].0);
        if i > 0 && apart(first, t[i - 1]) {
            out.push(' ');
        }
        let mut prev: Option<Script> = None;
        for (s, latin) in pieces {
            if prev.is_some_and(|p| p != Script::Cyrillic || s != Script::Cyrillic) {
                out.push(' ');
            }
            out.push_str(&latin);
            prev = Some(s);
        }
        while t.get(j).is_some_and(|&c| is_thai_mark(c)) {
            j += 1;
        }
        if t.get(j).is_some_and(|&c| apart(last, c)) {
            out.push(' ');
        }
        copied = j;
    }
    out.extend(&t[copied..]);
    (out, true)
}

const CYRILLIC: [(char, &str); 37] = [
    ('а', "a"),
    ('б', "b"),
    ('в', "v"),
    ('г', "g"),
    ('д', "d"),
    ('е', "e"),
    ('ё', "yo"),
    ('ж', "zh"),
    ('з', "z"),
    ('и', "i"),
    ('й', "y"),
    ('к', "k"),
    ('л', "l"),
    ('м', "m"),
    ('н', "n"),
    ('о', "o"),
    ('п', "p"),
    ('р', "r"),
    ('с', "s"),
    ('т', "t"),
    ('у', "u"),
    ('ф', "f"),
    ('х', "kh"),
    ('ц', "ts"),
    ('ч', "ch"),
    ('ш', "sh"),
    ('щ', "shch"),
    ('ъ', ""),
    ('ы', "y"),
    ('ь', ""),
    ('э', "e"),
    ('ю', "yu"),
    ('я', "ya"),
    ('і', "i"),
    ('ї', "yi"),
    ('є', "ye"),
    ('ґ', "g"),
];

/// Letter by letter; an uppercase letter gives a capitalized romanization.
fn cyrillic(run: &[char]) -> Option<String> {
    let mut out = String::new();
    for &c in run {
        let lower = c.to_lowercase().next()?;
        let latin = CYRILLIC.iter().find(|(k, _)| *k == lower)?.1;
        let mut cs = latin.chars();
        if c != lower {
            out.extend(cs.next().map(|f| f.to_ascii_uppercase()));
        }
        out.extend(cs);
    }
    Some(out)
}

/// Hepburn for hiragana U+3041..=U+3096 in code point order. `っ` is never
/// read from the table.
const KANA: [&str; 86] = [
    "a", "a", "i", "i", "u", "u", "e", "e", "o", "o", //
    "ka", "ga", "ki", "gi", "ku", "gu", "ke", "ge", "ko", "go", //
    "sa", "za", "shi", "ji", "su", "zu", "se", "ze", "so", "zo", //
    "ta", "da", "chi", "ji", "", "tsu", "zu", "te", "de", "to", "do", //
    "na", "ni", "nu", "ne", "no", //
    "ha", "ba", "pa", "hi", "bi", "pi", "fu", "bu", "pu", "he", "be", "pe", "ho", "bo",
    "po", //
    "ma", "mi", "mu", "me", "mo", //
    "ya", "ya", "yu", "yu", "yo", "yo", //
    "ra", "ri", "ru", "re", "ro", //
    "wa", "wa", "i", "e", "o", "n", "vu", "ka", "ke",
];

/// Katakana folded onto hiragana; `ヷ`..`ヺ` and `ー` stay as they are.
fn to_hiragana(c: char) -> char {
    match c {
        '\u{30a1}'..='\u{30f6}' => char::from_u32(c as u32 - 0x60).unwrap_or(c),
        _ => c,
    }
}

/// Small ya/yu/yo after an i-row syllable make a digraph (`きゃ` kya, `しゃ`
/// sha), a small vowel replaces the vowel before it (`ファ` fa, `ティ` ti),
/// small tsu doubles the next consonant and the long-vowel mark is dropped.
fn kana(run: &[char]) -> Option<String> {
    let mut sylls: Vec<String> = Vec::new();
    let mut double_next = false;
    for &c in run {
        let h = to_hiragana(c);
        let small_y = match h {
            'ゃ' => Some("a"),
            'ゅ' => Some("u"),
            'ょ' => Some("o"),
            _ => None,
        };
        let small_vowel = match h {
            'ぁ' => Some("a"),
            'ぃ' => Some("i"),
            'ぅ' => Some("u"),
            'ぇ' => Some("e"),
            'ぉ' => Some("o"),
            _ => None,
        };
        match (h, small_y, small_vowel, sylls.last_mut()) {
            ('ー', ..) => {}
            ('っ', ..) => double_next = true,
            (_, Some(v), _, Some(prev)) if prev.len() >= 2 && prev.ends_with('i') => {
                prev.pop();
                if !(prev.ends_with("sh") || prev.ends_with("ch") || prev.ends_with('j')) {
                    prev.push('y');
                }
                prev.push_str(v);
            }
            (_, _, Some(v), Some(prev)) if prev.len() >= 2 || prev == "u" => {
                if prev == "u" {
                    *prev = "w".into();
                } else {
                    prev.pop();
                }
                prev.push_str(v);
            }
            _ => {
                let latin = match h {
                    'ヷ' => "va",
                    'ヸ' => "vi",
                    'ヹ' => "ve",
                    'ヺ' => "vo",
                    '\u{3041}'..='\u{3096}' => KANA[(h as u32 - 0x3041) as usize],
                    _ => return None,
                };
                let mut syll = String::new();
                if std::mem::take(&mut double_next) {
                    match latin.chars().next() {
                        Some('c') => syll.push('t'),
                        Some(f) if !"aiueon".contains(f) => syll.push(f),
                        _ => {}
                    }
                }
                syll.push_str(latin);
                sylls.push(syll);
            }
        }
    }
    Some(sylls.concat())
}

/// Revised Romanization jamo, syllable by syllable (no sound-change rules).
const INITIALS: [&str; 19] = [
    "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p",
    "h",
];
const MEDIALS: [&str; 21] = [
    "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we",
    "wi", "yu", "eu", "ui", "i",
];
const FINALS: [&str; 28] = [
    "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p",
    "t", "t", "ng", "t", "t", "k", "t", "p", "t",
];

fn hangul(run: &[char]) -> Option<String> {
    let mut out = String::new();
    for &c in run {
        let s = (c as u32).checked_sub(0xac00).filter(|&s| s < 11172)? as usize;
        out.push_str(INITIALS[s / 588]);
        out.push_str(MEDIALS[s % 588 / 28]);
        out.push_str(FINALS[s % 28]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rom(s: &str) -> String {
        romanize_embedded(s).0
    }

    #[test]
    fn romanizes_runs_inside_thai() {
        assert_eq!(romanize_embedded("рейтลิมิต"), ("reyt ลิมิต".into(), true));
        assert_eq!(rom("ตั้ง рейтลิมิตให้ API"), "ตั้ง reyt ลิมิตให้ API");
        assert_eq!(rom("เช็กไทม์ของレスポン ผม"), "เช็กไทม์ของ resupon ผม");
        assert_eq!(rom("ดูเฮดเดอร์ของレスปอนด์ก่อน"), "ดูเฮดเดอร์ของ resu ปอนด์ก่อน");
        assert_eq!(rom("มิ팅บ่ายสอง"), "มิ ting บ่ายสอง");
        assert_eq!(rom("マイกริด"), "mai กริด");
        assert_eq!(rom("ok Привет"), "ok Privet");
        assert_eq!(rom("rаte limit"), "rate limit");
    }

    #[test]
    fn kana_and_hangul_are_kept_off_latin() {
        assert_eq!(rom("ok 가ok"), "ok ga ok");
        assert_eq!(rom("okマイ2"), "ok mai 2");
        assert_eq!(rom("ok서버 ok"), "ok seobeo ok");
        // Cyrillic homoglyphs stay inside the Latin word.
        assert_eq!(rom("ok pеrf"), "ok perf");
    }

    #[test]
    fn mixed_runs_are_romanized_piece_by_piece() {
        assert_eq!(rom("ทดสอบрейтレス"), "ทดสอบ reyt resu");
        assert_eq!(rom("ทดสอบレス서버"), "ทดสอบ resu seobeo");
    }

    #[test]
    fn a_thai_mark_after_the_run_is_dropped() {
        assert_eq!(rom("マイ่"), "mai");
        assert_eq!(rom("ใช้マイ่กริด"), "ใช้ mai กริด");
    }

    #[test]
    fn kana_digraphs_gemination_and_long_vowels() {
        for (kana, latin) in [
            ("チャット", "chatto"),
            ("ミーティング", "mitingu"),
            ("ショー", "sho"),
            ("きゃく", "kyaku"),
            ("ファイル", "fairu"),
            ("マッチ", "matchi"),
            ("ウィキ", "wiki"),
            ("ジェイ", "jei"),
        ] {
            assert_eq!(
                rom(&format!("ทดสอบ{kana}")),
                format!("ทดสอบ {latin}"),
                "{kana}"
            );
        }
    }

    #[test]
    fn hangul_syllables() {
        assert_eq!(rom("ok서버"), "ok seobeo");
        assert_eq!(rom("ok한국"), "ok hanguk");
        assert_eq!(rom("เว็บ훅เป็น"), "เว็บ huk เป็น");
    }

    #[test]
    fn leaves_captions_han_and_plain_text() {
        for s in [
            "ありがとう",
            "감사합니다",
            "рейт",
            "สวัสดี アイウエオカキ",
            "ใช้เจม玛ใน",
            "ok ご視聴ありがとう",
            "ok ー",
            "ok ・",
            "วันนี้อากาศดี",
            "",
        ] {
            assert_eq!(romanize_embedded(s), (s.to_string(), false), "{s}");
        }
    }

    #[test]
    fn space_delimited_kana_and_hangul_words_are_captions() {
        for s in [
            "ขอบคุณครับ 감사합니다",
            "โอเคครับ ありがとう",
            "ok 시청해 주셔서 감사합니다.",
            "ประชุมเสร็จแล้ว 감사합니다",
            "วันนี้พอแค่นี้ ありがとう",
            "เลิกงานแล้ว 시청해주셔서 감사합니다",
            "ไปกินข้าว おやすみ",
            "สวัสดี 안녕하세요",
            "ok 감사합니다",
            "ok 서버 ok",
        ] {
            assert_eq!(romanize_embedded(s), (s.to_string(), false), "{s}");
        }
    }

    #[test]
    fn too_many_glued_runs_are_left_alone() {
        for s in [
            "ok시청ok해주ok셔서ok감사",
            "กาマイกาマイกาマイกาマイ",
            "กาマイマイマกาマイマイマกาマイマイマ",
        ] {
            assert_eq!(romanize_embedded(s), (s.to_string(), false), "{s}");
        }
        assert_eq!(rom("กาマイกาマイ"), "กา mai กา mai");
    }
}
