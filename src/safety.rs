//! Glue around @gotgenes/pi-permission-system, the policy layer pocketpi
//! recommends (docs/pi-parity-plan.md §6).
//!
//! **Workflow stages run under their own policy.** The extension reads its
//! global policy from `<agent dir>/extensions/pi-permission-system/config.json`
//! and nothing else decides where that is (no env var or flag; project and
//! per-agent files only merge on top of it). So a stage gets its own agent
//! dir: an *overlay* next to the real one (`~/.pi/agent.pocketpi-stage`) in
//! which every entry is a symlink to the real entry, except that
//! `extensions/` is a real folder of symlinks whose `pi-permission-system/`
//! holds `config.json` -> pocketpi's `~/.config/pocketpi/safety/stage-policy.json`.
//! The stage's pi gets `PI_CODING_AGENT_DIR=<overlay>`, so it sees the
//! person's auth, settings, models, packages and trust exactly as a chat
//! does (pi writes through the symlinks), and only the policy differs.
//! The overlay sits beside the real dir so relative paths in settings.json
//! resolve to the same places. Its session files go to the real sessions
//! folder (`--session-dir`), so they are listed with the person's chats.
//!
//! Without a stage policy file there is no overlay: stages use the chat
//! policy, where every "ask" is a deny (the engine declines dialogs).
//!
//! **Auto review** is @mzwing/pi-permission-auto-review: an `authorizerChain`
//! link (named `auto-review`) that has a model answer the policy's asks the
//! way Claude Code's auto mode does, so they reach a person only when the
//! review fails. pi-permission-system consults it only for asks: its denies
//! (secrets, sudo) still refuse first. Its config is the `auto-review` admin
//! file; `POST /api/safety/auto-review` puts the link in the chat policy's
//! chain (or takes it out), and `GET /api/safety/reviews` reads its
//! decisions back from pi-permission-system's review log, since nothing else
//! shows them. Stages never ask, so the link never runs in one.

use crate::{AppResult, AppState, err};
use axum::{Json, extract::State, http::StatusCode};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// What "Install" installs: pinned, so a policy written for it keeps meaning
/// the same thing.
pub const PACKAGE: &str = "npm:@gotgenes/pi-permission-system@42.0.0";
/// The extension's folder under `<agent dir>/extensions`.
const EXT_DIR: &str = "pi-permission-system";
/// The proposed policies (extensions/safety/), offered by "use recommended".
pub const CHAT_POLICY: &str = include_str!("../extensions/safety/chat-policy.json");
pub const STAGE_POLICY: &str = include_str!("../extensions/safety/stage-policy.json");
/// What "Install auto review" installs, pinned like [`PACKAGE`]: it was
/// reviewed and tested at this version.
pub const AUTO_REVIEW_PACKAGE: &str = "npm:@mzwing/pi-permission-auto-review@1.0.1";
/// Its link's name in `authorizerChain`.
pub const AUTO_REVIEW_LINK: &str = "auto-review";
/// The config written when auto review is first turned on: Claude Code's
/// rules on a cheap model. Claude through OpenCode Go fails a continued
/// review conversation, so every review is sent in full.
pub const AUTO_REVIEW_CONFIG: &str = r#"{
  "preset": "claude-code",
  "provider": "opencode-go",
  "model": "claude-haiku-5-5",
  "followUpReviews": "off"
}"#;
/// `path_write` rules that keep the agent from rewriting what governs it
/// (pi's settings and packages, the policies, auto review's config). With a
/// model answering asks, those writes would otherwise be its call.
const SELF_PROTECT: &[&str] = &["~/.pi/agent/settings.json", "~/.pi/agent/extensions/*", "~/.pi/agent/npm/*", "~/.config/pocketpi/safety/*"];
const SELF_PROTECT_REASON: &str = "pi's settings, packages and permission policies are off limits to the agent; change them in pocketpi's Settings";

static OVERLAY_LOCK: Mutex<()> = Mutex::new(());
/// The agent dir's files pi may create on its own, shared with stages even
/// before they exist.
const SHARED_FILES: &[&str] = &["auth.json", "settings.json", "models.json", "models-store.json", "mcp.json", "trust.json"];

/// Where a stage's agent dir goes: beside the real one.
pub fn overlay_path(agent_dir: &Path) -> Option<PathBuf> {
    let name = agent_dir.file_name()?.to_str()?;
    Some(agent_dir.parent()?.join(format!("{name}.pocketpi-stage")))
}

#[cfg(unix)]
fn symlink(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}
#[cfg(not(unix))]
fn symlink(_: &Path, _: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("symlinks need unix"))
}

/// Makes `link` a symlink to `target`, replacing a wrong symlink or a plain
/// file (one pi made in the overlay before the real dir had it). A folder in
/// its way is left alone (and reported): it may hold something.
fn ensure_link(target: &Path, link: &Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(link) {
        Ok(m) if m.file_type().is_symlink() => {
            if std::fs::read_link(link)? == target {
                return Ok(());
            }
        }
        Ok(m) if m.is_dir() => {
            return Err(std::io::Error::other(format!("{} is a folder; not replacing it", link.display())));
        }
        Ok(_) => {}
        Err(_) => return symlink(target, link),
    }
    // Swap atomically: a running stage may be reading through it.
    let tmp = link.with_file_name(format!(".{}.pocketpi-tmp", link.file_name().unwrap_or_default().to_string_lossy()));
    let _ = std::fs::remove_file(&tmp);
    symlink(target, &tmp)?;
    std::fs::rename(&tmp, link)
}

/// Mirrors `real` into `overlay` as symlinks (except `skip`), and drops
/// overlay symlinks whose real entry is gone. Plain files and folders pi
/// made in the overlay itself (lock folders, tmp) are kept. `ensure` names
/// files linked even before they exist, so pi creates them in the real dir
/// (writes follow a dangling symlink).
fn mirror(real: &Path, overlay: &Path, skip: &str, ensure: &[&str]) -> std::io::Result<()> {
    std::fs::create_dir_all(overlay)?;
    for name in ensure {
        let (r, o) = (real.join(name), overlay.join(name));
        if std::fs::symlink_metadata(&r).is_err() {
            // One pi made here before there was a real one: it becomes the real one.
            if std::fs::symlink_metadata(&o).is_ok_and(|m| m.is_file()) {
                std::fs::rename(&o, &r)?;
            }
            ensure_link(&r, &o)?;
        }
    }
    let mut names: Vec<std::ffi::OsString> = ensure.iter().map(|n| n.into()).collect();
    if let Ok(entries) = std::fs::read_dir(real) {
        for e in entries.flatten() {
            let name = e.file_name();
            if name == skip {
                continue;
            }
            if let Err(err) = ensure_link(&e.path(), &overlay.join(&name)) {
                eprintln!("stage overlay: {err}");
            }
            names.push(name);
        }
    }
    for e in std::fs::read_dir(overlay)?.flatten() {
        let name = e.file_name();
        let is_link = e.file_type().is_ok_and(|t| t.is_symlink());
        if is_link && name != skip && !names.contains(&name) {
            let _ = std::fs::remove_file(e.path());
        }
    }
    Ok(())
}

/// Builds (or brings up to date) the overlay for `agent_dir` with `policy`
/// as the extension's config, and returns its path.
pub fn build_overlay(agent_dir: &Path, policy: &Path) -> std::io::Result<PathBuf> {
    let overlay = overlay_path(agent_dir).ok_or_else(|| std::io::Error::other("agent dir has no parent"))?;
    let _g = OVERLAY_LOCK.lock().unwrap();
    // A symlinked `extensions` (made by hand?) would put our config into
    // the real folder: make it a real one.
    let ext = overlay.join("extensions");
    if std::fs::symlink_metadata(&ext).is_ok_and(|m| m.file_type().is_symlink()) {
        std::fs::remove_file(&ext)?;
    }
    // pi creates these at startup; created through the overlay they must
    // land in the real dir. Sessions go there anyway (`--session-dir`).
    std::fs::create_dir_all(agent_dir.join("sessions"))?;
    mirror(agent_dir, &overlay, "extensions", SHARED_FILES)?;
    mirror(&agent_dir.join("extensions"), &ext, EXT_DIR, &[])?;
    let own = ext.join(EXT_DIR);
    if std::fs::symlink_metadata(&own).is_ok_and(|m| m.file_type().is_symlink()) {
        std::fs::remove_file(&own)?;
    }
    std::fs::create_dir_all(&own)?;
    ensure_link(policy, &own.join("config.json"))?;
    Ok(overlay)
}

/// pi's default session folder for `cwd` under `agent_dir` (its own
/// encoding: `--home-me-project--`).
pub fn default_session_dir(agent_dir: &Path, cwd: &str) -> PathBuf {
    let enc: String = cwd.trim_start_matches(['/', '\\']).chars().map(|c| if matches!(c, '/' | '\\' | ':') { '-' } else { c }).collect();
    agent_dir.join("sessions").join(format!("--{enc}--"))
}

/// Points a stage's pi at the overlay when there is a stage policy. Called
/// where stage pis are spawned (`spawn_pi_with` → `spawn_live`).
pub fn stage_command(app: &AppState, cwd: &str, cmd: &mut tokio::process::Command) {
    let Ok(policy) = app.admin.path(crate::pi_admin::File::StagePolicy, None) else { return };
    if !policy.is_file() {
        return;
    }
    match build_overlay(&app.agent_dir, &policy) {
        Ok(overlay) => {
            cmd.env("PI_CODING_AGENT_DIR", &overlay);
            // Session files where the chats are, not under the overlay's path.
            if std::env::var_os("PI_CODING_AGENT_SESSION_DIR").is_none() {
                cmd.arg("--session-dir").arg(default_session_dir(&app.agent_dir, cwd));
            }
        }
        Err(e) => eprintln!("stage overlay: {e}; this stage runs under the chat policy"),
    }
}

/// `GET /api/safety`: what the safety page needs besides the config files.
pub async fn info(State(app): State<Arc<AppState>>) -> Json<Value> {
    let parse = |s: &str| serde_json::from_str::<Value>(s).unwrap_or(Value::Null);
    let stage_policy = app.admin.path(crate::pi_admin::File::StagePolicy, None).ok();
    Json(json!({
        "package": PACKAGE,
        "recommended": { "permissions": parse(CHAT_POLICY), "stage-policy": parse(STAGE_POLICY) },
        "stage_policy": stage_policy,
        "stage_policy_active": stage_policy.as_ref().is_some_and(|p| p.is_file()),
        "stage_overlay": overlay_path(&app.agent_dir),
        "auto_review": {
            "package": AUTO_REVIEW_PACKAGE,
            "link": AUTO_REVIEW_LINK,
            "recommended": parse(AUTO_REVIEW_CONFIG),
        },
    }))
}

#[derive(Deserialize)]
pub struct AutoReviewToggle {
    enabled: bool,
}

/// Puts the auto-review link in (or takes it out of) a policy's
/// `authorizerChain`, keeping any other links. Turning it on also adds the
/// [`SELF_PROTECT`] rules that are missing. Returns whether it changed.
fn toggle_link(doc: &mut Value, enabled: bool) -> bool {
    let Some(o) = doc.as_object_mut() else { return false };
    let mut chain: Vec<Value> = o.get("authorizerChain").and_then(Value::as_array).cloned().unwrap_or_default();
    let has = chain.iter().any(|v| v == AUTO_REVIEW_LINK);
    let mut changed = false;
    if enabled && !has {
        chain.push(json!(AUTO_REVIEW_LINK));
        changed = true;
    } else if !enabled && has {
        chain.retain(|v| v != AUTO_REVIEW_LINK);
        changed = true;
    }
    if changed {
        if chain.is_empty() {
            o.shift_remove("authorizerChain");
        } else {
            o.insert("authorizerChain".into(), Value::Array(chain));
        }
    }
    if enabled {
        let perm = o.entry("permission").or_insert_with(|| json!({}));
        if let Some(perm) = perm.as_object_mut() {
            let pw = perm.entry("path_write").or_insert_with(|| json!({}));
            if let Some(pw) = pw.as_object_mut() {
                // The catch-all first, as in the recommended policies (last match wins).
                if !pw.contains_key("*") {
                    pw.shift_insert(0, "*".into(), json!("allow"));
                    changed = true;
                }
                for p in SELF_PROTECT {
                    if !pw.contains_key(*p) {
                        pw.insert((*p).into(), json!({ "action": "deny", "reason": SELF_PROTECT_REASON }));
                        changed = true;
                    }
                }
            }
        }
    }
    changed
}

/// `POST /api/safety/auto-review {"enabled"}`: turns auto review on or off
/// for chats (the chat policy's chain; the package stays installed). The
/// first time on, it also writes [`AUTO_REVIEW_CONFIG`]. Answers
/// `{permissions, config}`, the two files' views.
pub async fn set_auto_review(State(app): State<Arc<AppState>>, Json(req): Json<AutoReviewToggle>) -> AppResult<Json<Value>> {
    use crate::pi_admin::File;
    let bad = |e: crate::pi_admin::AdminError| err(StatusCode::UNPROCESSABLE_ENTITY, e.to_string());
    let mut config = app.admin.read(File::AutoReview, None).map_err(bad)?;
    if req.enabled && config["exists"] != json!(true) {
        let doc: Map<String, Value> = serde_json::from_str(AUTO_REVIEW_CONFIG).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
        let patch = crate::pi_admin::Patch { set: doc.into_iter().collect(), unset: vec![] };
        config = app.admin.patch(File::AutoReview, None, &patch).map_err(bad)?;
    }
    let permissions = app.admin.update(File::Permissions, None, |doc| Ok(toggle_link(doc, req.enabled))).map_err(bad)?;
    Ok(Json(json!({ "permissions": permissions, "config": config })))
}

#[derive(Deserialize)]
pub struct ReviewsQuery {
    limit: Option<usize>,
}

/// How much of the review log's end is read: plenty for the latest reviews
/// (a request is a few short lines), without reading a log that has grown.
const LOG_TAIL: u64 = 2 << 20;

/// The review log's last [`LOG_TAIL`] bytes, whole lines only.
fn log_tail(path: &Path) -> String {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut f) = std::fs::File::open(path) else { return String::new() };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    let start = len.saturating_sub(LOG_TAIL);
    if f.seek(SeekFrom::Start(start)).is_err() {
        return String::new();
    }
    let mut buf = Vec::new();
    let _ = f.read_to_end(&mut buf);
    let text = String::from_utf8_lossy(&buf).into_owned();
    if start > 0 { text.split_once('\n').map(|(_, rest)| rest.to_string()).unwrap_or_default() } else { text }
}

/// The auto-review decisions in a review log, newest first: each joined
/// with its request (what was asked) and how the request ended (a deny's
/// reason; after a defer, what the person answered).
pub fn reviews_from_log(text: &str, limit: usize) -> Vec<Value> {
    let mut requests: std::collections::HashMap<String, Map<String, Value>> = std::collections::HashMap::new();
    let mut order: Vec<String> = Vec::new();
    for line in text.lines() {
        let Ok(e) = serde_json::from_str::<Value>(line) else { continue };
        let Some(id) = e["requestId"].as_str() else { continue };
        let ev = e["event"].as_str().unwrap_or("");
        let r = requests.entry(id.to_string()).or_default();
        if ev.starts_with("permission_request.") {
            for k in ["surface", "command", "toolName", "matchedPattern"] {
                if e[k].is_string() && !r.contains_key(k) {
                    r.insert(k.into(), e[k].clone());
                }
            }
            if !r.contains_key("path")
                && let Some(p) = e["path"].as_str().or(e["decidingPath"].as_str())
            {
                r.insert("path".into(), json!(p));
            }
            let by = &e["decidedBy"];
            if by.is_object() {
                if by["kind"] == "authorizer" && by["name"] == AUTO_REVIEW_LINK {
                    if let Some(reason) = by["reason"].as_str().or(e["denialReason"].as_str()) {
                        r.insert("reason".into(), json!(reason));
                    }
                } else if r.contains_key("outcome") {
                    // After the review deferred: the person (or a timeout) decided.
                    let then = if ev.ends_with(".denied") { "denied" } else { "approved" };
                    r.insert("then".into(), json!(then));
                }
            }
        } else if ev == "auto_review.decision" {
            if !r.contains_key("outcome") {
                order.push(id.to_string());
            }
            r.insert("id".into(), json!(id));
            r.insert("at".into(), e["timestamp"].clone());
            for k in ["outcome", "durationMs", "model", "provider", "stage", "errorCategory"] {
                if !e[k].is_null() {
                    r.insert(k.into(), e[k].clone());
                }
            }
        }
    }
    order.iter().rev().take(limit).filter_map(|id| requests.remove(id)).map(Value::Object).collect()
}

/// `GET /api/safety/reviews[?limit=30]`: `{reviews: [{id, at, outcome,
/// surface, command?, path?, reason?, then?, durationMs, model, stage?,
/// errorCategory?}], log}`, newest first, from the chat policy's review log.
pub async fn reviews(State(app): State<Arc<AppState>>, axum::extract::Query(q): axum::extract::Query<ReviewsQuery>) -> Json<Value> {
    let log = app.agent_dir.join("extensions").join(EXT_DIR).join("logs").join("pi-permission-system-permission-review.jsonl");
    let limit = q.limit.unwrap_or(30).clamp(1, 200);
    let path = log.clone();
    let list = tokio::task::spawn_blocking(move || reviews_from_log(&log_tail(&path), limit)).await.unwrap_or_default();
    Json(json!({ "reviews": list, "log": log }))
}

#[derive(Deserialize)]
pub struct UseRecommended {
    /// "permissions" (the chat policy) or "stage-policy".
    file: String,
}

/// `POST /api/safety/recommended {"file"}`: writes the proposed policy's
/// keys over the file (other keys stay), through pi_admin (backups).
pub async fn use_recommended(State(app): State<Arc<AppState>>, Json(req): Json<UseRecommended>) -> AppResult<Json<Value>> {
    let (file, text) = match req.file.as_str() {
        "permissions" => (crate::pi_admin::File::Permissions, CHAT_POLICY),
        "stage-policy" => (crate::pi_admin::File::StagePolicy, STAGE_POLICY),
        _ => return Err(err(StatusCode::BAD_REQUEST, "file is permissions or stage-policy")),
    };
    let doc: Map<String, Value> = serde_json::from_str(text).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let patch = crate::pi_admin::Patch { set: doc.into_iter().map(|(k, v)| (k.replace('.', "\\."), v)).collect(), unset: vec![] };
    app.admin.patch(file, None, &patch).map(Json).map_err(|e| err(StatusCode::UNPROCESSABLE_ENTITY, e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "pocketpi-safety-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn proposed_policies_parse_and_put_catch_alls_first() {
        for text in [CHAT_POLICY, STAGE_POLICY] {
            let doc: Value = serde_json::from_str(text).unwrap();
            let perm = doc["permission"].as_object().unwrap();
            for (surface, rules) in perm {
                if let Some(o) = rules.as_object() {
                    assert_eq!(o.keys().next().map(String::as_str), Some("*"), "{surface}: the catch-all comes first");
                }
            }
            // Secrets are denied in both.
            for p in ["~/.ssh/*", "~/.aws/*", "~/.config/gh/hosts.yml", "*.env", "~/.pi/agent/auth.json", "~/.config/pocketpi/apns/*"] {
                assert_eq!(doc["permission"]["path"][p]["action"], "deny", "{p}");
            }
            assert_eq!(doc["permission"]["path"]["*.env.example"], "allow");
            assert_eq!(doc["permission"]["bash"]["sudo *"]["action"], "deny");
            // Round trip through the admin's ordered form keeps the order.
            let rules = crate::pi_admin::ordered_rules(&doc);
            assert_eq!(rules["bash"][0][0], "*");
        }
        let chat: Value = serde_json::from_str(CHAT_POLICY).unwrap();
        assert_eq!(chat["promptTimeoutMs"], 600000);
        assert_eq!(chat["permission"]["bash"]["rm *"], "ask");
        let stage: Value = serde_json::from_str(STAGE_POLICY).unwrap();
        // Stages push their own branch (clipt-fix-pr's open-pr stage does), never forced or to main.
        assert!(stage["permission"]["bash"]["git push *"].is_null());
        assert_eq!(stage["permission"]["bash"]["git push *--force*"]["action"], "deny");
        assert_eq!(stage["permission"]["bash"]["git push * main"]["action"], "deny");
        assert_eq!(stage["permission"]["bash"]["gh pr merge*"]["action"], "deny");
        // Nothing in a stage asks: an ask would be declined there anyway.
        assert!(!STAGE_POLICY.contains("\"ask\""));
    }

    #[cfg(unix)]
    #[test]
    fn overlay_shares_everything_but_the_policy() {
        let dir = scratch();
        let real = dir.join("pi/agent");
        std::fs::create_dir_all(real.join("extensions/pi-permission-system/logs")).unwrap();
        std::fs::create_dir_all(real.join("sessions")).unwrap();
        std::fs::write(real.join("auth.json"), r#"{"k":1}"#).unwrap();
        std::fs::write(real.join("settings.json"), "{}").unwrap();
        std::fs::write(real.join("extensions/mine.ts"), "x").unwrap();
        std::fs::write(real.join("extensions/pi-permission-system/config.json"), r#"{"chat":true}"#).unwrap();
        let policy = dir.join("stage-policy.json");
        std::fs::write(&policy, r#"{"stage":true}"#).unwrap();

        let o = build_overlay(&real, &policy).unwrap();
        assert_eq!(o, dir.join("pi/agent.pocketpi-stage"));
        assert_eq!(std::fs::read_to_string(o.join("auth.json")).unwrap(), r#"{"k":1}"#);
        assert_eq!(std::fs::read_to_string(o.join("extensions/mine.ts")).unwrap(), "x");
        assert_eq!(std::fs::read_to_string(o.join("extensions/pi-permission-system/config.json")).unwrap(), r#"{"stage":true}"#);
        assert!(!o.join("extensions/pi-permission-system/logs").exists(), "its own logs");
        // pi writes through the links.
        std::fs::write(o.join("settings.json"), r#"{"w":1}"#).unwrap();
        assert_eq!(std::fs::read_to_string(real.join("settings.json")).unwrap(), r#"{"w":1}"#);
        std::fs::write(o.join("sessions/s.jsonl"), "{}").unwrap();
        assert!(real.join("sessions/s.jsonl").exists());

        // Later: a new entry shows up, a removed one goes, a file pi made in
        // the overlay before the real one existed gives way to the real one.
        std::fs::remove_file(real.join("extensions/mine.ts")).unwrap();
        std::fs::write(real.join("models.json"), "{}").unwrap();
        std::fs::remove_file(o.join("mcp.json")).unwrap();
        std::fs::write(o.join("mcp.json"), "{}").unwrap();
        std::fs::write(real.join("mcp.json"), r#"{"real":1}"#).unwrap();
        std::fs::create_dir_all(o.join("auth.json.lock")).unwrap();
        build_overlay(&real, &policy).unwrap();
        assert!(o.join("models.json").exists());
        assert!(!o.join("extensions/mine.ts").exists());
        assert_eq!(std::fs::read_to_string(o.join("mcp.json")).unwrap(), r#"{"real":1}"#);
        assert!(o.join("auth.json.lock").is_dir(), "pi's own lock folders stay");
        // Files pi creates later are created in the real dir.
        assert!(std::fs::symlink_metadata(o.join("trust.json")).unwrap().file_type().is_symlink());
        std::fs::write(o.join("trust.json"), r#"{"/p":true}"#).unwrap();
        assert_eq!(std::fs::read_to_string(real.join("trust.json")).unwrap(), r#"{"/p":true}"#);
        // The real chat policy was never touched.
        assert_eq!(std::fs::read_to_string(real.join("extensions/pi-permission-system/config.json")).unwrap(), r#"{"chat":true}"#);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn auto_review_link_toggles_and_protects_the_config() {
        let mut doc = json!({"authorizerChain": ["other"], "permission": {"path": {"*": "allow"}}});
        assert!(toggle_link(&mut doc, true));
        assert_eq!(doc["authorizerChain"], json!(["other", "auto-review"]));
        let pw = doc["permission"]["path_write"].as_object().unwrap();
        assert_eq!(pw.keys().next().map(String::as_str), Some("*"), "catch-all first");
        for p in SELF_PROTECT {
            assert_eq!(pw[*p]["action"], "deny", "{p}");
        }
        // Again: nothing to do.
        assert!(!toggle_link(&mut doc, true));
        // Off takes only the link out; the rules stay.
        assert!(toggle_link(&mut doc, false));
        assert_eq!(doc["authorizerChain"], json!(["other"]));
        assert!(doc["permission"]["path_write"]["~/.pi/agent/settings.json"].is_object());
        let mut alone = json!({"authorizerChain": ["auto-review"]});
        assert!(toggle_link(&mut alone, false));
        assert!(alone.get("authorizerChain").is_none(), "an empty chain is removed");
        // The recommended chat policy already protects the same paths.
        let chat: Value = serde_json::from_str(CHAT_POLICY).unwrap();
        for p in SELF_PROTECT {
            assert_eq!(chat["permission"]["path_write"][*p]["action"], "deny", "{p}");
        }
        assert!(serde_json::from_str::<Value>(AUTO_REVIEW_CONFIG).unwrap()["model"].is_string());
    }

    #[test]
    fn reviews_join_the_request_and_its_ending() {
        let log = [
            r#"{"timestamp":"t0","event":"permission_request.waiting","requestId":"a","surface":"bash","command":"rm -rf build","path":null}"#,
            r#"{"timestamp":"t1","event":"auto_review.decision","requestId":"a","outcome":"allow","durationMs":4000,"model":"claude-haiku-5-5","stage":"fast"}"#,
            r#"{"timestamp":"t1","event":"permission_request.approved","requestId":"a","decidedBy":{"kind":"authorizer","name":"auto-review","verdict":"allow","reason":null}}"#,
            r#"{"timestamp":"t2","event":"permission_request.waiting","requestId":"b","surface":"external_directory","command":null,"path":null,"decidingPath":"/etc/x"}"#,
            r#"{"timestamp":"t3","event":"auto_review.decision","requestId":"b","outcome":"deny","durationMs":6000,"model":"m"}"#,
            r#"{"timestamp":"t3","event":"permission_request.denied","requestId":"b","decidedBy":{"kind":"authorizer","name":"auto-review","verdict":"deny","reason":"[Scope] not asked for"}}"#,
            r#"not json"#,
            r#"{"timestamp":"t4","event":"permission_request.waiting","requestId":"c","surface":"bash","command":"git push --force"}"#,
            r#"{"timestamp":"t5","event":"auto_review.decision","requestId":"c","outcome":"defer","errorCategory":"provider-error"}"#,
            r#"{"timestamp":"t6","event":"permission_request.denied","requestId":"c","decidedBy":{"kind":"user","via":"select"}}"#,
            r#"{"timestamp":"t7","event":"permission_request.approved","requestId":"d","decidedBy":{"kind":"user"}}"#,
        ]
        .join("\n");
        let r = reviews_from_log(&log, 10);
        assert_eq!(r.len(), 3, "only requests auto review decided on");
        assert_eq!(r[0]["id"], "c");
        assert_eq!(r[0]["outcome"], "defer");
        assert_eq!(r[0]["then"], "denied");
        assert_eq!(r[0]["errorCategory"], "provider-error");
        assert_eq!(r[1]["outcome"], "deny");
        assert_eq!(r[1]["path"], "/etc/x");
        assert_eq!(r[1]["reason"], "[Scope] not asked for");
        assert_eq!(r[2]["command"], "rm -rf build");
        assert!(r[2].get("reason").is_none() && r[2].get("then").is_none());
        assert_eq!(reviews_from_log(&log, 1).len(), 1);
    }

    #[test]
    fn session_dir_matches_pis_encoding() {
        assert_eq!(
            default_session_dir(Path::new("/h/.pi/agent"), "/home/me/proj"),
            PathBuf::from("/h/.pi/agent/sessions/--home-me-proj--")
        );
    }
}
