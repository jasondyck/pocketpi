//! Reading and changing pi's own JSON config files.
//!
//! pi's RPC has no commands for settings, credentials, models, MCP servers or
//! project trust, so pocketpi edits the files pi reads at startup:
//!
//! | name       | global (`$agent_dir/…`) | project (`<cwd>/.pi/…`) |
//! |------------|-------------------------|-------------------------|
//! | `settings` | `settings.json`         | `settings.json`         |
//! | `mcp`      | `mcp.json`              | `mcp.json`              |
//! | `auth`     | `auth.json`             | –                       |
//! | `models`   | `models.json`           | –                       |
//! | `trust`    | `trust.json`            | –                       |
//!
//! Writes are patches, never whole files: `{set: {"a.b": value}, unset: ["c"]}`
//! changes only the named paths, so keys pocketpi doesn't know about (new pi
//! settings, a person's hand edits) survive. Every write goes to a `.tmp` file
//! that is renamed over the real one, the previous version is kept as
//! `<file>.pocketpi.bak` (then `.bak.1`, `.bak.2`), and one mutex covers all
//! of it so two requests can't interleave.
//!
//! Secrets never leave the server: `auth.json` is read back only as
//! `{provider, type, hasKey}` per provider, and in `models.json` and `mcp.json`
//! any string under a key that looks like a credential (apiKey, token,
//! secret, password, authorization, headers, env) is replaced with
//! [`REDACTED`]. Setting a value to that marker is refused, so a client that
//! round-trips a redacted document can't overwrite the real secret with it.
//!
//! pi only rereads these files when it starts, so each successful write bumps
//! `epoch`; a chat pi started before the current epoch is "stale" and the
//! clients offer "Restart to apply".

use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::{
    path::{Path, PathBuf},
    sync::{
        Mutex,
        atomic::{AtomicU64, Ordering},
    },
};

/// Stands in for a secret in what clients see.
pub const REDACTED: &str = "<redacted>";

/// How many old versions of each file are kept.
const BACKUPS: usize = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum File {
    Settings,
    Auth,
    Models,
    Mcp,
    Trust,
}

impl File {
    pub fn parse(name: &str) -> Option<File> {
        Some(match name {
            "settings" => File::Settings,
            "auth" => File::Auth,
            "models" => File::Models,
            "mcp" => File::Mcp,
            "trust" => File::Trust,
            _ => return None,
        })
    }

    fn file_name(self) -> &'static str {
        match self {
            File::Settings => "settings.json",
            File::Auth => "auth.json",
            File::Models => "models.json",
            File::Mcp => "mcp.json",
            File::Trust => "trust.json",
        }
    }

    /// Only settings and MCP servers have a per-project file.
    pub fn has_project_scope(self) -> bool {
        matches!(self, File::Settings | File::Mcp)
    }

    /// Credentials stay private on disk too, like pi creates them.
    fn default_mode(self) -> u32 {
        match self {
            File::Auth => 0o600,
            _ => 0o644,
        }
    }
}

/// A change to one file: dotted paths to set and to remove. A literal dot in
/// a key is written `\.` (model ids like `anthropic/claude-4.5` have dots).
#[derive(Deserialize, Default, Debug)]
pub struct Patch {
    #[serde(default)]
    pub set: Map<String, Value>,
    #[serde(default)]
    pub unset: Vec<String>,
}

pub struct Admin {
    pub agent_dir: PathBuf,
    lock: Mutex<()>,
    epoch: AtomicU64,
}

#[derive(Debug, PartialEq)]
pub enum AdminError {
    /// The request itself is wrong (bad path, redacted marker, no cwd).
    Bad(String),
    /// The file on disk isn't valid JSON (or not an object); pocketpi won't
    /// overwrite what it can't read.
    Unreadable(String),
    Io(String),
}

impl std::fmt::Display for AdminError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AdminError::Bad(s) | AdminError::Unreadable(s) | AdminError::Io(s) => f.write_str(s),
        }
    }
}

impl Admin {
    pub fn new(agent_dir: PathBuf) -> Admin {
        Admin { agent_dir, lock: Mutex::new(()), epoch: AtomicU64::new(0) }
    }

    /// Bumped by every successful config write (here or by a pi CLI job).
    pub fn epoch(&self) -> u64 {
        self.epoch.load(Ordering::Relaxed)
    }

    pub fn bump(&self) -> u64 {
        self.epoch.fetch_add(1, Ordering::Relaxed) + 1
    }

    /// Where `file` lives: the global one, or the project's when `cwd` is given.
    pub fn path(&self, file: File, cwd: Option<&str>) -> Result<PathBuf, AdminError> {
        match cwd.filter(|c| !c.is_empty()) {
            None => Ok(self.agent_dir.join(file.file_name())),
            Some(_) if !file.has_project_scope() => {
                Err(AdminError::Bad(format!("{} has no project file", file.file_name())))
            }
            Some(c) => {
                let dir = std::fs::canonicalize(c).map_err(|_| AdminError::Bad(format!("folder not found: {c}")))?;
                if !dir.is_dir() {
                    return Err(AdminError::Bad(format!("not a folder: {c}")));
                }
                Ok(dir.join(".pi").join(file.file_name()))
            }
        }
    }

    /// What clients see: `{file, scope, path, exists, data, epoch}`, with
    /// secrets taken out. A missing file reads as `{}`.
    pub fn read(&self, file: File, cwd: Option<&str>) -> Result<Value, AdminError> {
        let path = self.path(file, cwd)?;
        let _g = self.lock.lock().unwrap();
        let (doc, exists) = load(&path)?;
        Ok(self.view(file, cwd, &path, doc, exists))
    }

    fn view(&self, file: File, cwd: Option<&str>, path: &Path, doc: Value, exists: bool) -> Value {
        let data = match file {
            File::Auth => redact_auth(&doc),
            File::Models | File::Mcp => redact_secrets(doc),
            _ => doc,
        };
        json!({
            "file": file_label(file),
            "scope": if cwd.is_some_and(|c| !c.is_empty()) { "project" } else { "global" },
            "path": path,
            "exists": exists,
            "data": data,
            "epoch": self.epoch(),
        })
    }

    /// Apply `patch` and return the new (redacted) view. An empty patch is a
    /// no-op that doesn't touch the file or the epoch.
    pub fn patch(&self, file: File, cwd: Option<&str>, patch: &Patch) -> Result<Value, AdminError> {
        let path = self.path(file, cwd)?;
        let _g = self.lock.lock().unwrap();
        let (mut doc, exists) = load(&path)?;
        if patch.set.is_empty() && patch.unset.is_empty() {
            return Ok(self.view(file, cwd, &path, doc, exists));
        }
        apply(&mut doc, patch)?;
        write(&path, &doc, file.default_mode()).map_err(|e| AdminError::Io(format!("{}: {e}", path.display())))?;
        self.bump();
        Ok(self.view(file, cwd, &path, doc, true))
    }
}

fn file_label(f: File) -> &'static str {
    match f {
        File::Settings => "settings",
        File::Auth => "auth",
        File::Models => "models",
        File::Mcp => "mcp",
        File::Trust => "trust",
    }
}

/// Reads a JSON object; a missing or empty file is `{}`.
fn load(path: &Path) -> Result<(Value, bool), AdminError> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((json!({}), false)),
        Err(e) => return Err(AdminError::Io(format!("{}: {e}", path.display()))),
    };
    if text.trim().is_empty() {
        return Ok((json!({}), true));
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(v @ Value::Object(_)) => Ok((v, true)),
        Ok(_) => Err(AdminError::Unreadable(format!("{} is not a JSON object", path.display()))),
        Err(e) => Err(AdminError::Unreadable(format!("{} is not valid JSON: {e}", path.display()))),
    }
}

/// Splits `a.b\.c` into `["a", "b.c"]`.
pub fn split_path(path: &str) -> Result<Vec<String>, AdminError> {
    let mut parts = vec![String::new()];
    let mut chars = path.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some(n) => parts.last_mut().unwrap().push(n),
                None => parts.last_mut().unwrap().push('\\'),
            },
            '.' => parts.push(String::new()),
            c => parts.last_mut().unwrap().push(c),
        }
    }
    if parts.iter().any(String::is_empty) {
        return Err(AdminError::Bad(format!("bad path: {path:?}")));
    }
    Ok(parts)
}

fn contains_redacted(v: &Value) -> bool {
    match v {
        Value::String(s) => s == REDACTED,
        Value::Array(a) => a.iter().any(contains_redacted),
        Value::Object(o) => o.values().any(contains_redacted),
        _ => false,
    }
}

/// Removes the value at `parts`; a path that doesn't exist is fine.
fn remove_at(v: &mut Value, parts: &[String]) {
    let Some(o) = v.as_object_mut() else { return };
    match parts {
        [last] => {
            o.shift_remove(last.as_str());
        }
        [first, rest @ ..] => {
            if let Some(next) = o.get_mut(first.as_str()) {
                remove_at(next, rest);
            }
        }
        [] => {}
    }
}

/// Unsets first, then sets, so `{unset:["a"], set:{"a.b":1}}` replaces `a`.
/// Missing objects along a set path are created; a path through something
/// that isn't an object is refused rather than clobbered.
pub fn apply(doc: &mut Value, patch: &Patch) -> Result<(), AdminError> {
    for p in &patch.unset {
        let parts = split_path(p)?;
        remove_at(doc, &parts);
    }
    for (p, value) in &patch.set {
        if contains_redacted(value) {
            return Err(AdminError::Bad(format!("{p}: refusing to store the {REDACTED} placeholder")));
        }
        let parts = split_path(p)?;
        let (last, parents) = parts.split_last().unwrap();
        let mut cur = &mut *doc;
        for k in parents {
            let o = cur.as_object_mut().ok_or_else(|| AdminError::Bad(format!("{p}: {k} is inside something that isn't an object")))?;
            let next = o.entry(k.clone()).or_insert_with(|| json!({}));
            if !next.is_object() {
                return Err(AdminError::Bad(format!("{p}: {k} is not an object")));
            }
            cur = next;
        }
        cur.as_object_mut()
            .ok_or_else(|| AdminError::Bad(format!("{p}: parent is not an object")))?
            .insert(last.clone(), value.clone());
    }
    Ok(())
}

/// `.tmp` + rename, keeping the old file as the newest backup. A symlinked
/// file (dotfiles repos) is written through to its target.
fn write(path: &Path, doc: &Value, default_mode: u32) -> std::io::Result<()> {
    let path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // Credentials are always private; other files keep whatever mode the
    // person gave them.
    let mode = if default_mode == 0o600 { 0o600 } else { file_mode(&path).unwrap_or(default_mode) };
    if path.exists() {
        rotate_backups(&path)?;
        set_mode(&backup_paths(&path)[0], mode)?;
    }
    let tmp = sibling(&path, ".pocketpi.tmp");
    let mut text = serde_json::to_string_pretty(doc)?;
    text.push('\n');
    std::fs::write(&tmp, text)?;
    set_mode(&tmp, mode)?;
    std::fs::rename(&tmp, &path)
}

fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

/// `<file>.pocketpi.bak` is the newest, then `.bak.1`, `.bak.2`.
pub fn backup_paths(path: &Path) -> Vec<PathBuf> {
    (0..BACKUPS)
        .map(|i| if i == 0 { sibling(path, ".pocketpi.bak") } else { sibling(path, &format!(".pocketpi.bak.{i}")) })
        .collect()
}

fn rotate_backups(path: &Path) -> std::io::Result<()> {
    let b = backup_paths(path);
    for i in (1..b.len()).rev() {
        if b[i - 1].exists() {
            std::fs::rename(&b[i - 1], &b[i])?;
        }
    }
    // A copy keeps the original's permissions (auth.json stays 0600).
    std::fs::copy(path, &b[0])?;
    Ok(())
}

#[cfg(unix)]
fn file_mode(path: &Path) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).ok().map(|m| m.permissions().mode() & 0o777)
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn file_mode(_: &Path) -> Option<u32> {
    None
}

#[cfg(not(unix))]
fn set_mode(_: &Path, _: u32) -> std::io::Result<()> {
    Ok(())
}

/// `auth.json` as `{providers: [{provider, type, hasKey}]}`: enough to show
/// which providers have credentials, nothing that could be used as one.
pub fn redact_auth(doc: &Value) -> Value {
    let mut out: Vec<Value> = doc
        .as_object()
        .map(|o| {
            o.iter()
                .map(|(provider, cred)| {
                    let ty = cred.get("type").and_then(Value::as_str).unwrap_or("unknown");
                    let nonempty = |k: &str| cred.get(k).and_then(Value::as_str).is_some_and(|s| !s.is_empty());
                    let has_key = nonempty("key") || nonempty("access") || nonempty("refresh");
                    json!({ "provider": provider, "type": ty, "hasKey": has_key })
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a["provider"].as_str().cmp(&b["provider"].as_str()));
    json!({ "providers": out })
}

fn secret_key(k: &str) -> bool {
    let k = k.to_ascii_lowercase();
    ["key", "token", "secret", "password", "authorization", "headers", "env", "credential"]
        .iter()
        .any(|w| k.contains(w))
}

/// Replaces every string under a credential-looking key with [`REDACTED`],
/// at any depth (provider `apiKey`, MCP `env`/`headers`, OAuth secrets).
pub fn redact_secrets(v: Value) -> Value {
    fn hide(v: Value) -> Value {
        match v {
            Value::String(_) => Value::String(REDACTED.into()),
            Value::Array(a) => Value::Array(a.into_iter().map(hide).collect()),
            Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, hide(v))).collect()),
            other => other,
        }
    }
    match v {
        Value::Object(o) => Value::Object(
            o.into_iter()
                .map(|(k, v)| {
                    let v = if secret_key(&k) { hide(v) } else { redact_secrets(v) };
                    (k, v)
                })
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(redact_secrets).collect()),
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "pocketpi-admin-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn patch(v: Value) -> Patch {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn dotted_paths_and_escapes() {
        assert_eq!(split_path("a.b.c").unwrap(), ["a", "b", "c"]);
        assert_eq!(split_path(r"modelThinkingLevels.anthropic/claude-4\.5").unwrap(), ["modelThinkingLevels", "anthropic/claude-4.5"]);
        assert!(split_path("a..b").is_err());
        assert!(split_path("").is_err());
        assert!(split_path(".a").is_err());
    }

    #[test]
    fn patch_merges_and_keeps_unknown_keys() {
        let mut doc = json!({"theme": "dark", "compaction": {"enabled": true, "reserveTokens": 100}, "future": {"x": [1, 2]}});
        apply(
            &mut doc,
            &patch(json!({"set": {"compaction.enabled": false, "retry.maxRetries": 5, "defaultModel": "m"}, "unset": ["theme", "nope.deeper"]})),
        )
        .unwrap();
        assert_eq!(
            doc,
            json!({"compaction": {"enabled": false, "reserveTokens": 100}, "future": {"x": [1, 2]}, "retry": {"maxRetries": 5}, "defaultModel": "m"})
        );
    }

    #[test]
    fn patch_refuses_to_walk_through_non_objects() {
        let mut doc = json!({"enabledModels": ["a"]});
        assert!(apply(&mut doc, &patch(json!({"set": {"enabledModels.x": 1}}))).is_err());
        assert_eq!(doc, json!({"enabledModels": ["a"]}));
        // Replacing the whole value is fine.
        apply(&mut doc, &patch(json!({"set": {"enabledModels": ["b", "c"]}}))).unwrap();
        assert_eq!(doc, json!({"enabledModels": ["b", "c"]}));
    }

    #[test]
    fn unset_then_set_replaces() {
        let mut doc = json!({"a": {"old": 1}});
        apply(&mut doc, &patch(json!({"unset": ["a"], "set": {"a.new": 2}}))).unwrap();
        assert_eq!(doc, json!({"a": {"new": 2}}));
    }

    #[test]
    fn refuses_the_redaction_marker() {
        let mut doc = json!({});
        let e = apply(&mut doc, &patch(json!({"set": {"providers.x.apiKey": REDACTED}}))).unwrap_err();
        assert!(matches!(e, AdminError::Bad(_)));
        assert!(apply(&mut doc, &patch(json!({"set": {"p": {"headers": {"A": REDACTED}}}}))).is_err());
    }

    #[test]
    fn writes_backups_keeps_three_and_bumps_epoch() {
        let dir = scratch();
        let admin = Admin::new(dir.clone());
        let path = dir.join("settings.json");
        std::fs::write(&path, r#"{"keep":"me","n":0}"#).unwrap();
        for i in 1..=5 {
            admin.patch(File::Settings, None, &patch(json!({"set": {"n": i}}))).unwrap();
        }
        assert_eq!(admin.epoch(), 5);
        let now: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(now, json!({"keep": "me", "n": 5}));
        let b = backup_paths(&path);
        let n = |p: &Path| serde_json::from_str::<Value>(&std::fs::read_to_string(p).unwrap()).unwrap()["n"].clone();
        assert_eq!(n(&b[0]), json!(4));
        assert_eq!(n(&b[1]), json!(3));
        assert_eq!(n(&b[2]), json!(2));
        assert!(!sibling(&path, ".pocketpi.bak.3").exists());
        assert!(!sibling(&path, ".pocketpi.tmp").exists());
        // An empty patch changes nothing.
        admin.patch(File::Settings, None, &Patch::default()).unwrap();
        assert_eq!(admin.epoch(), 5);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn refuses_to_overwrite_a_broken_file() {
        let dir = scratch();
        let admin = Admin::new(dir.clone());
        std::fs::write(dir.join("settings.json"), "{ not json").unwrap();
        let e = admin.patch(File::Settings, None, &patch(json!({"set": {"a": 1}}))).unwrap_err();
        assert!(matches!(e, AdminError::Unreadable(_)));
        assert_eq!(std::fs::read_to_string(dir.join("settings.json")).unwrap(), "{ not json");
        assert_eq!(admin.epoch(), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn auth_reads_are_redacted_and_writes_stay_private() {
        let dir = scratch();
        let admin = Admin::new(dir.clone());
        let secret = "sk-very-secret";
        std::fs::write(
            dir.join("auth.json"),
            json!({
                "openai": {"type": "api_key", "key": secret},
                "anthropic": {"type": "oauth", "access": "acc-secret", "refresh": "ref-secret", "expires": 1},
                "llama.cpp": {"type": "api_key", "env": {"LLAMA_BASE_URL": "http://x"}}
            })
            .to_string(),
        )
        .unwrap();
        let v = admin.read(File::Auth, None).unwrap();
        let text = v.to_string();
        for s in [secret, "acc-secret", "ref-secret", "http://x"] {
            assert!(!text.contains(s), "{s} leaked: {text}");
        }
        assert_eq!(
            v["data"]["providers"],
            json!([
                {"provider": "anthropic", "type": "oauth", "hasKey": true},
                {"provider": "llama.cpp", "type": "api_key", "hasKey": false},
                {"provider": "openai", "type": "api_key", "hasKey": true},
            ])
        );
        let v = admin
            .patch(File::Auth, None, &patch(json!({"set": {"groq": {"type": "api_key", "key": "gsk-new"}}, "unset": ["openai"]})))
            .unwrap();
        assert!(!v.to_string().contains("gsk-new"));
        let on_disk: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("auth.json")).unwrap()).unwrap();
        assert_eq!(on_disk["groq"]["key"], "gsk-new");
        assert_eq!(on_disk["anthropic"]["refresh"], "ref-secret");
        assert!(on_disk.get("openai").is_none());
        #[cfg(unix)]
        {
            assert_eq!(file_mode(&dir.join("auth.json")), Some(0o600));
            assert_eq!(file_mode(&backup_paths(&dir.join("auth.json"))[0]), Some(0o600));
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn new_auth_file_is_private() {
        let dir = scratch();
        let admin = Admin::new(dir.clone());
        admin.patch(File::Auth, None, &patch(json!({"set": {"x": {"type": "api_key", "key": "k"}}}))).unwrap();
        #[cfg(unix)]
        assert_eq!(file_mode(&dir.join("auth.json")), Some(0o600));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn models_and_mcp_secrets_are_redacted() {
        let v = redact_secrets(json!({
            "providers": {"my": {"baseUrl": "http://h", "apiKey": "sk-1", "models": [{"id": "m", "headers": {"X-Key": "abc"}}]}},
            "mcpServers": {"s": {"command": "x", "args": ["--token", "a"], "env": {"API_KEY": "zzz"}, "oauth": {"clientSecret": "cs"}}}
        }));
        let text = v.to_string();
        for s in ["sk-1", "abc", "zzz", "cs"] {
            assert!(!text.contains(&format!("\"{s}\"")), "{s} leaked: {text}");
        }
        assert_eq!(v["providers"]["my"]["baseUrl"], "http://h");
        assert_eq!(v["mcpServers"]["s"]["command"], "x");
        assert_eq!(v["providers"]["my"]["apiKey"], REDACTED);
    }

    #[test]
    fn project_scope_only_for_settings_and_mcp() {
        let dir = scratch();
        let admin = Admin::new(dir.join("agent"));
        let proj = dir.join("proj");
        std::fs::create_dir_all(&proj).unwrap();
        let p = proj.to_str().unwrap();
        assert!(admin.path(File::Auth, Some(p)).is_err());
        assert!(admin.path(File::Settings, Some("/definitely/not/here")).is_err());
        let v = admin.patch(File::Settings, Some(p), &patch(json!({"set": {"a": 1}}))).unwrap();
        assert_eq!(v["scope"], "project");
        let real = std::fs::canonicalize(&proj).unwrap().join(".pi/settings.json");
        assert!(real.exists());
        // The global file is untouched.
        assert!(!dir.join("agent/settings.json").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn writes_through_symlinks() {
        let dir = scratch();
        let admin = Admin::new(dir.join("agent"));
        std::fs::create_dir_all(dir.join("agent")).unwrap();
        std::fs::write(dir.join("real.json"), "{}").unwrap();
        std::os::unix::fs::symlink(dir.join("real.json"), dir.join("agent/settings.json")).unwrap();
        admin.patch(File::Settings, None, &patch(json!({"set": {"a": 1}}))).unwrap();
        assert!(std::fs::symlink_metadata(dir.join("agent/settings.json")).unwrap().file_type().is_symlink());
        assert!(std::fs::read_to_string(dir.join("real.json")).unwrap().contains("\"a\": 1"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
