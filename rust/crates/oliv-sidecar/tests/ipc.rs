use serde_json::{Value, json};
use std::io::Write;
use std::process::{Command, Stdio};
fn run(requests: &[Value]) -> Vec<Value> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_oliv-sidecar"))
        .env_remove("OLIV_INFERENCE_EXECUTABLE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    for request in requests {
        writeln!(input, "{request}").unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}
#[test]
fn ping_silence_and_text_work_without_inference() {
    let replies = run(&[
        json!({"id":4,"cmd":"ping"}),
        json!({"id":5,"cmd":"dictate","pcm_b64":"AAAAAA=="}),
        json!({"id":6,"cmd":"text","cleanup":false,"format_commands":true,"text":"hello new line world"}),
    ]);
    assert_eq!(replies.len(), 3);
    assert_eq!(replies[0]["runtime"], "rust-core");
    assert_eq!(replies[0]["id"], 4);
    assert_eq!(replies[1]["no_speech"], true);
    assert_eq!(replies[2]["final"], "hello\nworld");
}
#[test]
fn bad_request_does_not_poison_following_request() {
    let replies = run(&[
        json!(["not an object"]),
        json!({"id":2,"cmd":"dictate","pcm_b64":"invalid"}),
        json!({"id":3,"cmd":"ping"}),
    ]);
    assert_eq!(replies[0]["code"], "invalidRequest");
    assert_eq!(replies[1]["ok"], false);
    assert_eq!(replies[2]["ok"], true);
    assert_eq!(replies[2]["id"], 3);
}
