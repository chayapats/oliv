/// Remove only the letter and attached vowel marks silenced by thanthakhat.
/// Other vowels and tone marks stay intact; this is not a fuzzy spelling key.
pub(crate) fn without_silent_letters(text: &str) -> Vec<char> {
    let mut out: Vec<char> = Vec::with_capacity(text.len());
    for c in text.chars() {
        if c == '\u{e4c}' {
            while out
                .last()
                .is_some_and(|p| matches!(p, '\u{e34}'..='\u{e39}'))
            {
                out.pop();
            }
            out.pop();
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::without_silent_letters;

    #[test]
    fn removes_silenced_consonants_and_their_vowels_only() {
        let normalize = |s: &str| without_silent_letters(s).into_iter().collect::<String>();
        assert_eq!(normalize("พันธุ์"), "พัน");
        assert_eq!(normalize("เซิร์ฟเวอร์"), "เซิฟเวอ");
        assert_eq!(normalize("รีสตาร์ท"), "รีสตาท");
        assert_eq!(normalize("กี่โมงแล้ว"), "กี่โมงแล้ว");
    }
}
