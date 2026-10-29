//! `~/oliv/config.toml` (`[api]`, plus where Gemma and Whisper listen) and the
//! bearer token in `~/oliv/api.token`. Mirrors the locks in `oliv_config.py`.

use std::net::Ipv4Addr;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::time::Duration;

use toml::{Table, Value};

use crate::dictate::AsrProfile;
use crate::llm::Prompt;

/// New installs use loopback behind an outbound tunnel. Binding one private
/// overlay address (see [`is_private_overlay`]) remains an explicit choice, and
/// the only one where legacy auth is allowed; wildcard/public listeners are refused.
pub const API_BIND: (&str, u16) = ("127.0.0.1", 8083);
const GEMMA_BIND: (&str, u16) = ("127.0.0.1", 8081);
const WHISPER_BIND: (&str, u16) = ("127.0.0.1", 8082);
const MIN_TOKEN_LEN: usize = 32;

#[derive(Clone, Debug)]
pub struct Config {
    pub listen: String,
    pub gemma_url: String,
    pub whisper_url: String,
    pub prompt: Prompt,
    /// The STT model `start.sh` runs; a request may override it.
    pub asr_profile: AsrProfile,
    pub asr_concurrency: usize,
    pub llm_timeout: Duration,
    pub auth_mode: AuthMode,
}

#[derive(Clone, Debug, PartialEq)]
pub enum AuthMode {
    Keys,
    Legacy,
}

/// An IPv4 literal in 100.64.0.0/10 (RFC 6598), the range private overlay
/// networks such as Tailscale or Headscale assign. Mirrors `oliv_config.py`.
pub fn is_private_overlay(host: &str) -> bool {
    match host.parse::<Ipv4Addr>() {
        Ok(ip) => {
            let [a, b, ..] = ip.octets();
            ip.to_string() == host && a == 100 && (64..128).contains(&b)
        }
        Err(_) => false,
    }
}

fn section<'a>(t: &'a Table, name: &str) -> Result<Option<&'a Table>, String> {
    match t.get(name) {
        None => Ok(None),
        Some(Value::Table(s)) => Ok(Some(s)),
        Some(_) => Err(format!("[{name}] must be a table")),
    }
}

fn check_bind(s: Option<&Table>, name: &str, (host, port): (&str, u16)) -> Result<String, String> {
    let got_host = s.and_then(|s| s.get("host")).and_then(Value::as_str);
    let got_port = s.and_then(|s| s.get("port")).and_then(Value::as_integer);
    if got_host != Some(host) || got_port != Some(i64::from(port)) {
        return Err(format!("{name} must listen on {host}:{port} only"));
    }
    Ok(format!("{host}:{port}"))
}

/// Parse the text of `config.toml`. A missing `[api]` means the defaults.
pub fn parse(text: &str) -> Result<Config, String> {
    let t: Table = text.parse().map_err(|e| format!("config.toml: {e}"))?;
    let gemma = check_bind(section(&t, "gemma")?, "gemma", GEMMA_BIND)?;
    let whisper = check_bind(section(&t, "whisper")?, "whisper", WHISPER_BIND)?;
    let api = section(&t, "api")?;
    let listen = match api {
        None => format!("{}:{}", API_BIND.0, API_BIND.1),
        Some(section) => {
            for key in section.keys() {
                if ![
                    "host",
                    "port",
                    "prompt",
                    "llm_timeout",
                    "auth_mode",
                    "asr_profile",
                    "asr_concurrency",
                ]
                .contains(&key.as_str())
                {
                    return Err(format!("unknown api setting: {key}"));
                }
            }
            let host = section.get("host").and_then(Value::as_str).unwrap_or("");
            if host != API_BIND.0 && !is_private_overlay(host) {
                return Err(
                    "api host must be 127.0.0.1 or a private overlay address (100.64.0.0/10)"
                        .into(),
                );
            }
            check_bind(api, "api", (host, API_BIND.1))?
        }
    };
    let auth_mode = match api.and_then(|a| a.get("auth_mode")) {
        None => AuthMode::Keys,
        Some(Value::String(s)) if s == "keys" => AuthMode::Keys,
        Some(Value::String(s))
            if s == "legacy"
                && api
                    .and_then(|a| a.get("host"))
                    .and_then(Value::as_str)
                    .is_some_and(is_private_overlay) =>
        {
            AuthMode::Legacy
        }
        _ => {
            return Err(
                "api.auth_mode must be keys; legacy is allowed only on a private overlay address"
                    .into(),
            );
        }
    };
    let prompt = match api.and_then(|a| a.get("prompt")) {
        None => Prompt::default(),
        Some(Value::String(p)) => p.parse()?,
        Some(_) => return Err("api.prompt must be a string".into()),
    };
    let asr_profile = match api.and_then(|a| a.get("asr_profile")) {
        None => AsrProfile::default(),
        Some(Value::String(p)) => p.parse().map_err(|e| format!("api.{e}"))?,
        Some(_) => return Err("api.asr_profile must be a string".into()),
    };
    let asr_concurrency = match api.and_then(|a| a.get("asr_concurrency")) {
        None => 1,
        Some(Value::Integer(n))
            if (1..=4).contains(n) && (asr_profile == AsrProfile::Qwen3Asr || *n == 1) =>
        {
            *n as usize
        }
        _ => {
            return Err(
                "api.asr_concurrency must be 1..4; only qwen3asr supports more than 1".into(),
            );
        }
    };
    let llm_timeout = match api.and_then(|a| a.get("llm_timeout")) {
        None => 5,
        Some(Value::Integer(n)) if (1..=30).contains(n) => *n as u64,
        Some(_) => return Err("api.llm_timeout must be whole seconds, 1 to 30".into()),
    };
    Ok(Config {
        listen,
        gemma_url: format!("http://{gemma}"),
        whisper_url: format!("http://{whisper}"),
        prompt,
        asr_profile,
        asr_concurrency,
        llm_timeout: Duration::from_secs(llm_timeout),
        auth_mode,
    })
}

pub fn load(path: &Path) -> Result<Config, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    parse(&text)
}

/// Read the bearer token; the file must be private (no group/other bits).
pub fn load_token(path: &Path) -> Result<String, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if meta.permissions().mode() & 0o077 != 0 {
        return Err(format!("{} must be mode 600", path.display()));
    }
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let token = text.trim().to_string();
    if token.len() < MIN_TOKEN_LEN || !token.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(format!(
            "{}: token must be at least {MIN_TOKEN_LEN} printable ASCII characters",
            path.display()
        ));
    }
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "[gemma]\nhost = \"127.0.0.1\"\nport = 8081\n\
                        [whisper]\nhost = \"127.0.0.1\"\nport = 8082\n";

    #[test]
    fn qwen_concurrency_is_explicit_and_other_profiles_stay_serial() {
        let config = format!(
            "{BASE}[api]\nhost=\"127.0.0.1\"\nport=8083\nasr_profile=\"qwen3asr\"\nasr_concurrency=2\n"
        );
        assert_eq!(parse(&config).unwrap().asr_concurrency, 2);
        for bad in ["0", "5", "true", "\"2\""] {
            assert!(
                parse(&config.replace("asr_concurrency=2", &format!("asr_concurrency={bad}")))
                    .is_err()
            );
        }
        assert!(parse(&config.replace("qwen3asr", "turbo")).is_err());
        assert_eq!(parse(BASE).unwrap().asr_concurrency, 1);
    }
    #[test]
    fn defaults_without_api_section() {
        let c = parse(BASE).unwrap();
        assert_eq!(c.listen, "127.0.0.1:8083");
        assert_eq!(c.auth_mode, AuthMode::Keys);
        assert_eq!(c.prompt, Prompt::V2);
        assert_eq!(c.asr_profile, AsrProfile::Turbo);
        assert_eq!(c.llm_timeout, Duration::from_secs(5));
        assert_eq!(c.gemma_url, "http://127.0.0.1:8081");
    }

    #[test]
    fn api_section() {
        let c = parse(&format!(
            "{BASE}[api]\nhost = \"100.64.0.10\"\nport = 8083\nprompt = \"V4\"\nllm_timeout = 7\n\
             asr_profile = \"qwen3asr\"\n"
        ))
        .unwrap();
        assert_eq!(c.prompt, Prompt::V4);
        assert_eq!(c.asr_profile, AsrProfile::Qwen3Asr);
        assert_eq!(c.llm_timeout, Duration::from_secs(7));
    }

    #[test]
    fn refuses_other_binds() {
        for api in ["0.0.0.0", "::", "192.168.1.5", "example.com"] {
            let t = format!("{BASE}[api]\nhost = \"{api}\"\nport = 8083\n");
            assert!(parse(&t).is_err(), "{api}");
        }
        for api in [
            "100.128.0.1",
            "100.63.255.255",
            "100.064.0.10",
            "100.64.0.10 ",
        ] {
            let t = format!("{BASE}[api]\nhost = \"{api}\"\nport = 8083\n");
            assert!(parse(&t).is_err(), "{api}");
        }
        let t = format!("{BASE}[api]\nhost = \"100.64.0.10\"\nport = 9999\n");
        assert!(parse(&t).is_err());
        let t = BASE.replace("127.0.0.1\"\nport = 8081", "0.0.0.0\"\nport = 8081");
        assert!(parse(&t).is_err());
    }

    #[test]
    fn repo_config_toml() {
        // vm/config.toml is the self-host starting point: typhoon-whisper-turbo, one ASR slot.
        let c = parse(include_str!("../../vm/config.toml")).unwrap();
        assert_eq!(c.listen, "127.0.0.1:8083");
        assert_eq!(c.auth_mode, AuthMode::Keys);
        assert_eq!(c.prompt, Prompt::V5);
        assert_eq!(c.asr_profile, AsrProfile::Turbo);
        assert_eq!(c.asr_concurrency, 1);
    }

    #[test]
    fn refuses_bad_values() {
        let t = format!("{BASE}[api]\nhost = \"100.64.0.10\"\nport = 8083\nprompt = \"v9\"\n");
        assert!(parse(&t).is_err());
        let t = format!("{BASE}[api]\nhost = \"100.64.0.10\"\nport = 8083\nllm_timeout = 0\n");
        assert!(parse(&t).is_err());
        for bad in ["\"qwen\"", "1"] {
            let t =
                format!("{BASE}[api]\nhost = \"100.64.0.10\"\nport = 8083\nasr_profile = {bad}\n");
            assert!(parse(&t).is_err(), "{bad}");
        }
    }

    #[test]
    fn legacy_requires_an_explicit_private_bind_and_unknown_settings_fail() {
        let t = format!("{BASE}[api]\nhost=\"127.0.0.1\"\nport=8083\nauth_mode=\"legacy\"\n");
        assert!(parse(&t).is_err());
        let t = t.replace("host=\"127.0.0.1\"", "host=\"100.64.0.10\"");
        assert_eq!(parse(&t).unwrap().auth_mode, AuthMode::Legacy);
        assert!(parse(&(t + "auth_mdoe=\"keys\"\n")).is_err());
    }
}
