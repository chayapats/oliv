use tokenizers::Tokenizer;
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let tok = Tokenizer::from_file(&args[1]).unwrap();
    let text = std::fs::read_to_string(&args[2]).unwrap();
    let encoded = tok.encode(text, false).unwrap();
    println!("{:?}", encoded.get_ids());
}
