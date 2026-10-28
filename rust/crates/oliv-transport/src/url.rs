use url::{Host, Url};
pub fn server_url(raw: &str) -> Result<String, String> {
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
