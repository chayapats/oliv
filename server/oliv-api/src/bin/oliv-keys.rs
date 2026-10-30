//! Offline key administration. Credentials only go to a new mode-600 file.

use oliv_pipeline::auth::{
    CreateKey, create_key, initialize_key_store, list_keys, prune_trial_keys, revoke_key,
};
use oliv_pipeline::dictionary_store::DictionaryStore;
use std::path::PathBuf;

const USAGE: &str = "Usage: oliv-keys --root DIR init|list|revoke ID\n       oliv-keys --root DIR prune-trials GRACE_DAYS\n       oliv-keys --root DIR create --name NAME --out PATH\n         [--expires-in-days 90] [--scopes dictate,clean,status]\n         [--requests-per-minute 10] [--daily-requests 500]\n       oliv-keys --root DIR profile list|link ID PROFILE|unlink ID\n\nDefault scope: dictate. Raw keys are written only to a NEW mode-600 file.\nExisting files, symlink paths, and directories writable by others are rejected.\n\nProfiles share one personal dictionary between keys (e.g. a person's Mac and\niPhone). An unlinked key is its own profile; `link` points a key at PROFILE,\nwhich may be another key's ID to share that key's dictionary.";

fn run(args: Vec<String>) -> Result<(), String> {
    if args == ["--help"] || args == ["-h"] {
        println!("{USAGE}");
        return Ok(());
    }
    if args.len() < 3 || args[0] != "--root" {
        return Err(USAGE.into());
    }
    let root = PathBuf::from(&args[1]);
    match args[2].as_str() {
        "init" if args.len() == 3 => {
            initialize_key_store(&root)?;
            println!("Key store initialized.");
        }
        "list" if args.len() == 3 => {
            let keys = list_keys(&root)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&keys).map_err(|_| "could not encode key metadata")?
            );
        }
        "revoke" if args.len() == 4 => {
            revoke_key(&root, &args[3])?;
            println!("Key revoked.");
        }
        "prune-trials" if args.len() == 4 => {
            let removed = prune_trial_keys(&root, number(&args[3])?)?;
            println!("Removed {removed} trial keys.");
        }
        "create" => {
            let mut options = CreateKey::default();
            let mut out = None;
            let mut seen = std::collections::HashSet::new();
            let (arguments, remainder) = args[3..].as_chunks::<2>();
            for pair in arguments {
                if !seen.insert(pair[0].as_str()) {
                    return Err("duplicate option".into());
                }
                match pair[0].as_str() {
                    "--name" => options.name.clone_from(&pair[1]),
                    "--out" => out = Some(PathBuf::from(&pair[1])),
                    "--expires-in-days" => options.expires_in_days = number(&pair[1])?,
                    "--scopes" => options.scopes = pair[1].split(',').map(str::to_string).collect(),
                    "--requests-per-minute" => options.requests_per_minute = number(&pair[1])?,
                    "--daily-requests" => options.daily_requests = number(&pair[1])?,
                    _ => return Err("unknown create option; use --help".into()),
                }
            }
            if !remainder.is_empty() {
                return Err("every create option requires a value".into());
            }
            let out = out.ok_or("create requires --out PATH")?;
            if !seen.contains("--name") {
                return Err("create requires --name NAME".into());
            }
            let info = create_key(&root, options, &out)?;
            println!(
                "Created key {}. Credential saved to the private output file.",
                info.id
            );
        }
        "profile" => profile(&root, &args[3..])?,
        _ => return Err(USAGE.into()),
    }
    Ok(())
}

fn profile(root: &std::path::Path, args: &[String]) -> Result<(), String> {
    let store =
        || DictionaryStore::open(root).map_err(|e| format!("dictionary store unavailable: {e}"));
    match args {
        [cmd] if cmd == "list" => {
            let links = store()?
                .links()
                .map_err(|_| "dictionary store unavailable")?;
            let links: Vec<_> = links
                .into_iter()
                .map(|(key, profile)| serde_json::json!({"key_id": key, "profile": profile}))
                .collect();
            println!(
                "{}",
                serde_json::to_string_pretty(&links).map_err(|_| "could not encode links")?
            );
        }
        [cmd, id, profile] if cmd == "link" => {
            if !list_keys(root)?.iter().any(|k| &k.id == id) {
                return Err(format!("no key with ID {id}"));
            }
            store()?.link(id, profile)?;
            println!("Key {id} now uses profile {profile}.");
        }
        [cmd, id] if cmd == "unlink" => {
            store()?.unlink(id)?;
            println!("Key {id} uses its own profile.");
        }
        _ => return Err(USAGE.into()),
    }
    Ok(())
}

fn number(value: &str) -> Result<u32, String> {
    value
        .parse()
        .map_err(|_| "expected a positive whole number".into())
}

fn main() {
    if let Err(error) = run(std::env::args().skip(1).collect()) {
        eprintln!("oliv-keys: {error}");
        std::process::exit(1);
    }
}
