//! pythainlp 5.3.4 `word_tokenize(engine="newmm")`, ported line by line from
//! `tokenize/newmm.py`, `tokenize/tcc_p.py` and `tokenize/_utils.py`.
//! Works on code points like Python does.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, HashSet, VecDeque};
use std::sync::LazyLock;

use fancy_regex::Regex;

use crate::data::THAI_WORDS;
use crate::pyu::{is_decimal, is_thai};
use crate::trie::Trie;

const MAX_GRAPH_SIZE: usize = 50;

// --------------------------------------------------------------------------- //
// TCC (tcc_p.py)
// --------------------------------------------------------------------------- //
const RE_TCC: &str = "\
เc็ck
เcctาะk
เccีtยะk
เccีtย(?=[เ-ไก-ฮ]|$)k
เcc็ck
เcิc์ck
เcิtck
เcีtยะ?k
เcืtอะ?k
เc[ิีุู]tย(?=[เ-ไก-ฮ]|$)k
เctา?ะ?k
cัtวะk
c[ัื]tc[ุิะ]?k
c[ิุู]์
c[ะ-ู]tk
cรรc์
c็
ct[ะาำ]?k
ck
แc็c
แcc์
แctะ
แcc็c
แccc์
โctะ
[เ-ไ]ct
ก็
อึ
หึ
";

static PAT_TCC: LazyLock<Regex> = LazyLock::new(|| {
    let d: String = "อูอุ".replace('อ', "");
    let rules: Vec<String> = RE_TCC
        .replace('k', "(cc?[dิ]?[์])?")
        .replace('c', "[ก-ฮ]")
        .replace('t', "[่-๋]?")
        .replace('d', &d)
        .split_whitespace()
        // Python's non-MULTILINE `$` also matches before a final "\n".
        .map(|r| r.replace('$', r"(?=\n?\z)"))
        .collect();
    Regex::new(&format!("^(?:{})", rules.join("|"))).expect("TCC regex")
});

/// `tcc_pos_array(text)`: `valid[i]` is true when `i` ends a Thai character cluster.
fn tcc_pos_array(text: &[char], s: &str) -> Vec<bool> {
    let mut arr = vec![false; text.len() + 1];
    // byte offset of every char, to slice `s` like Python's `text[p:]`
    let mut offs: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
    offs.push(s.len());
    let mut p = 0;
    while p < text.len() {
        let n = match PAT_TCC.find(&s[offs[p]..]) {
            Ok(Some(m)) if m.end() > 0 => s[offs[p]..offs[p] + m.end()].chars().count(),
            _ => 1,
        };
        p += n;
        arr[p] = true;
    }
    arr
}

// --------------------------------------------------------------------------- //
// newmm.py
// --------------------------------------------------------------------------- //

/// `_PAT_NONTHAI.match(text, pos)` → end position:
/// `[-a-zA-Z]+|\d+([,\.]\d+)*|[ \t]+|\r?\n|[^฀-๿ \t\r\n]+`
fn nonthai_match(t: &[char], pos: usize) -> Option<usize> {
    let n = t.len();
    let c = *t.get(pos)?;
    let run = |mut i: usize, f: &dyn Fn(char) -> bool| {
        while i < n && f(t[i]) {
            i += 1;
        }
        i
    };
    if c == '-' || c.is_ascii_alphabetic() {
        return Some(run(pos, &|c| c == '-' || c.is_ascii_alphabetic()));
    }
    if is_decimal(c) {
        let mut i = run(pos, &is_decimal);
        while i + 1 < n && (t[i] == ',' || t[i] == '.') && is_decimal(t[i + 1]) {
            i = run(i + 1, &is_decimal);
        }
        return Some(i);
    }
    if c == ' ' || c == '\t' {
        return Some(run(pos, &|c| c == ' ' || c == '\t'));
    }
    if c == '\r' && t.get(pos + 1) == Some(&'\n') {
        return Some(pos + 2);
    }
    if c == '\n' {
        return Some(pos + 1);
    }
    let other = |c: char| !is_thai(c) && !matches!(c, ' ' | '\t' | '\r' | '\n');
    if other(c) {
        return Some(run(pos, &other));
    }
    None
}

/// `_PAT_THAI_TWOCHARS.match(word)` for a dictionary word: `[ก-ฮ]{,2}$`.
fn thai_twochars(word_len: usize, word: &[char]) -> bool {
    word_len <= 2 && word.iter().all(|c| ('ก'..='ฮ').contains(c))
}

/// First path of `_bfs_paths_graph(graph, start, goal)`.
fn bfs_first_path(graph: &HashMap<usize, Vec<usize>>, start: usize, goal: usize) -> Vec<usize> {
    let mut visited = HashSet::from([start]);
    let mut queue = VecDeque::from([(start, vec![start])]);
    while let Some((vertex, path)) = queue.pop_front() {
        for &pos in graph.get(&vertex).map(Vec::as_slice).unwrap_or(&[]) {
            if pos == goal {
                let mut p = path.clone();
                p.push(pos);
                return p;
            }
            if visited.insert(pos) {
                let mut p = path.clone();
                p.push(pos);
                queue.push_back((pos, p));
            }
        }
    }
    unreachable!("newmm: no path from {start} to {goal}")
}

/// `newmm._onecut` → token boundaries (end positions).
fn onecut(text: &[char], s: &str, dict: &Trie) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut graph: HashMap<usize, Vec<usize>> = HashMap::new();
    let mut graph_size = 0usize;
    let valid = tcc_pos_array(text, s);
    let len_text = text.len();
    let mut pos_list = BinaryHeap::from([Reverse(0usize)]);
    let mut end_pos = 0usize;
    while pos_list.peek().is_some_and(|p| p.0 < len_text) {
        let Reverse(begin_pos) = pos_list.pop().unwrap();
        for wlen in dict.prefixes(text, begin_pos) {
            let cand = begin_pos + wlen;
            if valid[cand] {
                graph.entry(begin_pos).or_default().push(cand);
                graph_size += 1;
                if !pos_list.iter().any(|p| p.0 == cand) {
                    pos_list.push(Reverse(cand));
                }
                if graph_size > MAX_GRAPH_SIZE {
                    break;
                }
            }
        }

        match pos_list.len() {
            1 => {
                let goal = pos_list.peek().unwrap().0;
                let path = bfs_first_path(&graph, end_pos, goal);
                graph_size = 0;
                graph.clear();
                for &pos in &path[1..] {
                    out.push((end_pos, pos));
                    end_pos = pos;
                }
            }
            0 => {
                if let Some(m) = nonthai_match(text, begin_pos) {
                    end_pos = m;
                } else {
                    end_pos = len_text;
                    for pos in begin_pos + 1..len_text {
                        if !valid[pos] {
                            continue;
                        }
                        let has_word = dict.prefixes(text, pos).into_iter().any(|wlen| {
                            valid[pos + wlen] && !thai_twochars(wlen, &text[pos..pos + wlen])
                        });
                        if has_word || nonthai_match(text, pos).is_some() {
                            end_pos = pos;
                            break;
                        }
                    }
                }
                graph_size = 0;
                graph.clear();
                out.push((begin_pos, end_pos));
                pos_list.push(Reverse(end_pos));
            }
            _ => {}
        }
    }
    out
}

/// `newmm.segment(text, custom_dict)` (safe_mode=False).
pub fn segment_with(text: &str, dict: &Trie) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }
    let chars: Vec<char> = text.chars().collect();
    onecut(&chars, text, dict)
        .into_iter()
        .map(|(a, b)| chars[a..b].iter().collect())
        .collect()
}

// --------------------------------------------------------------------------- //
// _utils.py postprocessors
// --------------------------------------------------------------------------- //

/// Matches of `(\d+[\.\,:])+\d+` in `t` (code-point spans), like `finditer`.
fn formatted_num_spans(t: &[char]) -> Vec<(usize, usize)> {
    let n = t.len();
    let digits_end = |mut i: usize| {
        while i < n && is_decimal(t[i]) {
            i += 1;
        }
        i
    };
    let mut out = Vec::new();
    let mut i = 0;
    while i < n {
        if !is_decimal(t[i]) {
            i += 1;
            continue;
        }
        let mut j = digits_end(i);
        let mut groups = 0;
        while j + 1 < n && matches!(t[j], '.' | ',' | ':') && is_decimal(t[j + 1]) {
            j = digits_end(j + 1);
            groups += 1;
        }
        if groups > 0 {
            out.push((i, j));
            i = j;
        } else {
            // no match can start anywhere inside this digit run
            i = j;
        }
    }
    out
}

/// `rejoin_formatted_num`.
pub fn rejoin_formatted_num(segments: Vec<String>) -> Vec<String> {
    let original: Vec<char> = segments.concat().chars().collect();
    let mut matches = formatted_num_spans(&original).into_iter();
    let mut joined = Vec::new();
    let mut pos = 0usize;
    let mut idx = 0usize;
    let mut m = matches.next();
    while idx < segments.len() {
        let Some((mstart, mend)) = m else { break };
        if pos >= mstart {
            let mut connected = String::new();
            while pos < mend && idx < segments.len() {
                connected.push_str(&segments[idx]);
                pos += segments[idx].chars().count();
                idx += 1;
            }
            if !connected.is_empty() {
                joined.push(connected);
            }
            m = matches.next();
        } else {
            pos += segments[idx].chars().count();
            joined.push(segments[idx].clone());
            idx += 1;
        }
    }
    joined.extend(segments.into_iter().skip(idx));
    joined
}

/// `strip_whitespace`: strip `" "` off each token and drop tokens that become empty.
pub fn strip_whitespace(segments: Vec<String>) -> Vec<String> {
    segments
        .into_iter()
        .filter_map(|t| {
            let s = t.trim_matches(' ');
            (!s.is_empty()).then(|| s.to_string())
        })
        .collect()
}

/// `word_tokenize(text, engine="newmm", keep_whitespace=...)` with the built-in dictionary.
pub fn word_tokenize(text: &str, keep_whitespace: bool) -> Vec<String> {
    word_tokenize_with(text, &THAI_WORDS, keep_whitespace)
}

pub fn word_tokenize_with(text: &str, dict: &Trie, keep_whitespace: bool) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }
    let segs = rejoin_formatted_num(segment_with(text, dict));
    if keep_whitespace {
        segs
    } else {
        strip_whitespace(segs)
    }
}
