//! Opt-in Groq STT. No SDK, no retries, no redirects, no temporary audio file.
use serde_json::Value;
use std::time::Duration;

pub fn transcribe(
    samples: &[f32],
    language: Option<&str>,
    prompt: Option<&str>,
) -> Result<String, String> {
    let key = std::env::var("GROQ_API_KEY").map_err(|_| "Groq key unavailable")?;
    if key.is_empty() || !key.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("Invalid Groq key".into());
    }
    let wav =
        crate::wav::encode_float_limited(samples, 9_600_000).map_err(|_| "Invalid Groq audio")?;
    // Audio can contain arbitrary bytes: select a boundary absent from all parts.
    let mut boundary = format!("oliv-{}", std::process::id());
    let absent = |b: &str| {
        !wav.windows(b.len()).any(|w| w == b.as_bytes())
            && !language.is_some_and(|s| s.contains(b))
            && !prompt.is_some_and(|s| s.contains(b))
    };
    while !absent(&boundary) {
        boundary.push('x');
    }
    let mut body = Vec::new();
    let mut field = |name: &str, value: &str| {
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        );
    };
    field("model", "whisper-large-v3");
    field("response_format", "json");
    field("temperature", "0");
    if let Some(language) = language {
        field("language", language);
    }
    if let Some(prompt) = prompt.filter(|s| !s.is_empty()) {
        field("prompt", prompt);
    }
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"capture.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes());
    body.extend_from_slice(&wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .tls_config(crate::api::platform_tls())
        .timeout_global(Some(Duration::from_secs(25)))
        .max_redirects(0)
        .http_status_as_error(false)
        .build()
        .into();
    let mut reply = agent
        .post("https://api.groq.com/openai/v1/audio/transcriptions")
        .header("Authorization", &format!("Bearer {key}"))
        .header(
            "Content-Type",
            &format!("multipart/form-data; boundary={boundary}"),
        )
        .send(&body)
        .map_err(|_| "Groq network request failed")?;
    if reply.status().as_u16() != 200 {
        return Err(format!(
            "Groq request failed (HTTP {})",
            reply.status().as_u16()
        ));
    }
    let text = reply
        .body_mut()
        .with_config()
        .limit(1024 * 1024)
        .read_to_string()
        .map_err(|_| "Invalid Groq reply")?;
    let value: Value = serde_json::from_str(&text).map_err(|_| "Invalid Groq reply")?;
    value["text"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| "Invalid Groq reply".into())
}
