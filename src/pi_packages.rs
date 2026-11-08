//! Turning pi's resources on and off, MCP server settings and sign-in, and
//! the package gallery (docs/pi-parity-plan.md F2, F4, F7, F8). Installing,
//! removing and updating packages and adding or removing MCP servers are pi
//! CLI jobs (`POST /api/pi/jobs`, src/pi_cli.rs); this is what the CLI can't do.
//!
//! | Route | Body / query | Answer |
//! |---|---|---|
//! | `POST /api/pi/resources/toggle` | `{cwd?, kind, path, scope, state: "on"\|"off"\|"inherit", override?, package?: {source, scope, entry}}` | `{enabled, key, scope, entries, epoch}` |
//! | `POST /api/pi/mcp/server` | `{name, cwd?, scope, enabled?, exposure?, override?, clear?}` | the mcp.json view (redacted), like a config write |
//! | `POST /api/pi/mcp/signin` | `{name, action: "login"\|"logout"\|"reconnect", cwd?, key?}` | `{key, cwd, file, done, notices, url, dialog}` |
//! | `GET /api/pi/gallery[?q=&from=]` | | `{total, from, packages: [{name, version, description, date, publisher, npm, repository, homepage, monthly, weekly, source}]}` |
//!
//! **How pi reads the resource arrays** (its `core/package-manager.js`, 1.5.0):
//! `extensions`, `skills` and `prompts` in settings mix plain entries (paths
//! to load) with overrides. For auto-discovered files (`isEnabledByOverrides`)
//! a `!glob` turns a file off, then an exact `+path` turns it back on, then an
//! exact `-path` turns it off, whatever the order in the array; "exact" is
//! the path relative to the settings folder (`.agents` for `.agents/skills`)
//! or the absolute path, and a skill's folder counts for its `SKILL.md`.
//! Files under plain entries (`applyPatterns`) work the same, except that
//! plain globs narrow them first. Global overrides only see global files,
//! project overrides only project files: to change a global file in one
//! project, pi's `pi config --local` lists the file's absolute path in the
//! project's array (so the project loads it, first) with `+`/`-` on it.
//! Built-ins (`builtin:<name>`) follow the global rule in global settings,
//! but in project settings the **last** entry naming one wins
//! (`applyAutoloadDisabledPatterns`), and a project entry beats the global.
//! A package's object form (`{source, extensions: [...]}`) filters what the
//! package offers: a missing key loads everything, `[]` loads nothing,
//! otherwise plain globs include (none = everything), then `!`, `+`, `-`.
//!
//! The toggles here write what `pi config` writes (the file relative to its
//! folder, `+`/`-` in front) and remove any older `+`/`-` entry for the same
//! file however it was spelled, so pi's precedence can't leave a stale
//! `-path` beating a new `+path`. Unlike `pi config` they never drop a plain
//! entry (that would stop the file loading at all), only add `+path` when
//! something still turns the file off, and turning one resource of a
//! package on under `[]` includes just that one (`pi config` would write
//! `["+x"]`, which loads all of them).
//!
//! **MCP** enable and exposure changes follow pi's `updateMcpServerConfig`:
//! a server defined in the file drops `enabled`/`exposure` when they go back
//! to the defaults; a project override (`{enabled: false}` without command,
//! url or type) keeps explicit values. Sign-in needs a session: `/mcp login
//! <server>` in a chat for the project shows a notify with the URL and then
//! an input asking for the URL the browser was sent to, which this answers
//! up front (`url`, `dialog`) so a client can show both without opening the
//! chat; the dialog is also in the chat and notified like any other.

use crate::{AppState, Kind, Live, err, pi_admin, pi_resources};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::StatusCode,
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, atomic::Ordering},
    time::{Duration, Instant},
};

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/pi/resources/toggle", post(toggle))
        .route("/api/pi/mcp/server", post(mcp_server))
        .route("/api/pi/mcp/signin", post(mcp_signin))
        .route("/api/pi/gallery", get(gallery))
}

// ------------------------------------------------------------------ resource arrays

fn is_override(e: &str) -> bool {
    e.starts_with(['+', '-', '!'])
}

fn has_plain_glob(entries: &[String]) -> bool {
    entries.iter().any(|e| !is_override(e) && (e.contains('*') || e.contains('?')))
}

/// Drops every `+`/`-` entry that names `path` exactly (any spelling).
fn without_exact(entries: &[String], path: &Path, base: &Path) -> Vec<String> {
    entries
        .iter()
        .filter(|e| match e.strip_prefix(['+', '-']) {
            Some(target) => !pi_resources::matches(path, target, base, true),
            None => true,
        })
        .cloned()
        .collect()
}

/// A top-level file's own settings array (global for global files, the
/// project's for project files): turned on or off for good.
pub fn toggle_file(entries: &[String], path: &Path, base: &Path, on: bool) -> Vec<String> {
    let pattern = pi_resources::relative(base, path);
    let mut out = without_exact(entries, path, base);
    if !on {
        out.push(format!("-{pattern}"));
    } else if !pi_resources::enabled_by_overrides(path, &out, base) || has_plain_glob(&out) {
        out.push(format!("+{pattern}"));
    }
    out
}

/// A global file overridden in one project (`pi config --local`): its
/// absolute path as a plain entry plus `+`/`-` on it; `None` removes both.
pub fn project_override_file(entries: &[String], path: &Path, base: &Path, state: Option<bool>) -> Vec<String> {
    let abs = path.to_string_lossy().into_owned();
    let mut out = without_exact(entries, path, base);
    match state {
        None => out.retain(|e| *e != abs),
        Some(on) => {
            if !out.contains(&abs) {
                out.push(abs.clone());
            }
            out.push(format!("{}{abs}", if on { '+' } else { '-' }));
        }
    }
    out
}

/// A built-in in global (`project: false`) or project settings. In project
/// settings `None` drops the override so the global setting applies.
pub fn toggle_builtin(entries: &[String], name: &str, project: bool, state: Option<bool>) -> Vec<String> {
    let id = format!("builtin:{name}");
    let mut out: Vec<String> =
        entries.iter().filter(|e| e.strip_prefix(['+', '-']).is_none_or(|t| t.strip_prefix("./").unwrap_or(t) != id)).cloned().collect();
    match (project, state) {
        (true, Some(on)) => out.push(format!("{}{id}", if on { '+' } else { '-' })),
        (true, None) => {}
        (false, Some(false)) => out.push(format!("-{id}")),
        (false, _) => {
            if !pi_resources::builtin_global_enabled(name, &out) {
                out.push(format!("+{id}"));
            }
        }
    }
    out
}

/// pi's `applyPatterns` for one file of a package (paths relative to `root`).
pub fn package_file_enabled(path: &Path, patterns: &[String], root: &Path) -> bool {
    use pi_resources::matches;
    let includes: Vec<&String> = patterns.iter().filter(|p| !is_override(p)).collect();
    let mut on = includes.is_empty() || includes.iter().any(|p| matches(path, p, root, false));
    if on && patterns.iter().filter_map(|p| p.strip_prefix('!')).any(|p| matches(path, p, root, false)) {
        on = false;
    }
    if !on && patterns.iter().filter_map(|p| p.strip_prefix('+')).any(|p| matches(path, p, root, true)) {
        on = true;
    }
    if patterns.iter().filter_map(|p| p.strip_prefix('-')).any(|p| matches(path, p, root, true)) {
        on = false;
    }
    on
}

const RESOURCE_KEYS: [&str; 4] = ["extensions", "skills", "prompts", "themes"];

fn package_source(p: &Value) -> Option<&str> {
    match p {
        Value::String(s) => Some(s),
        Value::Object(o) => o.get("source").and_then(Value::as_str),
        _ => None,
    }
}

/// One resource of a package on or off, in that package's settings entry.
/// `entry` is the file relative to the package root. Returns whether the
/// `packages` array changed.
pub fn toggle_package(packages: &mut [Value], source: &str, key: &str, entry: &str, on: bool) -> Result<bool, String> {
    let i = packages.iter().position(|p| package_source(p) == Some(source)).ok_or_else(|| format!("{source} isn't in this settings file's packages"))?;
    let root = Path::new("/__pkg");
    let path = root.join(entry.strip_prefix("./").unwrap_or(entry));
    let mut obj = match &packages[i] {
        Value::String(s) => json!({"source": s}),
        v => v.clone(),
    };
    let original: Option<Vec<String>> = obj.get(key).and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect());
    let next: Option<Vec<String>> = match (&original, on) {
        // Everything of this kind loads, or nothing does: already as asked.
        (None, true) => None,
        (Some(a), false) if a.is_empty() => Some(vec![]),
        (None, false) => Some(vec![format!("-{entry}")]),
        (Some(a), false) => {
            let mut k = without_exact(a, &path, root);
            if package_file_enabled(&path, &k, root) {
                k.push(format!("-{entry}"));
            }
            Some(k)
        }
        (Some(a), true) if a.is_empty() => Some(vec![entry.to_string()]),
        (Some(a), true) => {
            let mut k = without_exact(a, &path, root);
            if k.is_empty() {
                None
            } else {
                if !package_file_enabled(&path, &k, root) {
                    k.push(format!("+{entry}"));
                }
                Some(k)
            }
        }
    };
    if next == original {
        return Ok(false);
    }
    let o = obj.as_object_mut().unwrap();
    match next {
        Some(list) => {
            o.insert(key.into(), json!(list));
        }
        None => {
            o.shift_remove(key);
        }
    }
    let plain = !RESOURCE_KEYS.iter().any(|k| o.contains_key(*k)) && o.keys().all(|k| k == "source");
    packages[i] = if plain { json!(source) } else { obj };
    Ok(true)
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
}

#[derive(Deserialize)]
struct PackageRef {
    source: String,
    /// "user" (global) or "project".
    #[serde(default)]
    scope: Option<String>,
    /// The file relative to the package root (`toggle.entry` from the scan).
    entry: String,
}

#[derive(Deserialize)]
struct ToggleReq {
    #[serde(default)]
    cwd: Option<String>,
    /// extension, skill or prompt.
    kind: String,
    /// The resource's file, or `builtin:<name>`.
    path: String,
    /// The settings file to change: "global" or "project".
    scope: String,
    /// "on", "off" or "inherit" (drop a project override).
    state: String,
    /// A project override of a global file (the path goes in the project's array).
    #[serde(default)]
    r#override: bool,
    #[serde(default)]
    package: Option<PackageRef>,
}

async fn toggle(State(app): State<Arc<AppState>>, Json(req): Json<ToggleReq>) -> crate::AppResult<Json<Value>> {
    let bad = |m: String| err(StatusCode::BAD_REQUEST, m);
    let key = match req.kind.as_str() {
        "extension" => "extensions",
        "skill" => "skills",
        "prompt" => "prompts",
        k => return Err(bad(format!("unknown kind: {k}"))),
    };
    let state = match req.state.as_str() {
        "on" => Some(true),
        "off" => Some(false),
        "inherit" => None,
        s => return Err(bad(format!("state must be on, off or inherit, not {s}"))),
    };
    let project = match req.scope.as_str() {
        "global" => false,
        "project" => true,
        s => return Err(bad(format!("scope must be global or project, not {s}"))),
    };
    let cwd = if project {
        let c = req.cwd.as_deref().filter(|c| !c.is_empty()).ok_or_else(|| bad("a project (cwd) is needed".into()))?;
        Some(std::fs::canonicalize(c).map_err(|_| bad(format!("folder not found: {c}")))?.to_string_lossy().into_owned())
    } else {
        None
    };
    let base: PathBuf = match &cwd {
        Some(c) => Path::new(c).join(".pi"),
        None => app.agent_dir.clone(),
    };
    let before = app.admin.epoch();
    let mut result_key = key.to_string();
    let mut entries_after = Value::Null;
    let mut enabled = state.unwrap_or(true);
    let doc = app
        .admin
        .update(pi_admin::File::Settings, cwd.as_deref(), |doc| {
            if !doc.is_object() {
                *doc = json!({});
            }
            if let Some(pkg) = &req.package {
                let want = if project { "project" } else { "user" };
                if pkg.scope.as_deref().is_some_and(|s| s != want) {
                    return Err(pi_admin::AdminError::Bad(format!("{} is a {} package", pkg.source, pkg.scope.as_deref().unwrap_or(""))));
                }
                if is_override(&pkg.entry) || pkg.entry.starts_with('/') || pkg.entry.split('/').any(|s| s == "..") {
                    return Err(pi_admin::AdminError::Bad("entry must be a path inside the package".into()));
                }
                let on = state.ok_or_else(|| pi_admin::AdminError::Bad("a package resource is on or off".into()))?;
                let mut list = doc.get("packages").and_then(Value::as_array).cloned().unwrap_or_default();
                let changed = toggle_package(&mut list, &pkg.source, key, &pkg.entry, on).map_err(pi_admin::AdminError::Bad)?;
                result_key = "packages".into();
                entries_after = json!(list);
                enabled = on;
                if changed {
                    doc["packages"] = json!(list);
                }
                return Ok(changed);
            }
            let current = strings(doc.get(key).unwrap_or(&Value::Null));
            let next = if let Some(name) = req.path.strip_prefix("builtin:") {
                if key != "extensions" || !pi_resources::BUILTINS.contains(&name) {
                    return Err(pi_admin::AdminError::Bad(format!("unknown built-in: {}", req.path)));
                }
                let n = toggle_builtin(&current, name, project, state);
                enabled = if project { pi_resources::builtin_project_override(name, &n).unwrap_or(true) } else { pi_resources::builtin_global_enabled(name, &n) };
                n
            } else {
                let p = Path::new(&req.path);
                if !p.is_absolute() {
                    return Err(pi_admin::AdminError::Bad("path must be absolute".into()));
                }
                // `.agents/skills` match against their `.agents` folder.
                let match_base = agents_base(p).filter(|_| key == "skills").unwrap_or_else(|| base.clone());
                if req.r#override {
                    if !project {
                        return Err(pi_admin::AdminError::Bad("an override goes in project settings".into()));
                    }
                    project_override_file(&current, p, &base, state)
                } else {
                    let on = state.ok_or_else(|| pi_admin::AdminError::Bad("inherit is for project overrides".into()))?;
                    let n = toggle_file(&current, p, &match_base, on);
                    enabled = pi_resources::enabled_by_overrides(p, &n, &match_base);
                    n
                }
            };
            entries_after = json!(next);
            if next == current {
                return Ok(false);
            }
            if next.is_empty() {
                doc.as_object_mut().unwrap().shift_remove(key);
            } else {
                doc[key] = json!(next);
            }
            Ok(true)
        })
        .map_err(crate::admin_err)?;
    if app.admin.epoch() != before {
        crate::config_changed(&app);
    }
    Ok(Json(json!({
        "enabled": enabled,
        "key": result_key,
        "scope": if project { "project" } else { "global" },
        "path": doc["path"],
        "entries": entries_after,
        "epoch": app.admin.epoch(),
    })))
}

/// The `.agents` folder of a file under `<x>/.agents/skills/`.
fn agents_base(p: &Path) -> Option<PathBuf> {
    let mut cur = p.parent();
    while let Some(d) = cur {
        if d.file_name().is_some_and(|n| n == "skills") && d.parent().and_then(Path::file_name).is_some_and(|n| n == ".agents") {
            return d.parent().map(Path::to_path_buf);
        }
        cur = d.parent();
    }
    None
}

// ------------------------------------------------------------------ MCP servers

pub const EXPOSURES: [&str; 5] = ["codemode", "deferred", "direct", "hidden", "codemode-deferred"];

/// A project entry that only overrides a global server's switches.
fn is_mcp_override(server: &Value) -> bool {
    server.is_object() && !["command", "url", "type"].iter().any(|k| server.get(*k).is_some())
}

#[derive(Deserialize, Default)]
pub struct McpEdit {
    pub name: String,
    #[serde(default)]
    pub cwd: Option<String>,
    /// The file to change: "global" or "project".
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub exposure: Option<String>,
    /// Add a project override when the project file doesn't name the server.
    #[serde(default)]
    pub r#override: bool,
    /// Remove the project override (the global server's settings apply).
    #[serde(default)]
    pub clear: bool,
}

/// pi's `updateMcpServerConfig` on one `mcp.json` document.
pub fn edit_mcp(doc: &mut Value, e: &McpEdit) -> Result<bool, String> {
    if e.name.is_empty() || !e.name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        return Err("server names are letters, digits, '_' and '-'".into());
    }
    if let Some(x) = &e.exposure {
        if !EXPOSURES.contains(&x.as_str()) {
            return Err(format!("exposure must be one of {}", EXPOSURES[..4].join(", ")));
        }
    }
    if !doc.is_object() {
        *doc = json!({});
    }
    let before = doc.clone();
    if doc.get("mcpServers").is_none_or(|s| !s.is_object()) {
        if !e.r#override {
            return Err(format!("no MCP server named \"{}\" in this file", e.name));
        }
        doc["mcpServers"] = json!({});
    }
    let servers = doc["mcpServers"].as_object_mut().unwrap();
    if e.clear {
        match servers.get(&e.name) {
            Some(s) if is_mcp_override(s) => {
                servers.shift_remove(&e.name);
            }
            Some(_) => return Err(format!("\"{}\" is defined in this file, not overridden; remove it instead", e.name)),
            None => {}
        }
        return Ok(*doc != before);
    }
    if !servers.contains_key(&e.name) {
        if !e.r#override {
            return Err(format!("no MCP server named \"{}\" in this file", e.name));
        }
        servers.insert(e.name.clone(), json!({}));
    }
    let server = servers.get_mut(&e.name).unwrap();
    let keep_defaults = is_mcp_override(server);
    let s = server.as_object_mut().ok_or("the server's entry isn't an object")?;
    if let Some(on) = e.enabled {
        if on && !keep_defaults {
            s.shift_remove("enabled");
        } else {
            s.insert("enabled".into(), json!(on));
        }
    }
    if let Some(x) = &e.exposure {
        if (x == "codemode" || x == "codemode-deferred") && !keep_defaults {
            s.shift_remove("exposure");
        } else {
            s.insert("exposure".into(), json!(x));
        }
    }
    Ok(*doc != before)
}

async fn mcp_server(State(app): State<Arc<AppState>>, Json(e): Json<McpEdit>) -> crate::AppResult<Json<Value>> {
    let project = match e.scope.as_deref().unwrap_or("global") {
        "global" => false,
        "project" => true,
        s => return Err(err(StatusCode::BAD_REQUEST, format!("scope must be global or project, not {s}"))),
    };
    let cwd = if project {
        Some(e.cwd.clone().filter(|c| !c.is_empty()).ok_or_else(|| err(StatusCode::BAD_REQUEST, "a project (cwd) is needed"))?)
    } else {
        None
    };
    let before = app.admin.epoch();
    let v = app.admin.update(pi_admin::File::Mcp, cwd.as_deref(), |doc| edit_mcp(doc, &e).map_err(pi_admin::AdminError::Bad)).map_err(crate::admin_err)?;
    if app.admin.epoch() != before {
        crate::config_changed(&app);
    }
    Ok(Json(v))
}

// ------------------------------------------------------------------ MCP sign-in through a chat

#[derive(Deserialize)]
struct SigninReq {
    name: String,
    /// login, logout or reconnect.
    action: String,
    #[serde(default)]
    cwd: Option<String>,
    /// The chat to run it in (else one open in the project, else a new one).
    #[serde(default)]
    key: Option<String>,
}

/// The first http(s) URL in a notify's text.
pub fn first_url(text: &str) -> Option<String> {
    text.split_whitespace().find(|w| w.starts_with("https://") || w.starts_with("http://")).map(|w| w.trim_end_matches(['.', ',', ')']).to_string())
}

async fn mcp_signin(State(app): State<Arc<AppState>>, Json(req): Json<SigninReq>) -> crate::AppResult<Json<Value>> {
    let bad = |m: &str| err(StatusCode::BAD_REQUEST, m.to_string());
    if req.name.is_empty() || !req.name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-') {
        return Err(bad("server names are letters, digits, '_' and '-'"));
    }
    if !["login", "logout", "reconnect"].contains(&req.action.as_str()) {
        return Err(bad("action must be login, logout or reconnect"));
    }
    // Reconnecting only means something to a pi that's running.
    let live = pick_chat(&app, req.key.as_deref(), req.cwd.as_deref(), req.action != "reconnect").await?;
    if live.streaming.load(Ordering::Relaxed) {
        return Err(err(StatusCode::CONFLICT, "pi is replying in that chat; try again when it's done"));
    }
    // Without /mcp (built-in MCP turned off) the text would go to the model.
    let cmds = tokio::time::timeout(Duration::from_secs(20), crate::rpc_internal(&live, json!({"type": "get_commands"})))
        .await
        .map_err(|_| err(StatusCode::GATEWAY_TIMEOUT, "the chat's pi didn't answer"))??;
    let has_mcp = cmds.pointer("/data/commands").and_then(Value::as_array).is_some_and(|l| l.iter().any(|c| c["name"] == "mcp"));
    if !has_mcp {
        return Err(err(StatusCode::CONFLICT, "this chat's pi has no /mcp command: the built-in mcp extension is off"));
    }
    let mut rx = live.tx.subscribe();
    let (done_tx, mut done_rx) = tokio::sync::oneshot::channel();
    let l2 = live.clone();
    let message = format!("/mcp {} {}", req.action, req.name);
    tokio::spawn(async move {
        let r = crate::rpc_internal(&l2, json!({"type": "prompt", "message": message})).await;
        let _ = done_tx.send(r.map_err(|e| e.1));
    });
    let limit = Duration::from_secs(if req.action == "reconnect" { 45 } else { 20 });
    let deadline = tokio::time::Instant::now() + limit;
    let mut notices: Vec<Value> = vec![];
    let mut url: Option<String> = None;
    let mut dialog = Value::Null;
    let mut done = false;
    let mut error = Value::Null;
    loop {
        tokio::select! {
            r = &mut done_rx => {
                done = true;
                match r {
                    Ok(Ok(v)) if v["success"] == false => error = v["error"].clone(),
                    Ok(Err(e)) => error = json!(e),
                    _ => {}
                }
                // The notifies were printed before the answer; take what's queued.
                while let Ok(line) = rx.try_recv() {
                    note(&line, &mut notices, &mut url, &mut dialog);
                }
                break;
            }
            m = rx.recv() => match m {
                Ok(line) => {
                    if note(&line, &mut notices, &mut url, &mut dialog) {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(_) => break,
            },
            _ = tokio::time::sleep_until(deadline) => break,
        }
    }
    Ok(Json(json!({
        "key": live.key,
        "cwd": live.cwd,
        "file": live.session_file(),
        "done": done,
        "error": error,
        "notices": notices,
        "url": url,
        "dialog": dialog,
    })))
}

/// Notes one line of a chat's output; true when a dialog opened (stop
/// waiting: the person has to answer it).
fn note(line: &str, notices: &mut Vec<Value>, url: &mut Option<String>, dialog: &mut Value) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return false };
    if v["type"] != "extension_ui_request" {
        return false;
    }
    match v["method"].as_str() {
        Some("notify") => {
            let msg = v["message"].as_str().unwrap_or("").to_string();
            if url.is_none() {
                *url = first_url(&msg);
            }
            notices.push(json!({"message": msg, "type": v["notifyType"]}));
            false
        }
        Some("input" | "select" | "confirm" | "editor") => {
            *dialog = json!({"id": v["id"], "method": v["method"], "title": v["title"], "placeholder": v["placeholder"], "options": v["options"]});
            true
        }
        _ => false,
    }
}

/// The chat for a sign-in: the one asked for, else the most recently used
/// chat open in the project, else a new chat there (or in $HOME).
async fn pick_chat(app: &Arc<AppState>, key: Option<&str>, cwd: Option<&str>, spawn: bool) -> crate::AppResult<Arc<Live>> {
    if let Some(k) = key.filter(|k| !k.is_empty()) {
        let live = app.live.lock().unwrap().get(k).cloned().ok_or_else(|| err(StatusCode::NOT_FOUND, "that chat isn't open"))?;
        if live.kind != Kind::Chat {
            return Err(err(StatusCode::BAD_REQUEST, "sign in from a project chat"));
        }
        return Ok(live);
    }
    let dir = crate::resolve_dir(app, cwd.unwrap_or(""))?;
    let found = app
        .live
        .lock()
        .unwrap()
        .values()
        .filter(|l| l.kind == Kind::Chat && !l.exited.load(Ordering::Relaxed) && !l.restarting.load(Ordering::Relaxed))
        .filter(|l| l.cwd == dir || std::fs::canonicalize(&l.cwd).is_ok_and(|c| c.to_string_lossy() == dir))
        .max_by_key(|l| *l.last_active.lock().unwrap())
        .cloned();
    match found {
        Some(l) => Ok(l),
        None if spawn => crate::spawn_pi(app, &dir, None).await,
        None => Err(err(StatusCode::CONFLICT, "no chat is open in this project")),
    }
}

// ------------------------------------------------------------------ gallery

const GALLERY_TTL: Duration = Duration::from_secs(600);

fn gallery_cache() -> &'static Mutex<HashMap<String, (Instant, Value)>> {
    static C: OnceLock<Mutex<HashMap<String, (Instant, Value)>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// The npm search answer, cut down to what the gallery shows (no emails).
pub fn parse_search(v: &Value, from: usize) -> Value {
    let packages: Vec<Value> = v["objects"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|o| {
                    let p = &o["package"];
                    let name = p["name"].as_str()?;
                    Some(json!({
                        "name": name,
                        "version": p["version"],
                        "description": p["description"],
                        "date": p["date"],
                        "publisher": p["publisher"]["username"],
                        "npm": p["links"]["npm"],
                        "repository": p["links"]["repository"],
                        "homepage": p["links"]["homepage"],
                        "monthly": o["downloads"]["monthly"],
                        "weekly": o["downloads"]["weekly"],
                        "source": format!("npm:{name}"),
                    }))
                })
                .collect()
        })
        .unwrap_or_default();
    json!({"total": v["total"], "from": from, "packages": packages})
}

fn url_encode(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

#[derive(Deserialize)]
struct GalleryQuery {
    #[serde(default)]
    q: Option<String>,
    #[serde(default)]
    from: Option<usize>,
}

/// npm packages with the `pi-package` keyword (pi's gallery is built from
/// the same), searched on the server and kept for 10 minutes per query.
async fn gallery(Query(q): Query<GalleryQuery>) -> crate::AppResult<Json<Value>> {
    let text = q.q.unwrap_or_default().trim().chars().take(100).collect::<String>();
    let from = q.from.unwrap_or(0).min(2000);
    let key = format!("{from}\u{0}{text}");
    if let Some((at, v)) = gallery_cache().lock().unwrap().get(&key) {
        if at.elapsed() < GALLERY_TTL {
            return Ok(Json(v.clone()));
        }
    }
    let base = std::env::var("POCKETPI_NPM_REGISTRY").unwrap_or_else(|_| "https://registry.npmjs.org".into());
    let search = if text.is_empty() { "keywords:pi-package".to_string() } else { format!("keywords:pi-package {text}") };
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder().timeout(Duration::from_secs(15)).build().map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let res = client
        .get(format!("{}/-/v1/search?text={}&size=25&from={from}", base.trim_end_matches('/'), url_encode(&search)))
        .send()
        .await
        .map_err(|e| err(StatusCode::BAD_GATEWAY, format!("npm search: {e}")))?;
    if !res.status().is_success() {
        return Err(err(StatusCode::BAD_GATEWAY, format!("npm search answered {}", res.status())));
    }
    let body = res.bytes().await.map_err(|e| err(StatusCode::BAD_GATEWAY, format!("npm search: {e}")))?;
    let v: Value = serde_json::from_slice(&body).map_err(|e| err(StatusCode::BAD_GATEWAY, format!("npm search: {e}")))?;
    let out = parse_search(&v, from);
    let mut c = gallery_cache().lock().unwrap();
    c.retain(|_, (at, _)| at.elapsed() < GALLERY_TTL);
    c.insert(key, (Instant::now(), out.clone()));
    Ok(Json(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn file_toggles_write_what_pi_config_writes() {
        let base = Path::new("/a");
        let f = Path::new("/a/extensions/foo.ts");
        let off = toggle_file(&e(&["../x", "+extensions/foo.ts"]), f, base, false);
        assert_eq!(off, e(&["../x", "-extensions/foo.ts"]));
        assert!(!pi_resources::enabled_by_overrides(f, &off, base));
        // On again: the -entry (however it was spelled) goes; nothing else needed.
        assert_eq!(toggle_file(&e(&["-/a/extensions/foo.ts", "-./extensions/foo.ts"]), f, base, true), e(&[]));
        // A !glob still covers it: +path wins over it.
        let on = toggle_file(&e(&["!*.ts", "-extensions/foo.ts"]), f, base, true);
        assert_eq!(on, e(&["!*.ts", "+extensions/foo.ts"]));
        assert!(pi_resources::enabled_by_overrides(f, &on, base));
        // A skill is named by its SKILL.md, and its folder spelling is removed too.
        let s = Path::new("/a/skills/review/SKILL.md");
        assert_eq!(toggle_file(&e(&["-skills/review"]), s, base, false), e(&["-skills/review/SKILL.md"]));
        assert_eq!(toggle_file(&e(&["-skills/review"]), s, base, true), e(&[]));
        // Outside the folder: relative with .., like node's path.relative.
        assert_eq!(toggle_file(&e(&["../../extra"]), Path::new("/extra/x.ts"), base, false), e(&["../../extra", "-../extra/x.ts"]));
    }

    #[test]
    fn project_overrides_of_global_files() {
        let base = Path::new("/p/.pi");
        let f = Path::new("/h/.pi/agent/extensions/foo.ts");
        let off = project_override_file(&e(&["x.ts"]), f, base, Some(false));
        assert_eq!(off, e(&["x.ts", "/h/.pi/agent/extensions/foo.ts", "-/h/.pi/agent/extensions/foo.ts"]));
        let on = project_override_file(&off, f, base, Some(true));
        assert_eq!(on, e(&["x.ts", "/h/.pi/agent/extensions/foo.ts", "+/h/.pi/agent/extensions/foo.ts"]));
        assert_eq!(project_override_file(&on, f, base, None), e(&["x.ts"]));
    }

    #[test]
    fn builtins_follow_each_scopes_rule() {
        assert_eq!(toggle_builtin(&e(&[]), "mcp", false, Some(false)), e(&["-builtin:mcp"]));
        // A leftover +builtin:mcp would lose to - anyway; it's cleaned up.
        assert_eq!(toggle_builtin(&e(&["+builtin:mcp"]), "mcp", false, Some(false)), e(&["-builtin:mcp"]));
        assert_eq!(toggle_builtin(&e(&["-builtin:mcp", "x"]), "mcp", false, Some(true)), e(&["x"]));
        assert_eq!(toggle_builtin(&e(&["!builtin:*"]), "mcp", false, Some(true)), e(&["!builtin:*", "+builtin:mcp"]));
        // Project: the last entry wins, so the new one goes at the end.
        assert_eq!(toggle_builtin(&e(&["+builtin:codemode", "!builtin:*"]), "codemode", true, Some(true)), e(&["!builtin:*", "+builtin:codemode"]));
        assert_eq!(toggle_builtin(&e(&["-builtin:codemode"]), "codemode", true, None), e(&[]));
    }

    #[test]
    fn package_filters() {
        let mut p = vec![json!("npm:a"), json!({"source": "npm:b", "skills": []})];
        // Off: the string becomes the object form with a -entry.
        assert!(toggle_package(&mut p, "npm:a", "extensions", "extensions/x.ts", false).unwrap());
        assert_eq!(p[0], json!({"source": "npm:a", "extensions": ["-extensions/x.ts"]}));
        // On again: back to the plain string (an empty list would load nothing).
        assert!(toggle_package(&mut p, "npm:a", "extensions", "extensions/x.ts", true).unwrap());
        assert_eq!(p[0], json!("npm:a"));
        assert!(!toggle_package(&mut p, "npm:a", "extensions", "extensions/x.ts", true).unwrap());
        // [] loads none: turning one on includes just that one.
        assert!(toggle_package(&mut p, "npm:b", "skills", "skills/s/SKILL.md", true).unwrap());
        assert_eq!(p[1], json!({"source": "npm:b", "skills": ["skills/s/SKILL.md"]}));
        let root = Path::new("/__pkg");
        assert!(package_file_enabled(&root.join("skills/s/SKILL.md"), &e(&["skills/s/SKILL.md"]), root));
        assert!(!package_file_enabled(&root.join("skills/t/SKILL.md"), &e(&["skills/s/SKILL.md"]), root));
        // A plain include that misses it: +entry.
        let mut p = vec![json!({"source": "npm:c", "prompts": ["prompts/a.md"]})];
        assert!(toggle_package(&mut p, "npm:c", "prompts", "prompts/b.md", true).unwrap());
        assert_eq!(p[0]["prompts"], json!(["prompts/a.md", "+prompts/b.md"]));
        assert!(toggle_package(&mut p, "npm:c", "prompts", "prompts/a.md", false).unwrap());
        assert_eq!(p[0]["prompts"], json!(["prompts/a.md", "+prompts/b.md", "-prompts/a.md"]));
        assert!(toggle_package(&mut vec![json!("x")], "npm:nope", "skills", "a", true).is_err());
    }

    #[test]
    fn mcp_edits_follow_pi() {
        let mut doc = json!({"mcpServers": {"fs": {"command": "npx", "enabled": false, "exposure": "direct"}}, "other": 1});
        let ed = |name: &str| McpEdit { name: name.into(), ..Default::default() };
        // Back to the defaults: the keys go.
        assert!(edit_mcp(&mut doc, &McpEdit { enabled: Some(true), exposure: Some("codemode".into()), ..ed("fs") }).unwrap());
        assert_eq!(doc["mcpServers"]["fs"], json!({"command": "npx"}));
        assert!(edit_mcp(&mut doc, &McpEdit { enabled: Some(false), exposure: Some("hidden".into()), ..ed("fs") }).unwrap());
        assert_eq!(doc["mcpServers"]["fs"], json!({"command": "npx", "enabled": false, "exposure": "hidden"}));
        assert!(!edit_mcp(&mut doc, &McpEdit { enabled: Some(false), ..ed("fs") }).unwrap());
        assert!(edit_mcp(&mut doc, &McpEdit { exposure: Some("loud".into()), ..ed("fs") }).is_err());
        assert!(edit_mcp(&mut doc, &McpEdit { enabled: Some(true), ..ed("nope") }).is_err());
        assert!(edit_mcp(&mut doc, &McpEdit { clear: true, ..ed("fs") }).is_err());
        assert_eq!(doc["other"], 1);
        // A project override keeps explicit defaults, and can be cleared.
        let mut proj = json!({});
        assert!(edit_mcp(&mut proj, &McpEdit { enabled: Some(true), r#override: true, ..ed("docs") }).unwrap());
        assert_eq!(proj, json!({"mcpServers": {"docs": {"enabled": true}}}));
        assert!(edit_mcp(&mut proj, &McpEdit { exposure: Some("codemode".into()), ..ed("docs") }).unwrap());
        assert_eq!(proj["mcpServers"]["docs"], json!({"enabled": true, "exposure": "codemode"}));
        assert!(edit_mcp(&mut proj, &McpEdit { clear: true, ..ed("docs") }).unwrap());
        assert_eq!(proj, json!({"mcpServers": {}}));
    }

    #[test]
    fn reads_npm_search_and_notifies() {
        let v = json!({"total": 1, "objects": [{"downloads": {"monthly": 10, "weekly": 3},
            "package": {"name": "@x/pi-y", "version": "1.0.0", "description": "d", "publisher": {"username": "u", "email": "u@e"}, "links": {"npm": "https://npm/x"}}}]});
        let g = parse_search(&v, 0);
        assert_eq!(g["packages"][0]["source"], "npm:@x/pi-y");
        assert_eq!(g["packages"][0]["monthly"], 10);
        assert!(!g.to_string().contains("u@e"));
        assert_eq!(first_url("Sign in to MCP server \"s\" in your browser:\nhttps://auth.example/a?b=c"), Some("https://auth.example/a?b=c".into()));
        let (mut n, mut u, mut d) = (vec![], None, Value::Null);
        assert!(!note(r#"{"type":"extension_ui_request","id":"1","method":"notify","message":"go https://x.y/z.","notifyType":"info"}"#, &mut n, &mut u, &mut d));
        assert!(note(r#"{"type":"extension_ui_request","id":"2","method":"input","title":"Waiting","placeholder":"http://127.0.0.1"}"#, &mut n, &mut u, &mut d));
        assert_eq!((u.as_deref(), d["id"].as_str(), n.len()), (Some("https://x.y/z"), Some("2"), 1));
        assert_eq!(agents_base(Path::new("/p/.agents/skills/a/SKILL.md")), Some(PathBuf::from("/p/.agents")));
        assert_eq!(agents_base(Path::new("/p/.pi/skills/a/SKILL.md")), None);
    }
}
