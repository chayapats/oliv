//! macOS spoken formatting commands, preserving the Python sidecar's fuzzy
//! Thai matching and guarded English matching before per-segment cleanup.
use crate::dictionary::token_spans;
use crate::phonetic::{norm_dist, thai_fold};
use crate::pyu::{has_thai, is_blank, strip};
use std::sync::LazyLock;

const CANONICAL: &[&str] = &[
    "ขึ้นย่อหน้าใหม่",
    "ย่อหน้าใหม่",
    "new paragraph",
    "ขึ้นบรรทัดใหม่",
    "บรรทัดใหม่",
    "new line",
    "newline",
    "bullet point",
];
const THAI: &[(&str, &str)] = &[
    ("ขึ้นย่อหน้าใหม่", "\n\n"),
    ("ย่อหน้าใหม่", "\n\n"),
    ("นิวพารากราฟ", "\n\n"),
    ("ขึ้นบรรทัดใหม่", "\n"),
    ("บรรทัดใหม่", "\n"),
    ("นิวไลน์", "\n"),
    ("บุลเล็ตพอยต์", "\n- "),
];
static ENGLISH: LazyLock<fancy_regex::Regex> = LazyLock::new(|| {
    fancy_regex::Regex::new(
    r"(?i)(?<![A-Za-z0-9฀-๿])(?:newparagraph|new paragraph|bulletpoint|bullet point|new line|newline)(?![A-Za-z0-9฀-๿])"
).unwrap()
});
static FOLDS: LazyLock<Vec<(String, &'static str)>> = LazyLock::new(|| {
    THAI.iter()
        .map(|(p, r)| (thai_fold(p), *r))
        .filter(|(f, _)| f.len() >= 4)
        .collect()
});

pub fn split(text: &str) -> (Vec<String>, Vec<String>) {
    let chars: Vec<char> = text.chars().collect();
    let mut spans: Vec<(usize, usize, &str)> = Vec::new();
    for m in ENGLISH.find_iter(text).flatten() {
        let separator = match m.as_str().to_ascii_lowercase().as_str() {
            "new paragraph" | "newparagraph" => "\n\n",
            "bullet point" | "bulletpoint" => "\n- ",
            _ => "\n",
        };
        spans.push((
            text[..m.start()].chars().count(),
            text[..m.end()].chars().count(),
            separator,
        ));
    }
    if has_thai(text) {
        let tokens = token_spans(text);
        let indices: Vec<usize> = tokens
            .iter()
            .enumerate()
            .filter(|(_, (_, _, t))| !is_blank(t) && has_thai(t))
            .map(|(i, _)| i)
            .collect();
        let mut proposals = Vec::new();
        for a in 0..indices.len() {
            for w in 1..=7 {
                if a + w > indices.len() {
                    break;
                }
                let start = tokens[indices[a]].0;
                let end = tokens[indices[a + w - 1]].1;
                let fold = thai_fold(&chars[start..end].iter().collect::<String>());
                if fold.len() < 4 {
                    continue;
                }
                for (canonical, repl) in FOLDS.iter() {
                    let distance = norm_dist(&fold, canonical);
                    let threshold = if canonical.len() >= 6 { 0.28 } else { 0.0 };
                    if distance <= threshold {
                        proposals.push((distance, start, end, *repl));
                    }
                }
            }
        }
        proposals.sort_by(|a, b| {
            a.0.total_cmp(&b.0)
                .then_with(|| (b.2 - b.1).cmp(&(a.2 - a.1)))
        });
        let mut claimed = vec![false; chars.len()];
        for (_, start, end, repl) in proposals {
            if claimed[start..end].iter().any(|x| *x) {
                continue;
            }
            claimed[start..end].fill(true);
            spans.push((start, end, repl));
        }
    }
    spans.sort();
    let (mut segments, mut separators) = (Vec::new(), Vec::new());
    let mut last = 0;
    for (start, end, repl) in spans {
        if start < last {
            continue;
        }
        segments.push(chars[last..start].iter().collect());
        separators.push(repl.to_string());
        last = end;
    }
    segments.push(chars[last..].iter().collect());
    (segments, separators)
}

pub fn join(segments: &[String], separators: &[String]) -> String {
    static AROUND: LazyLock<regex::Regex> =
        LazyLock::new(|| regex::Regex::new(r"[ \t]*\n[ \t]*").unwrap());
    static RUNS: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"\n{3,}").unwrap());
    let mut text = String::new();
    for (i, segment) in segments.iter().enumerate() {
        text.push_str(segment);
        if let Some(separator) = separators.get(i) {
            text.push_str(separator);
        }
    }
    strip(&RUNS.replace_all(&AROUND.replace_all(&text, "\n"), "\n\n")).to_string()
}

pub fn apply(text: &str) -> (String, usize) {
    let (segments, separators) = split(text);
    if separators.is_empty() {
        return (text.to_string(), 0);
    }
    let segments: Vec<String> = segments.iter().map(|s| strip(s).to_string()).collect();
    (join(&segments, &separators), separators.len())
}

pub fn initial_prompt(
    explicit: Option<&str>,
    vocabulary: &[String],
    format: bool,
) -> Option<String> {
    let mut user = explicit
        .filter(|s| !is_blank(s))
        .map(|s| strip(s).to_string())
        .unwrap_or_else(|| {
            vocabulary
                .iter()
                .map(|s| strip(s))
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(", ")
        });
    let commands = if format {
        CANONICAL.join(", ")
    } else {
        String::new()
    };
    if user.is_empty() && commands.is_empty() {
        return None;
    }
    if !user.is_empty() && !commands.is_empty() {
        user = user
            .chars()
            .take(960usize.saturating_sub(commands.chars().count() + 2))
            .collect();
        return Some(if user.is_empty() {
            commands
        } else {
            format!("{user}, {commands}")
        });
    }
    Some(format!("{user}{commands}").chars().take(960).collect())
}
