use oliv_pipeline::metrics::{normalize, tokenize};
use serde_json::{Value, json};

pub fn distance<T: PartialEq>(a: &[T], b: &[T]) -> usize {
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, left) in a.iter().enumerate() {
        let mut current = vec![i + 1];
        for (j, right) in b.iter().enumerate() {
            current.push(
                (current[j] + 1)
                    .min(previous[j + 1] + 1)
                    .min(previous[j] + usize::from(left != right)),
            );
        }
        previous = current;
    }
    previous[b.len()]
}
pub fn score(reference: &str, hypothesis: &str, keywords: &[String]) -> Value {
    let reference = normalize(reference);
    let hypothesis = normalize(hypothesis);
    let rc: Vec<_> = reference.chars().filter(|c| !c.is_whitespace()).collect();
    let hc: Vec<_> = hypothesis.chars().filter(|c| !c.is_whitespace()).collect();
    let rt = tokenize(&reference);
    let ht = tokenize(&hypothesis);
    let hyp: String = hc.iter().collect();
    let recall = if keywords.is_empty() {
        None
    } else {
        Some(
            keywords
                .iter()
                .filter(|k| {
                    let key: String = normalize(k)
                        .chars()
                        .filter(|c| !c.is_whitespace())
                        .collect();
                    hyp.contains(&key)
                })
                .count() as f64
                / keywords.len() as f64,
        )
    };
    json!({"cer":distance(&rc,&hc) as f64/rc.len().max(1) as f64,
        "wer":distance(&rt,&ht) as f64/rt.len().max(1) as f64,"kw_recall":recall,
        "ref_chars":rc.len(),"ref_tokens":rt.len()})
}
pub fn exact(text: &str) -> String {
    text.replace('\u{200b}', "")
        .split('\n')
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_lowercase()
}
pub fn bucket(id: &str) -> String {
    let prefix: String = id.chars().take_while(|c| c.is_ascii_lowercase()).collect();
    if prefix.is_empty() { id.into() } else { prefix }
}
pub fn segment(text: &str) -> String {
    oliv_pipeline::tokenize::word_tokenize(text, true)
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalized_thai_and_english() {
        let s = score(
            "สวัสดีครับ PostgreSQL!",
            "สวัสดีครับ postgresql",
            &["PostgreSQL".into()],
        );
        assert_eq!(s["wer"], 0.0);
        assert_eq!(s["cer"], 0.0);
        assert_eq!(s["kw_recall"], 1.0);
    }
    #[test]
    fn omissions_and_empty_hypotheses() {
        assert_eq!(score("Hello world", "Hello", &[])["wer"], 0.5);
        assert_eq!(score("กข", "", &[])["cer"], 1.0);
        assert_eq!(score("", "", &[])["wer"], 0.0);
    }
    #[test]
    fn edit_operations_and_linebreaks() {
        assert_eq!(distance(&['ก', 'ข', 'ค'], &['ก', 'ง', 'ค', 'จ']), 2);
        assert_ne!(exact("a\nb"), exact("a b"));
        assert_eq!(exact(" A\n B "), "a\nb");
    }
    #[test]
    fn semantic_segmentation_handles_long_thai() {
        assert!(segment("วันนี้จะทดสอบระบบภาษาไทย").contains(' '));
        assert_eq!(segment("hello  world"), "hello world");
    }
}
