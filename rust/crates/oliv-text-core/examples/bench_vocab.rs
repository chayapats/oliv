//! Rough timing of the dictionary passes at a given size:
//! `cargo run --release -p oliv-text-core --example bench_vocab -- 1000`
use oliv_text_core::phonetic::{correct_with_vocab, vocab_hint};
use oliv_text_core::user_dictionary::{Entry, UserDictionary};
use std::time::Instant;
fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(1000);
    let stems = [
        "Grafana",
        "Koolify",
        "Neovim",
        "Zedd",
        "Raycast",
        "Jenkins",
        "Terraform",
    ];
    let entries: Vec<Entry> = (0..n)
        .map(|i| Entry {
            word: format!("{}{}", stems[i % stems.len()], i),
            correction: (i % 2 == 0).then(|| format!("heard{i}")),
            enabled: true,
            starred: false,
        })
        .collect();
    let text = "วันนี้เราจะ deploy grafannah กับ kubernetes แล้วเช็ค log ใน SHA สองห้าหก ก่อนประชุมบ่ายสามโมง heard10 ด้วยนะครับ";
    let t = Instant::now();
    let d = UserDictionary::new(&entries);
    println!("n={n} build {:?}", t.elapsed());
    let t = Instant::now();
    for _ in 0..10 {
        d.apply_corrections(text);
    }
    println!("corrections avg {:?}", t.elapsed() / 10);
    let t = Instant::now();
    for _ in 0..10 {
        d.apply_numerals(text);
    }
    println!("numerals avg {:?}", t.elapsed() / 10);
    let t = Instant::now();
    for _ in 0..3 {
        correct_with_vocab(text, d.vocabulary());
    }
    println!("fuzzy avg {:?}", t.elapsed() / 3);
    let t = Instant::now();
    for _ in 0..3 {
        vocab_hint(text, d.vocabulary());
    }
    println!("hint avg {:?}", t.elapsed() / 3);
}
