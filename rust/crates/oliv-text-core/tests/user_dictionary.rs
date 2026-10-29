//! User dictionary behavior shared by the Mac app and the OLIV server.

use oliv_text_core::phonetic::correct_with_vocab;
use oliv_text_core::user_dictionary::{Entry, UserDictionary, clean_field, dedupe_key};

fn e(word: &str, correction: Option<&str>) -> Entry {
    Entry {
        word: word.into(),
        correction: correction.map(Into::into),
        enabled: true,
        starred: false,
    }
}

fn starred(mut entry: Entry) -> Entry {
    entry.starred = true;
    entry
}

fn disabled(mut entry: Entry) -> Entry {
    entry.enabled = false;
    entry
}

fn dict(entries: &[Entry]) -> UserDictionary {
    UserDictionary::new(entries)
}

fn fixed(text: &str, n: usize) -> (String, usize) {
    (text.to_string(), n)
}

// --- entries -------------------------------------------------------------

#[test]
fn fields_are_trimmed_and_need_letters_or_digits() {
    assert_eq!(clean_field("  Grafana "), Some("Grafana"));
    assert_eq!(clean_field("ชยพัฒน์"), Some("ชยพัฒน์"));
    for bad in ["", "   ", "!!!", "…"] {
        assert_eq!(clean_field(bad), None, "{bad:?}");
    }
    assert!(clean_field(&"ก".repeat(100)).is_some());
    assert!(clean_field(&"ก".repeat(101)).is_none());
}

#[test]
fn dedupe_ignores_latin_case_but_not_thai() {
    assert_eq!(dedupe_key("Koolify"), dedupe_key(" KOOLIFY "));
    assert_ne!(dedupe_key("เจนจิรา"), dedupe_key("เจนจิลา"));
}

#[test]
fn vocabulary_is_enabled_valid_starred_first_and_deduped() {
    let d = dict(&[
        e("beta", None),
        starred(e("Alpha", None)),
        e("BETA", None),
        starred(e("Koolify", Some("koolify"))),
        e("!!!", None),
        disabled(starred(e("Gamma", None))),
    ]);
    assert_eq!(d.vocabulary(), ["Alpha", "Koolify", "beta"]);
}

#[test]
fn merged_vocabulary_puts_dictionary_first() {
    let d = dict(&[starred(e("Koolify", None)), e("Legacy", None)]);
    let legacy = vec!["legacy".to_string(), "Other".to_string(), " ".to_string()];
    assert_eq!(d.merged_vocabulary(&legacy), ["Koolify", "Legacy", "Other"]);
    assert_eq!(dict(&[]).merged_vocabulary(&legacy), legacy);
}

// --- corrections ---------------------------------------------------------

#[test]
fn correction_outputs_the_exact_word() {
    let d = dict(&[e("Koolify", Some("koolify"))]);
    assert_eq!(
        d.apply_corrections("say KOOlify now"),
        fixed("say Koolify now", 1)
    );
}

#[test]
fn longest_correction_wins_and_first_entry_owns_a_phrase() {
    let d = dict(&[
        e("Kool", Some("kool")),
        e("Koolify", Some("koolify")),
        e("Shadow", Some("KOOL")),
    ]);
    assert_eq!(
        d.apply_corrections("i love koolify"),
        fixed("i love Koolify", 1)
    );
    assert_eq!(d.apply_corrections("so kool"), fixed("so Kool", 1));
}

#[test]
fn disabled_and_invalid_corrections_do_nothing() {
    let d = dict(&[
        disabled(e("Koolify", Some("koolify"))),
        e("Punct", Some("!!!")),
    ]);
    assert_eq!(d.apply_corrections("koolify !!!"), fixed("koolify !!!", 0));
}

#[test]
fn latin_corrections_respect_word_boundaries() {
    let d = dict(&[e("the", Some("teh"))]);
    assert_eq!(d.apply_corrections("teh tehran"), fixed("the tehran", 1));
    assert_eq!(d.apply_corrections("xteh teh2"), fixed("xteh teh2", 0));
}

#[test]
fn punctuation_stays_attached() {
    let d = dict(&[e("Koolify", Some("koolify"))]);
    assert_eq!(
        d.apply_corrections("koolify, now."),
        fixed("Koolify, now.", 1)
    );
}

#[test]
fn thai_corrections_are_exact_and_never_split_a_real_word() {
    let prefix = dict(&[e("CLOCK", Some("นาฬิก"))]);
    assert_eq!(prefix.apply_corrections("นาฬิกา"), fixed("นาฬิกา", 0));
    let full = dict(&[e("watch", Some("นาฬิกา"))]);
    assert_eq!(
        full.apply_corrections("ซื้อนาฬิกาใหม่"),
        fixed("ซื้อ watch ใหม่", 1)
    );
}

#[test]
fn thai_name_fix_adds_no_spaces_inside_thai() {
    let d = dict(&[e("เจนจิรา", Some("เจนจิลา"))]);
    assert_eq!(d.apply_corrections("คุณเจนจิลาครับ"), fixed("คุณเจนจิราครับ", 1));
}

#[test]
fn already_correct_text_is_not_counted() {
    let d = dict(&[e("Koolify", Some("koolify"))]);
    assert_eq!(
        d.apply_corrections("Koolify is up"),
        fixed("Koolify is up", 0)
    );
}

#[test]
fn legacy_merge_prefers_longer_then_dictionary_and_keeps_legacy_exact() {
    let user = dict(&[e("U", Some("ab"))]);
    let legacy = |pairs: &[(&str, &str)]| -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    };
    assert_eq!(
        user.apply_with_legacy("x ab y", &legacy(&[("ab", "L")])),
        fixed("x U y", 1)
    );
    let user = dict(&[e("U", Some("bc"))]);
    assert_eq!(
        user.apply_with_legacy("abcd", &legacy(&[("abcd", "L")])),
        fixed("L", 1)
    );
    // Legacy keys stay case-sensitive.
    assert_eq!(
        user.apply_with_legacy("say SAY", &legacy(&[("say", "L")])),
        fixed("L SAY", 1)
    );
}

#[test]
fn legacy_only_is_exactly_apply_table() {
    let legacy = vec![
        ("ซี".to_string(), "C".to_string()),
        ("say".to_string(), "L".to_string()),
    ];
    let table: Vec<(&str, &str)> = legacy
        .iter()
        .map(|(k, v)| (k.as_str(), v.as_str()))
        .collect();
    for text in ["ภาษาซีง่าย", "say SAY", "", "nothing here"] {
        assert_eq!(
            dict(&[]).apply_with_legacy(text, &legacy),
            oliv_text_core::dictionary::apply_table(text, &table),
            "{text:?}"
        );
    }
}

// --- Thai numerals -------------------------------------------------------

#[test]
fn numerals_map_both_styles_to_the_word() {
    let d = dict(&[e("SHA256", None)]);
    assert_eq!(
        d.apply_numerals("ใช้ SHA สองห้าหก ครับ"),
        fixed("ใช้ SHA256 ครับ", 1)
    );
    assert_eq!(
        d.apply_numerals("รหัส SHA สองร้อยห้าสิบหก"),
        fixed("รหัส SHA256", 1)
    );
    assert_eq!(d.apply_numerals("sha สองห้าหก"), fixed("SHA256", 1));
}

#[test]
fn numerals_glued_to_thai_get_spaced() {
    let d = dict(&[e("H100", None)]);
    assert_eq!(
        d.apply_numerals("การ์ดจอHหนึ่งร้อยแรงมาก"),
        fixed("การ์ดจอ H100 แรงมาก", 1)
    );
}

#[test]
fn numerals_collapse_a_redundant_full_mention() {
    let d = dict(&[e("SHA256", None)]);
    assert_eq!(d.apply_numerals("SHA256 สองห้าหก"), fixed("SHA256", 1));
    assert_eq!(d.apply_numerals("SHA256สองร้อยห้าสิบหก"), fixed("SHA256", 1));
}

#[test]
fn numerals_leave_everything_else_alone() {
    let d = dict(&[e("SHA256", None)]);
    for text in [
        "ใช้ SHA256 อยู่",    // digits already
        "SHA สอง ห้า",      // 2 ≠ 256 (the next word is separate)
        "SHA256 สอง",      // wrong value
        "SHA2560 สองห้าหก", // different token
        "xSHA สองห้าหก",    // glued to a longer Latin run
    ] {
        assert_eq!(d.apply_numerals(text), fixed(text, 0), "{text:?}");
    }
    // "สอง" heads the spoken "สองร้อย": never split a numeral run.
    assert_eq!(
        dict(&[e("SHA2", None)]).apply_numerals("SHA สองร้อย"),
        fixed("SHA สองร้อย", 0)
    );
    assert_eq!(
        dict(&[disabled(e("SHA256", None))]).apply_numerals("SHA สองห้าหก"),
        fixed("SHA สองห้าหก", 0)
    );
}

// --- LLM guard -----------------------------------------------------------

#[test]
fn lost_words_detects_an_llm_rewriting_a_fixed_word() {
    let d = dict(&[
        e("เจนจิรา", Some("เจนจิลา")),
        e("SHA256", None),
        e("AI", None),
    ]);
    assert_eq!(
        d.lost_words("คุณเจนจิรามาไหม", "คุณ Janejira มาไหม"),
        ["เจนจิรา"]
    );
    assert_eq!(d.lost_words("ใช้ SHA256", "ใช้ sha256"), ["SHA256"]);
    assert!(d.lost_words("คุณเจนจิรามาไหม", "คุณเจนจิรามาไหมคะ").is_empty());
    // Only whole Latin words count: "AI" is not in "MAIL".
    assert!(d.lost_words("check MAIL", "check mail").is_empty());
    assert!(d.lost_words("ไม่มีคำในพจนานุกรม", "อะไรก็ได้").is_empty());
}

// --- fuzzy vocabulary digit guard -----------------------------------------

#[test]
fn fuzzy_vocab_never_snaps_a_bare_prefix_to_a_numbered_word() {
    let vocab = vec!["SHA256".to_string()];
    let (text, fired, _) = correct_with_vocab("SHA สอง", &vocab);
    assert_eq!((text.as_str(), fired), ("SHA สอง", 0));
}

#[test]
fn fuzzy_vocab_still_fixes_digitless_mishearings() {
    let vocab = vec!["Grafana".to_string()];
    let (text, fired, _) = correct_with_vocab("เรียก grafannah หน่อย", &vocab);
    assert_eq!((text.as_str(), fired), ("เรียก Grafana หน่อย", 1));
}
