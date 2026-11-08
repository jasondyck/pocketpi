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
    }))
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
        assert_eq!(stage["permission"]["bash"]["git push *"]["action"], "deny");
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
    fn session_dir_matches_pis_encoding() {
        assert_eq!(
            default_session_dir(Path::new("/h/.pi/agent"), "/home/me/proj"),
            PathBuf::from("/h/.pi/agent/sessions/--home-me-proj--")
        );
    }
}
