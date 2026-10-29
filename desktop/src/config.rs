//! `~/.config/oliv/config.toml`: where oliv-api is, its token, and what each
//! dictation asks for. The file holds the token, so it must be mode 600.
//! The daemon reads it again for every dictation, so edits apply at once.

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use toml::{Table, Value};
use url::{Host, Url};

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, PartialEq)]
pub struct Config {
    /// Base URL of oliv-api; public endpoints require HTTPS.
    pub url: String,
    pub token: String,
    pub request_timeout: Duration,
    pub cleanup: bool,
    pub remove_fillers: bool,
    pub thai_format: bool,
    pub vocabulary: Vec<String>,
    /// `{spoken: written}` in file order (oliv-api applies them in order).
    pub replacements: Vec<(String, String)>,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("token", &"[redacted]")
            .finish_non_exhaustive()
    }
}

pub fn path() -> Result<PathBuf, String> {
    #[cfg(windows)]
    let base = crate::store::env_dir("APPDATA")?;
    #[cfg(unix)]
    let base = match std::env::var_os("XDG_CONFIG_HOME") {
        Some(d) if !d.is_empty() => PathBuf::from(d),
        _ => crate::store::home()?.join(".config"),
    };
    Ok(base.join("oliv/config.toml"))
}

fn table<'a>(t: &'a Table, name: &str) -> Result<Option<&'a Table>, String> {
    match t.get(name) {
        None => Ok(None),
        Some(Value::Table(s)) => Ok(Some(s)),
        Some(_) => Err(format!("[{name}] must be a table")),
    }
}

/// Reject keys we do not know, so a typo is an error instead of silently ignored.
fn known(t: &Table, section: &str, keys: &[&str]) -> Result<(), String> {
    match t.keys().find(|k| !keys.contains(&k.as_str())) {
        Some(k) if section.is_empty() => Err(format!("unknown section [{k}]")),
        Some(k) => Err(format!("unknown key {section}.{k}")),
        None => Ok(()),
    }
}

fn string(s: &Table, section: &str, key: &str) -> Result<String, String> {
    match s.get(key) {
        Some(Value::String(v)) => Ok(v.clone()),
        Some(_) => Err(format!("{section}.{key} must be a string")),
        None => Err(format!("{section}.{key} is missing")),
    }
}

fn flag(s: Option<&Table>, key: &str) -> Result<bool, String> {
    match s.and_then(|s| s.get(key)) {
        None => Ok(true),
        Some(Value::Boolean(b)) => Ok(*b),
        Some(_) => Err(format!("dictate.{key} must be true or false")),
    }
}

/// Public credentials must travel over verified TLS. Plain HTTP remains an
/// explicit development option for loopback, RFC1918 LANs and CGNAT IPs.
fn server_url(raw: &str) -> Result<String, String> {
    let bad =
        || "server.url must be an http(s) URL without credentials, query or fragment".to_string();
    // URL parsers repair these forms; refusing them avoids surprising endpoints.
    if raw.chars().any(|c| c.is_whitespace() || c.is_control()) || raw.contains('\\') {
        return Err(bad());
    }
    let authority = raw
        .split_once("://")
        .ok_or_else(bad)?
        .1
        .split('/')
        .next()
        .unwrap_or("");
    if authority.is_empty() || authority.contains('@') {
        return Err(bad());
    }
    let url = Url::parse(raw).map_err(|_| bad())?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.port() == Some(0)
    {
        return Err(bad());
    }
    let host = url.host().ok_or_else(bad)?;
    if let Host::Domain(name) = host {
        // URL parsing handles IDNA; validate the resulting DNS labels as well.
        if name.len() > 253
            || name
                .strip_suffix('.')
                .unwrap_or(name)
                .split('.')
                .any(|label| {
                    label.is_empty()
                        || label.len() > 63
                        || label.starts_with('-')
                        || label.ends_with('-')
                        || !label
                            .bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
        {
            return Err("server.url has an invalid hostname".into());
        }
    }
    if url.scheme() == "http" {
        let private = match host {
            Host::Ipv4(ip) => {
                let [a, b, _, _] = ip.octets();
                ip.is_loopback() || ip.is_private() || (a == 100 && (64..=127).contains(&b))
            }
            Host::Ipv6(ip) => ip.is_loopback(),
            Host::Domain(name) => name == "localhost",
        };
        if !private {
            return Err("server.url requires https outside loopback/private IPv4 networks".into());
        }
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
}

/// Parse the text of `config.toml`.
pub fn parse(text: &str) -> Result<Config, String> {
    let t: Table = text.parse().map_err(|_: toml::de::Error| {
        "invalid TOML in config (check syntax; values hidden)".to_string()
    })?;
    known(&t, "", &["server", "dictate", "replacements"])?;
    let server = table(&t, "server")?.ok_or("[server] is missing")?;
    known(server, "server", &["url", "token", "timeout_seconds"])?;
    let url = server_url(&string(server, "server", "url")?)?;
    let request_timeout = match server.get("timeout_seconds") {
        None => DEFAULT_TIMEOUT,
        Some(Value::Integer(n)) if (10..=180).contains(n) => Duration::from_secs(*n as u64),
        Some(_) => return Err("server.timeout_seconds must be whole seconds, 10 to 180".into()),
    };
    let token = string(server, "server", "token")?;
    if token.is_empty() || !token.bytes().all(|b| b.is_ascii_graphic()) {
        return Err("server.token must be printable ASCII without spaces".into());
    }
    let dictate = table(&t, "dictate")?;
    if let Some(d) = dictate {
        known(
            d,
            "dictate",
            &["cleanup", "remove_fillers", "thai_format", "vocabulary"],
        )?;
    }
    let vocabulary = match dictate.and_then(|d| d.get("vocabulary")) {
        None => Vec::new(),
        Some(Value::Array(a)) => a
            .iter()
            .map(|v| v.as_str().map(str::to_string))
            .collect::<Option<_>>()
            .ok_or("dictate.vocabulary must be a list of strings")?,
        Some(_) => return Err("dictate.vocabulary must be a list of strings".into()),
    };
    let replacements = match table(&t, "replacements")? {
        None => Vec::new(),
        Some(r) => r
            .iter()
            .map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
            .collect::<Option<_>>()
            .ok_or("[replacements] values must be strings")?,
    };
    Ok(Config {
        url,
        token,
        request_timeout,
        cleanup: flag(dictate, "cleanup")?,
        remove_fillers: flag(dictate, "remove_fillers")?,
        thai_format: flag(dictate, "thai_format")?,
        vocabulary,
        replacements,
    })
}

/// Read and parse `path`; it holds the token, so group/other bits are refused.
pub fn load_from(path: &Path) -> Result<Config, String> {
    #[cfg(unix)]
    {
        let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if meta.permissions().mode() & 0o077 != 0 {
            return Err(format!(
                "{} must be mode 600 (it holds the token)",
                path.display()
            ));
        }
    }
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    parse(&text).map_err(|e| format!("{}: {e}", path.display()))
}

pub fn load() -> Result<Config, String> {
    load_from(&path()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: &str = "[server]\nurl = \"http://100.64.10.20:8083/\"\ntoken = \"abc\"\n";

    #[test]
    fn minimal_turns_every_pass_on() {
        let c = parse(MIN).unwrap();
        assert_eq!(c.url, "http://100.64.10.20:8083");
        assert_eq!(c.token, "abc");
        assert_eq!(c.request_timeout, Duration::from_secs(120));
        assert!(c.cleanup && c.remove_fillers && c.thai_format);
        assert!(c.vocabulary.is_empty() && c.replacements.is_empty());
    }

    #[test]
    fn full() {
        let c = parse(&format!(
            "{MIN}[dictate]\nthai_format = false\nvocabulary = [\"Grafana\", \"คูเบอร์\"]\n\
             [replacements]\n\"ซี\" = \"C\"\n\"เอ\" = \"A\"\n\"บี\" = \"B\"\n"
        ))
        .unwrap();
        assert!(c.cleanup && c.remove_fillers && !c.thai_format);
        assert_eq!(c.vocabulary, ["Grafana", "คูเบอร์"]);
        // File order, not sorted.
        let keys: Vec<_> = c.replacements.iter().map(|(k, _)| k.as_str()).collect();
        assert_eq!(keys, ["ซี", "เอ", "บี"]);
        assert_eq!(c.replacements[0].1, "C");
    }

    #[test]
    fn example_config_parses() {
        let c = parse(include_str!("../config.example.toml")).unwrap();
        assert_eq!(c.url, "https://oliv.example.com");
        assert_eq!(c.request_timeout, DEFAULT_TIMEOUT);
    }

    #[test]
    fn public_https_and_private_http_urls() {
        for url in [
            "https://api.example.com",
            "https://API.example.com:8443/prefix/",
            "https://ตัวอย่าง.com",
            "https://127.0.0.1:8443",
            "http://localhost:8083",
            "http://127.0.0.1:8083",
            "http://127.12.34.56",
            "http://[::1]:8083",
            "http://10.0.0.1:8083",
            "http://172.16.0.1",
            "http://172.31.255.254",
            "http://192.168.1.2",
            "http://100.64.0.1",
            "http://100.127.255.254",
            "http://100.64.10.20:8083",
        ] {
            assert!(server_url(url).is_ok(), "{url}");
        }
        assert_eq!(
            server_url("https://API.example.com:8443/prefix/").unwrap(),
            "https://api.example.com:8443/prefix"
        );
    }

    #[test]
    fn rejects_public_plaintext_and_ambiguous_or_credential_urls() {
        for url in [
            "http://api.example.com",
            "http://8.8.8.8",
            "http://100.63.255.255",
            "http://100.128.0.1",
            "http://172.15.0.1",
            "http://172.32.0.1",
            "http://169.254.169.254",
            "http://0.0.0.0",
            "http://[2001:db8::1]",
            "http://localhost.example.com",
            "https://user:secret@api.example.com",
            "https://@api.example.com",
            "https://api.example.com?token=secret",
            "https://api.example.com/#secret",
            "https://api.example.com?",
            "https://api.example.com#",
            "https:///api.example.com",
            "https://api.example.com:0",
            "https://api.example.com:65536",
            "https://api..example.com",
            "https://api.example.com..",
            "https://bad_host.example.com",
            "https://-bad.example.com",
            "https://bad-.example.com",
            "https://api.example.com\\other",
            " https://api.example.com",
            "https://api.example.com\n",
            "https://",
            "ftp://api.example.com",
            "api.example.com",
        ] {
            assert!(server_url(url).is_err(), "accepted {url:?}");
        }
    }

    #[test]
    fn timeout_is_bounded_whole_seconds() {
        for seconds in [10, 120, 180] {
            let c = parse(&format!("{MIN}timeout_seconds = {seconds}\n")).unwrap();
            assert_eq!(c.request_timeout, Duration::from_secs(seconds));
        }
        for bad in ["9", "181", "-1", "0", "10.5", "true", "\"120\""] {
            assert!(parse(&format!("{MIN}timeout_seconds = {bad}\n")).is_err());
        }
    }

    #[test]
    fn errors() {
        for (bad, why) in [
            ("", "no server"),
            ("[server]\nurl = \"http://x\"\n", "no token"),
            (
                "[server]\nurl = \"http://x\"\ntoken = \"a\"\n",
                "public http",
            ),
            (
                "[server]\nurl = \"http://x\"\ntoken = \"a b\"\n",
                "space in token",
            ),
            (&format!("{MIN}[dictate]\ncleanup = 1\n"), "flag type"),
            (&format!("{MIN}[dictate]\nvocab = []\n"), "typo key"),
            (&format!("{MIN}[dictat]\n"), "typo section"),
            (&format!("{MIN}[replacements]\na = 1\n"), "replacement type"),
            (&format!("{MIN}[dictate]\nvocabulary = [1]\n"), "vocab type"),
        ] {
            assert!(parse(bad).is_err(), "{why}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn refuses_readable_file() {
        let dir = std::env::temp_dir().join(format!("oliv-cfg-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        std::fs::write(&p, MIN).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(load_from(&p).unwrap_err().contains("mode 600"));
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(load_from(&p).unwrap().token, "abc");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
