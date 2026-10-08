//! The cleanup LLM call: prompt selection, request body (`_build_prompt` as a
//! single user turn to llama-server's `/v1/chat/completions`), and a mockable
//! `Llm` trait so tests never touch the network.

use std::fmt;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Mutex, OnceLock};

use serde_json::{Value, json};

use crate::guardrail::STOPS;
use crate::prompts_text::{CLEANUP_V2, CLEANUP_V3, CLEANUP_V4, CLEANUP_V5};

pub const MAX_TOKENS: u32 = 200;
/// Cleanup system prompt version (`OLIV_CLEANUP_PROMPT`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Prompt {
    #[default]
    V2,
    V3,
    V4,
    V5,
    /// An experimental prompt read from `<root>/prompts/<name>.txt` (eval only).
    Custom(&'static CustomPrompt),
}

#[derive(Debug, PartialEq, Eq, Hash)]
pub struct CustomPrompt {
    pub name: &'static str,
    pub text: &'static str,
}

static PROMPTS_DIR: OnceLock<PathBuf> = OnceLock::new();
static CUSTOM: Mutex<Vec<&'static CustomPrompt>> = Mutex::new(Vec::new());

/// Where experimental prompts live. Without this, only v2 to v5 exist.
pub fn set_prompts_dir(dir: PathBuf) {
    let _ = PROMPTS_DIR.set(dir);
}

/// Load `name` from the prompts dir. The file is read on every call, so an edit
/// takes effect at once; a changed text is leaked as a new entry (eval-sized).
fn custom(name: &str) -> Option<Prompt> {
    let ok = !name.is_empty()
        && name.len() <= 40
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if !ok {
        return None;
    }
    let text = std::fs::read_to_string(PROMPTS_DIR.get()?.join(format!("{name}.txt"))).ok()?;
    let text = text.trim_end_matches('\n');
    let mut all = CUSTOM.lock().ok()?;
    if let Some(c) = all.iter().find(|c| c.name == name && c.text == text) {
        return Some(Prompt::Custom(c));
    }
    let c: &'static CustomPrompt = Box::leak(Box::new(CustomPrompt {
        name: Box::leak(name.to_string().into_boxed_str()),
        text: Box::leak(text.to_string().into_boxed_str()),
    }));
    all.push(c);
    Some(Prompt::Custom(c))
}

impl Prompt {
    pub fn text(self) -> &'static str {
        match self {
            Prompt::V2 => CLEANUP_V2,
            Prompt::V3 => CLEANUP_V3,
            Prompt::V4 => CLEANUP_V4,
            Prompt::V5 => CLEANUP_V5,
            Prompt::Custom(c) => c.text,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Prompt::V2 => "v2",
            Prompt::V3 => "v3",
            Prompt::V4 => "v4",
            Prompt::V5 => "v5",
            Prompt::Custom(c) => c.name,
        }
    }
}

impl FromStr for Prompt {
    type Err = String;

    /// Case-insensitive like Oliv's `_PROMPTS.get(name.lower())`.
    fn from_str(s: &str) -> Result<Self, String> {
        match s.to_lowercase().as_str() {
            "v2" => Ok(Prompt::V2),
            "v3" => Ok(Prompt::V3),
            "v4" => Ok(Prompt::V4),
            "v5" => Ok(Prompt::V5),
            other => {
                custom(other).ok_or_else(|| format!("unknown prompt {s:?} (want v2, v3, v4 or v5)"))
            }
        }
    }
}

/// `_hint_line(hints)`: the conditional user-vocabulary hint.
pub fn hint_line(hints: &[String]) -> String {
    if hints.is_empty() {
        return String::new();
    }
    format!(
        "\n\nThe user's vocabulary may include: {}. If a Thai-script word clearly SOUNDS like \
         one of these, restore that exact spelling. If its sound is not present, ignore the \
         list -- never add a term that was not spoken.",
        hints.join(", ")
    )
}

/// One cleanup call: the post-dictionary text plus any vocab hints.
#[derive(Clone, Copy, Debug)]
pub struct Request<'a> {
    pub prompt: Prompt,
    pub text: &'a str,
    pub hints: &'a [String],
}

impl Request<'_> {
    /// The user-turn content (`_build_prompt` without the chat template).
    pub fn content(&self) -> String {
        format!(
            "{}{}\n\nIN:  {}\nOUT: ",
            self.prompt.text(),
            hint_line(self.hints),
            self.text
        )
    }

    /// The `/v1/chat/completions` body: greedy, thinking off, Oliv's stop list.
    pub fn body(&self) -> Value {
        json!({
            "messages": [{"role": "user", "content": self.content()}],
            "temperature": 0,
            "max_tokens": MAX_TOKENS,
            "stop": STOPS,
            "chat_template_kwargs": {"enable_thinking": false},
        })
    }
}

#[derive(Debug)]
pub struct LlmError(pub String);

impl fmt::Display for LlmError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for LlmError {}

/// Returns the raw generation for a cleanup request.
pub trait Llm {
    fn generate(&self, req: &Request) -> Result<String, LlmError>;

    /// Whether the backend answers its health check (for `/health`).
    fn healthy(&self) -> bool {
        true
    }
}
