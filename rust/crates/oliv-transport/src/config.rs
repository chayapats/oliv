use serde_json::Value;
use std::time::Duration;
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone)]
pub struct Config {
    pub url: String,
    pub token: String,
    pub user_agent: String,
    pub request_timeout: Duration,
    pub cleanup: bool,
    pub remove_fillers: bool,
    pub thai_format: bool,
    pub vocabulary: Vec<String>,
    pub replacements: Vec<(String, String)>,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("token", &"[redacted]")
            .finish_non_exhaustive()
    }
}
impl Config {
    pub fn new(url: &str, token: &str, timeout: u64) -> Result<Self, String> {
        if !(10..=180).contains(&timeout) {
            return Err("invalidTimeout".into());
        }
        if token.is_empty() || !token.bytes().all(|b| b.is_ascii_graphic()) {
            return Err("invalidKey".into());
        }
        Ok(Self {
            url: crate::url::server_url(url).map_err(|_| "invalidURL")?,
            token: token.to_string(),
            user_agent: crate::api::USER_AGENT.to_string(),
            request_timeout: Duration::from_secs(timeout),
            cleanup: true,
            remove_fillers: false,
            thai_format: false,
            vocabulary: vec![],
            replacements: vec![],
        })
    }
    pub fn from_request(request: &Value) -> Result<Self, String> {
        let api = &request["api"];
        let timeout = match api.get("timeout") {
            None => 120.0,
            Some(value) => value
                .as_f64()
                .filter(|n| n.is_finite() && (10.0..=180.0).contains(n))
                .ok_or("invalidTimeout")?,
        };
        let mut config = Self::new(
            api["url"].as_str().ok_or("invalidURL")?,
            api["key"].as_str().ok_or("invalidKey")?,
            timeout.ceil() as u64,
        )?;
        config.request_timeout = Duration::from_secs_f64(timeout);
        let flag = |key, default| match request.get(key) {
            None => Ok(default),
            Some(Value::Bool(value)) => Ok(*value),
            _ => Err("invalidOptions"),
        };
        config.cleanup = flag("cleanup", true)?;
        config.remove_fillers = flag("remove_fillers", false)?;
        config.thai_format = flag("thai_format", false)? && config.cleanup;
        if let Some(terms) = request.get("vocabulary") {
            config.vocabulary = terms
                .as_array()
                .ok_or("invalidOptions")?
                .iter()
                .map(|v| v.as_str().map(str::to_string).ok_or("invalidOptions"))
                .collect::<Result<_, _>>()?;
        }
        if let Some(table) = request.get("replacements") {
            config.replacements = table
                .as_object()
                .ok_or("invalidOptions")?
                .iter()
                .map(|(k, v)| {
                    v.as_str()
                        .map(|v| (k.clone(), v.to_string()))
                        .ok_or("invalidOptions")
                })
                .collect::<Result<_, _>>()?;
            config.replacements.sort_by(|a, b| a.0.cmp(&b.0));
        }
        if let Some(agent) = api["user_agent"].as_str() {
            if !agent.starts_with("oliv-macos/") || !agent.bytes().all(|b| b.is_ascii_graphic()) {
                return Err("invalidOptions".into());
            }
            config.user_agent = agent.to_string();
        }
        Ok(config)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn ipc_validates_options_without_coercing_bad_timeout() {
        let mut request = json!({"api":{"url":"http://127.0.0.1:8080","key":"synthetic","timeout":10.5},
            "cleanup":false,"thai_format":true,"replacements":{"b":"2","a":"1"}});
        let config = Config::from_request(&request).unwrap();
        assert_eq!(config.request_timeout, Duration::from_millis(10_500));
        assert!(!config.thai_format);
        assert_eq!(config.replacements[0].0, "a");
        assert!(!format!("{config:?}").contains("synthetic"));
        for invalid in [json!(null), json!("120"), json!(9), json!(181), json!(-1)] {
            request["api"]["timeout"] = invalid;
            assert!(Config::from_request(&request).is_err());
        }
        request["api"]["timeout"] = json!(120);
        request["cleanup"] = json!("true");
        assert!(Config::from_request(&request).is_err());
    }
}
