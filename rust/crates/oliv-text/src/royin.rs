//! pythainlp 5.3.4 `romanize(text, engine="royin")` (`transliterate/core.py` +
//! `transliterate/royin.py`), ported line by line.

use std::sync::LazyLock;

use regex::Regex;

use crate::tokenize::word_tokenize;

const THAI_CONSONANTS: &str = "กขฃคฅฆงจฉชซฌญฎฏฐฑฒณดตถทธนบปผฝพฟภมยรลวศษสหฬอฮ";
const ROMANIZED_VOWELS: &str = "aeiou";
const THANTHAKHAT: char = '\u{0e4c}';

const VOWEL_PATTERNS: &str = "เ*ียว,\\1iao
แ*็ว,\\1aeo
เ*ือย,\\1ueai
แ*ว,\\1aeo
เ*็ว,\\1eo
เ*ว,\\1eo
*ิว,\\1io
*วย,\\1uai
เ*ย,\\1oei
*อย,\\1oi
โ*ย,\\1oi
*ุย,\\1ui
*าย,\\1ai
ไ*ย,\\1ai
*ัย,\\1ai
ไ**,\\1\\2ai
ไ*,\\1ai
ใ*,\\1ai
*ว*,\\1ua\\2
*ัวะ,\\1ua
*ัว,\\1ua
เ*ือะ,\\1uea
เ*ือ,\\1uea
เ*ียะ,\\1ia
เ*ีย,\\1ia
เ*อะ,\\1oe
เ*อ,\\1oe
เ*ิ,\\1oe
*อ,\\1o
เ*าะ,\\1o
เ*็,\\1e
โ*ะ,\\1o
โ*,\\1o
แ*ะ,\\1ae
แ*,\\1ae
เ*าะ,\\1e
*าว,\\1ao
เ*า,\\1ao
เ*,\\1e
*ู,\\1u
*ุ,\\1u
*ื,\\1ue
*ึ,\\1ue
*ี,\\1i
*ิ,\\1i
*ำ,\\1am
*า,\\1a
*ั,\\1a
*ะ,\\1a
#ฤ,\\1rue
$ฤ,\\1ri";

/// `_VOWELS`: (pattern, replacement) applied in order with `re.sub`.
static VOWELS: LazyLock<Vec<(Regex, String)>> = LazyLock::new(|| {
    let pats = VOWEL_PATTERNS
        .replace('*', &format!("([{THAI_CONSONANTS}])"))
        .replace('#', "([คนพมห])")
        .replace('$', "([กตทปศส])");
    pats.split('\n')
        .map(|line| {
            let (p, r) = line.split_once(',').unwrap();
            let r = r.replace("\\1", "${1}").replace("\\2", "${2}");
            (Regex::new(p).unwrap(), r)
        })
        .collect()
});

static RE_NORMALIZE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(&format!(
        "จน์|มณ์|ณฑ์|ทร์|ตร์|[{c}]{t}|[{c}][\u{0e30}-\u{0e39}]{t}|[\u{0e2f}\u{0e46}\u{0e48}-\u{0e4f}\u{0e5a}\u{0e5b}]",
        c = THAI_CONSONANTS,
        t = THANTHAKHAT
    ))
    .unwrap()
});

/// `_CONSONANTS`: (initial, final) romanization.
fn consonant(c: char) -> Option<(&'static str, &'static str)> {
    Some(match c {
        'ก' => ("k", "k"),
        'ข' | 'ฃ' | 'ค' | 'ฅ' | 'ฆ' => ("kh", "k"),
        'ง' => ("ng", "ng"),
        'จ' | 'ฉ' | 'ช' | 'ฌ' => ("ch", "t"),
        'ซ' => ("s", "t"),
        'ญ' => ("y", "n"),
        'ฎ' => ("d", "t"),
        'ฏ' => ("t", "t"),
        'ฐ' | 'ฑ' | 'ฒ' => ("th", "t"),
        'ณ' => ("n", "n"),
        'ด' => ("d", "t"),
        'ต' => ("t", "t"),
        'ถ' | 'ท' | 'ธ' => ("th", "t"),
        'น' => ("n", "n"),
        'บ' => ("b", "p"),
        'ป' => ("p", "p"),
        'ผ' | 'พ' | 'ภ' => ("ph", "p"),
        'ฝ' | 'ฟ' => ("f", "p"),
        'ม' => ("m", "m"),
        'ย' => ("y", ""),
        'ร' => ("r", "n"),
        'ฤ' => ("rue", ""),
        'ล' | 'ฬ' => ("l", "n"),
        'ว' => ("w", ""),
        'ศ' | 'ษ' | 'ส' => ("s", "t"),
        'ห' | 'ฮ' => ("h", ""),
        'อ' => ("", ""),
        _ => return None,
    })
}

fn is_consonant_key(c: char) -> bool {
    consonant(c).is_some()
}

fn is_thai_consonant(c: char) -> bool {
    THAI_CONSONANTS.contains(c)
}

fn normalize(word: &str) -> String {
    RE_NORMALIZE.replace_all(word, "").into_owned()
}

fn replace_vowels(word: &str) -> String {
    let mut w = word.to_string();
    for (re, rep) in VOWELS.iter() {
        w = re.replace_all(&w, rep.as_str()).into_owned();
    }
    w
}

/// Python raises IndexError when `consonants[j]` runs past the end (a `ฤ` that
/// survived the vowel pass counts as a consonant here but not in `consonants`).
struct IndexError;

fn replace_consonants(word: &str, consonants: &[char]) -> Result<String, IndexError> {
    const HO_HIP: char = 'ห';
    const RO_RUA: char = 'ร';
    if consonants.is_empty() {
        return Ok(word.to_string());
    }
    let w: Vec<char> = word.chars().collect();
    let cons = |j: usize| -> Result<(&'static str, &'static str), IndexError> {
        consonants
            .get(j)
            .and_then(|&c| consonant(c))
            .ok_or(IndexError)
    };
    let mut skip = false;
    let mut mod_chars: Vec<String> = Vec::new();
    let mut j = 0usize;
    let mut vowel_seen = false;

    for i in 0..w.len() {
        if skip {
            skip = false;
            j += 1;
        } else if !is_consonant_key(w[i]) {
            vowel_seen = true;
            mod_chars.push(w[i].to_string());
        } else if mod_chars.is_empty() && w[i] == HO_HIP && consonants.len() != 1 {
            j += 1;
        } else if w[i..] == [RO_RUA, RO_RUA] {
            skip = true;
            mod_chars.push("a".into());
            mod_chars.push("n".into());
            vowel_seen = true;
            j += 1;
        } else if w[i..].starts_with(&[RO_RUA, RO_RUA]) {
            skip = true;
            mod_chars.push("a".into());
            vowel_seen = true;
            j += 1;
        } else if !vowel_seen {
            let has_initial = mod_chars
                .iter()
                .any(|c| !c.is_empty() && !ROMANIZED_VOWELS.contains(c.as_str()));
            if !has_initial {
                let initial = cons(j)?.0;
                if !initial.is_empty() {
                    mod_chars.push(initial.into());
                }
                j += 1;
            } else {
                let is_cluster = matches!(w[i], 'ร' | 'ล' | 'ว');
                let is_last = i + 1 >= w.len();
                let has_vowel_next = !is_last && !is_consonant_key(w[i + 1]);
                if is_cluster && (has_vowel_next || !is_last) {
                    mod_chars.push(cons(j)?.0.into());
                    j += 1;
                } else if !is_cluster && !is_last {
                    mod_chars.push("a".into());
                    let initial = cons(j)?.0;
                    if !initial.is_empty() {
                        mod_chars.push(initial.into());
                    }
                    vowel_seen = false;
                    j += 1;
                } else if has_vowel_next {
                    mod_chars.push(cons(j)?.0.into());
                    j += 1;
                } else {
                    // final consonant (last char, or another consonant follows):
                    // implicit 'o' (pythainlp has two identical branches here)
                    mod_chars.push("o".into());
                    mod_chars.push(cons(j)?.1.into());
                    vowel_seen = true;
                    j += 1;
                }
            }
        } else {
            let has_vowel_next = i + 1 < w.len() && !is_consonant_key(w[i + 1]);
            if has_vowel_next {
                mod_chars.push(cons(j)?.0.into());
                vowel_seen = false;
                j += 1;
            } else {
                mod_chars.push(cons(j)?.1.into());
                j += 1;
            }
        }
    }
    Ok(mod_chars.concat())
}

fn romanize_word(word: &str) -> Result<String, IndexError> {
    if word == "ห" {
        return Ok(String::new());
    }
    let mut w = replace_vowels(&normalize(word));
    let consonants: Vec<char> = w.chars().filter(|&c| is_thai_consonant(c)).collect();
    let chars: Vec<char> = w.chars().collect();
    if chars.len() == 2 && consonants.len() == 2 {
        w = format!("{}o{}", chars[0], chars[1]);
    }
    replace_consonants(&w, &consonants)
}

fn should_add_syllable_separator(prev_word: &str, curr_word: &str, prev_rom: &str) -> bool {
    if prev_rom.is_empty() || curr_word.chars().count() < 2 {
        return false;
    }
    let prev_after_vowels = replace_vowels(&normalize(prev_word));
    let prev_consonants = prev_word.chars().filter(|&c| is_thai_consonant(c)).count();
    let has_explicit_vowel_prev = prev_after_vowels.chars().count() > prev_consonants;
    let cons_in_word = curr_word.chars().filter(|&c| is_thai_consonant(c)).count();
    let vowels_in_word = curr_word.chars().count() - cons_in_word;
    has_explicit_vowel_prev
        && cons_in_word == 2
        && vowels_in_word == 0
        && !ROMANIZED_VOWELS.contains(prev_rom.chars().last().unwrap())
}

/// `royin.romanize(text)` for one space-free subword.
fn romanize_subword(text: &str) -> Result<String, IndexError> {
    let words = word_tokenize(text, true);
    let mut out: Vec<String> = Vec::new();
    for (i, word) in words.iter().enumerate() {
        let mut rom = romanize_word(word)?;
        if i > 0 && !rom.is_empty() {
            let prev_rom = out.last().map(String::as_str).unwrap_or("");
            if should_add_syllable_separator(&words[i - 1], word, prev_rom) {
                rom = format!("a{rom}");
            }
        }
        out.push(rom);
    }
    Ok(out.concat())
}

/// `romanize(text, engine="royin")`; `Err` when pythainlp raises (IndexError).
pub fn romanize(text: &str) -> Result<String, &'static str> {
    if text.is_empty() {
        return Ok(String::new());
    }
    let parts: Result<Vec<String>, IndexError> = text.split(' ').map(romanize_subword).collect();
    parts.map(|p| p.join(" ")).map_err(|_| "IndexError")
}
