//! The instructions pi reads besides settings: context files (`AGENTS.md`
//! and friends) and the system prompt files (`SYSTEM.md`,
//! `APPEND_SYSTEM.md`), global and per project (Settings › Context;
//! docs/pi-parity-plan.md E6).
//!
//! | Route | Answer |
//! |---|---|
//! | `GET /api/pi/context[?cwd=]` | `{agentDir, cwd, maxBytes, epoch, trust?, files: [{scope, name, path, exists, size, editable, kind, loaded}], loaded: {context: [{path, scope, name}], system, append}}` |
//! | `GET /api/pi/context/file?scope=&name=[&cwd=]` | `{scope, name, path, exists, editable, kind, size, content}` |
//! | `POST /api/pi/context/file?scope=&name=[&cwd=]` | `{"content": "…"}` or `{"delete": true}` → the file as it is now, plus `epoch` |
//!
//! Only these files, never a path a client picks (`name` is looked up in
//! [`SLOTS`]; anything else is refused):
//!
//! | scope | name | where | edit |
//! |---|---|---|---|
//! | global | `AGENTS.override.md`, `AGENTS.md` | `<agent dir>/` | yes |
//! | global | `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD` | `<agent dir>/` | read only |
//! | global | `SYSTEM.md`, `APPEND_SYSTEM.md` | `<agent dir>/` | yes |
//! | project | `AGENTS.override.md`, `AGENTS.md` | `<cwd>/` | yes |
//! | project | `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD` | `<cwd>/` | read only |
//! | project | `SYSTEM.md`, `APPEND_SYSTEM.md` | `<cwd>/.pi/` | yes |
//!
//! What pi loads (its `core/resource-loader.js`): in each folder the first of
//! `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`;
//! the agent dir's first, then the cwd's parents from the root down, then the
//! cwd's. Context files need no project trust. `SYSTEM.md` replaces pi's
//! system prompt and `APPEND_SYSTEM.md` adds to it; a project's own
//! (`.pi/…`) wins over the global one when pi trusts the project (they're
//! not combined), and is ignored otherwise.
//!
//! Writes are `.tmp` + rename with `.pocketpi.bak` backups like every other
//! pocketpi edit of pi's files (`pi_admin::write_text`), capped at
//! [`MAX_BYTES`]; a delete keeps the file as the newest backup. pi reads
//! these when it starts, so each write bumps the config epoch ("Restart to
//! apply").

use crate::AppState;
use axum::{
    Json, Router,
    extract::{Query, State},
    http::StatusCode,
    routing::get,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

/// Largest file pocketpi writes (pi puts all of it in every request).
pub const MAX_BYTES: usize = 256 * 1024;

/// pi's context file names, in the order it looks for them in a folder.
pub const CONTEXT_NAMES: &[&str] = &["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Global,
    Project,
}

impl Scope {
    fn parse(s: &str) -> Option<Scope> {
        match s {
            "global" => Some(Scope::Global),
            "project" => Some(Scope::Project),
            _ => None,
        }
    }
    fn label(self) -> &'static str {
        match self {
            Scope::Global => "global",
            Scope::Project => "project",
        }
    }
}

/// One file pocketpi may show: its name, where it lives under the scope's
/// folder (agent dir or cwd), whether it can be written, and what it is.
pub struct Slot {
    pub scope: Scope,
    pub name: &'static str,
    pub rel: &'static str,
    pub editable: bool,
    /// "context", "system" or "append".
    pub kind: &'static str,
}

const fn slot(scope: Scope, name: &'static str, rel: &'static str, editable: bool, kind: &'static str) -> Slot {
    Slot { scope, name, rel, editable, kind }
}

pub const SLOTS: &[Slot] = &[
    slot(Scope::Global, "AGENTS.override.md", "AGENTS.override.md", true, "context"),
    slot(Scope::Global, "AGENTS.md", "AGENTS.md", true, "context"),
    slot(Scope::Global, "AGENTS.MD", "AGENTS.MD", false, "context"),
    slot(Scope::Global, "CLAUDE.md", "CLAUDE.md", false, "context"),
    slot(Scope::Global, "CLAUDE.MD", "CLAUDE.MD", false, "context"),
    slot(Scope::Global, "SYSTEM.md", "SYSTEM.md", true, "system"),
    slot(Scope::Global, "APPEND_SYSTEM.md", "APPEND_SYSTEM.md", true, "append"),
    slot(Scope::Project, "AGENTS.override.md", "AGENTS.override.md", true, "context"),
    slot(Scope::Project, "AGENTS.md", "AGENTS.md", true, "context"),
    slot(Scope::Project, "AGENTS.MD", "AGENTS.MD", false, "context"),
    slot(Scope::Project, "CLAUDE.md", "CLAUDE.md", false, "context"),
    slot(Scope::Project, "CLAUDE.MD", "CLAUDE.MD", false, "context"),
    slot(Scope::Project, "SYSTEM.md", ".pi/SYSTEM.md", true, "system"),
    slot(Scope::Project, "APPEND_SYSTEM.md", ".pi/APPEND_SYSTEM.md", true, "append"),
];

/// Files offered even when they don't exist yet (to create them).
fn offered_when_missing(s: &Slot) -> bool {
    matches!(s.name, "AGENTS.md" | "SYSTEM.md" | "APPEND_SYSTEM.md")
}

pub fn find_slot(scope: Scope, name: &str) -> Option<&'static Slot> {
    SLOTS.iter().find(|s| s.scope == scope && s.name == name)
}

/// A project folder from a client: it must exist and be a folder; the
/// canonical path is what's used from then on.
pub fn project_dir(cwd: &str) -> Result<PathBuf, String> {
    let dir = std::fs::canonicalize(cwd).map_err(|_| format!("folder not found: {cwd}"))?;
    if !dir.is_dir() {
        return Err(format!("not a folder: {cwd}"));
    }
    Ok(dir)
}

/// Where a slot's file is.
pub fn slot_path(s: &Slot, agent_dir: &Path, cwd: Option<&Path>) -> Result<PathBuf, String> {
    match s.scope {
        Scope::Global => Ok(agent_dir.join(s.rel)),
        Scope::Project => cwd.map(|c| c.join(s.rel)).ok_or_else(|| "a project file needs ?cwd=".to_string()),
    }
}

/// A regular file (following a symlink) at `p`.
fn is_file(p: &Path) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_file())
}

/// The context file pi takes from one folder.
pub fn context_file_in(dir: &Path) -> Option<PathBuf> {
    // pi takes the first that exists; on a case-insensitive disk AGENTS.MD
    // "exists" whenever AGENTS.md does, and pi then reports the earlier name.
    CONTEXT_NAMES.iter().map(|n| dir.join(n)).find(|p| is_file(p))
}

/// The context files pi loads for `cwd`, in its order: the agent dir's, then
/// the cwd's parents from the root down, then the cwd's (each path once).
pub fn loaded_context(agent_dir: &Path, cwd: Option<&Path>) -> Vec<(PathBuf, &'static str)> {
    let mut out: Vec<(PathBuf, &'static str)> = Vec::new();
    if let Some(g) = context_file_in(agent_dir) {
        out.push((g, "global"));
    }
    if let Some(cwd) = cwd {
        let mut chain = Vec::new();
        let mut cur = Some(cwd);
        while let Some(d) = cur {
            if let Some(f) = context_file_in(d)
                && !out.iter().any(|(p, _)| p == &f)
                && !chain.iter().any(|(p, _): &(PathBuf, &str)| p == &f)
            {
                chain.push((f, if d == cwd { "project" } else { "parent" }));
            }
            cur = d.parent();
        }
        chain.reverse();
        out.extend(chain);
    }
    out
}

/// `SYSTEM.md` / `APPEND_SYSTEM.md` as pi picks them: the project's when it
/// exists and the project is trusted, else the global one.
pub fn loaded_prompt(name: &str, agent_dir: &Path, cwd: Option<&Path>, trusted: bool) -> Option<(PathBuf, &'static str)> {
    if let Some(c) = cwd {
        let p = c.join(".pi").join(name);
        if trusted && is_file(&p) {
            return Some((p, "project"));
        }
    }
    let g = agent_dir.join(name);
    is_file(&g).then_some((g, "global"))
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new().route("/api/pi/context", get(overview)).route("/api/pi/context/file", get(read_file).post(write_file))
}

#[derive(Deserialize)]
struct CwdQuery {
    #[serde(default)]
    cwd: Option<String>,
}

fn cwd_of(q: Option<&str>) -> Result<Option<PathBuf>, (StatusCode, String)> {
    match q.filter(|c| !c.is_empty()) {
        None => Ok(None),
        Some(c) => project_dir(c).map(Some).map_err(|e| crate::err(StatusCode::BAD_REQUEST, e)),
    }
}

/// Whether pi trusts the project, as Settings › Trust works it out.
fn project_trust(app: &AppState, cwd: &Path) -> Value {
    let (entries, _, _) = crate::pi_resources::read_trust(&app.agent_dir);
    let global = std::fs::read_to_string(app.agent_dir.join("settings.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .unwrap_or_else(|| json!({}));
    let (default, _) = crate::pi_resources::default_trust(&global);
    crate::pi_resources::trust_for(&entries, &default, cwd, &app.home)
}

fn size_of(p: &Path) -> Option<u64> {
    std::fs::metadata(p).ok().filter(|m| m.is_file()).map(|m| m.len())
}

async fn overview(State(app): State<Arc<AppState>>, Query(q): Query<CwdQuery>) -> crate::AppResult<Json<Value>> {
    let cwd = cwd_of(q.cwd.as_deref())?;
    let trust = cwd.as_deref().map(|c| project_trust(&app, c));
    let trusted = trust.as_ref().is_some_and(|t| t["trusted"] == json!(true));
    let context = loaded_context(&app.agent_dir, cwd.as_deref());
    let system = loaded_prompt("SYSTEM.md", &app.agent_dir, cwd.as_deref(), trusted);
    let append = loaded_prompt("APPEND_SYSTEM.md", &app.agent_dir, cwd.as_deref(), trusted);
    let mut files = Vec::new();
    for s in SLOTS {
        if s.scope == Scope::Project && cwd.is_none() {
            continue;
        }
        let Ok(path) = slot_path(s, &app.agent_dir, cwd.as_deref()) else { continue };
        let size = size_of(&path);
        // A case-only twin (AGENTS.MD next to AGENTS.md on a case-insensitive
        // disk) is the same file: list each real entry once.
        let exists = size.is_some() && path.parent().is_some_and(|d| context_listed(d, s.name));
        if !exists && !offered_when_missing(s) {
            continue;
        }
        let loaded = match s.kind {
            "context" => context.iter().any(|(p, _)| p == &path),
            "system" => system.as_ref().is_some_and(|(p, _)| p == &path),
            _ => append.as_ref().is_some_and(|(p, _)| p == &path),
        };
        files.push(json!({
            "scope": s.scope.label(), "name": s.name, "path": path, "exists": exists,
            "size": if exists { size } else { None }, "editable": s.editable, "kind": s.kind, "loaded": loaded,
        }));
    }
    let entry = |x: &Option<(PathBuf, &str)>| x.as_ref().map(|(p, sc)| json!({"path": p, "scope": sc}));
    Ok(Json(json!({
        "agentDir": app.agent_dir,
        "cwd": cwd,
        "maxBytes": MAX_BYTES,
        "epoch": app.admin.epoch(),
        "trust": trust,
        "files": files,
        "loaded": {
            "context": context.iter().map(|(p, sc)| json!({
                "path": p, "scope": sc, "name": p.file_name().map(|n| n.to_string_lossy().into_owned()),
            })).collect::<Vec<_>>(),
            "system": entry(&system),
            "append": entry(&append),
        },
    })))
}

/// Whether `dir` holds an entry named exactly `name` (not just a case twin).
fn context_listed(dir: &Path, name: &str) -> bool {
    std::fs::read_dir(dir).ok().is_some_and(|mut d| d.any(|e| e.is_ok_and(|e| e.file_name() == name)))
}

#[derive(Deserialize)]
struct FileQuery {
    scope: String,
    name: String,
    #[serde(default)]
    cwd: Option<String>,
}

/// The slot and path a request names, or why not.
fn resolve(app: &AppState, q: &FileQuery) -> Result<(&'static Slot, PathBuf), (StatusCode, String)> {
    let bad = |m: String| crate::err(StatusCode::BAD_REQUEST, m);
    let scope = Scope::parse(&q.scope).ok_or_else(|| bad(format!("unknown scope: {}", q.scope)))?;
    let slot = find_slot(scope, &q.name).ok_or_else(|| bad(format!("not a context file pocketpi edits: {}", q.name)))?;
    let cwd = cwd_of(q.cwd.as_deref())?;
    if scope == Scope::Global && cwd.is_some() {
        return Err(bad("a global file takes no cwd".into()));
    }
    let path = slot_path(slot, &app.agent_dir, cwd.as_deref()).map_err(bad)?;
    Ok((slot, path))
}

fn file_view(slot: &Slot, path: &Path) -> Result<Value, (StatusCode, String)> {
    let (exists, content) = match std::fs::read(path) {
        Ok(b) => {
            if b.len() > MAX_BYTES * 4 {
                return Err(crate::err(StatusCode::PAYLOAD_TOO_LARGE, format!("{} is too big to show", path.display())));
            }
            (true, String::from_utf8_lossy(&b).trim_start_matches('\u{feff}').to_string())
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (false, String::new()),
        Err(e) if e.kind() == std::io::ErrorKind::IsADirectory => {
            return Err(crate::err(StatusCode::CONFLICT, format!("{} is a folder", path.display())));
        }
        Err(e) => return Err(crate::err(StatusCode::INTERNAL_SERVER_ERROR, format!("{}: {e}", path.display()))),
    };
    Ok(json!({
        "scope": slot.scope.label(), "name": slot.name, "path": path, "exists": exists,
        "editable": slot.editable, "kind": slot.kind, "size": content.len(), "content": content,
    }))
}

async fn read_file(State(app): State<Arc<AppState>>, Query(q): Query<FileQuery>) -> crate::AppResult<Json<Value>> {
    let (slot, path) = resolve(&app, &q)?;
    Ok(Json(file_view(slot, &path)?))
}

#[derive(Deserialize)]
struct WriteBody {
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    delete: bool,
}

/// Checks a write and does it. Separate from the route for the tests.
pub fn write_slot(slot: &Slot, path: &Path, content: Option<&str>, delete: bool) -> Result<(), (StatusCode, String)> {
    if !slot.editable {
        return Err(crate::err(StatusCode::FORBIDDEN, format!("{} is read only here", slot.name)));
    }
    if std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir()) {
        return Err(crate::err(StatusCode::CONFLICT, format!("{} is a folder", path.display())));
    }
    let io = |e: std::io::Error| crate::err(StatusCode::INTERNAL_SERVER_ERROR, format!("{}: {e}", path.display()));
    if delete {
        return crate::pi_admin::remove_with_backup(path).map_err(io);
    }
    let text = content.ok_or_else(|| crate::err(StatusCode::BAD_REQUEST, "content or delete is required"))?;
    if text.len() > MAX_BYTES {
        return Err(crate::err(StatusCode::PAYLOAD_TOO_LARGE, format!("at most {} KB", MAX_BYTES / 1024)));
    }
    if text.contains('\0') {
        return Err(crate::err(StatusCode::BAD_REQUEST, "not a text file"));
    }
    crate::pi_admin::write_text(path, text, 0o644).map_err(io)
}

async fn write_file(
    State(app): State<Arc<AppState>>,
    Query(q): Query<FileQuery>,
    Json(body): Json<WriteBody>,
) -> crate::AppResult<Json<Value>> {
    let (slot, path) = resolve(&app, &q)?;
    write_slot(slot, &path, body.content.as_deref(), body.delete)?;
    app.admin.bump();
    crate::config_changed(&app);
    let mut v = file_view(slot, &path)?;
    v["epoch"] = json!(app.admin.epoch());
    Ok(Json(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "pocketpi-context-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(d).unwrap()
    }

    #[test]
    fn only_allowlisted_names() {
        for bad in ["../AGENTS.md", "AGENTS.md/../../x", "/etc/passwd", "settings.json", "agents.md", ".pi/SYSTEM.md", ""] {
            assert!(find_slot(Scope::Global, bad).is_none(), "{bad}");
            assert!(find_slot(Scope::Project, bad).is_none(), "{bad}");
        }
        assert!(Scope::parse("../global").is_none());
        let a = find_slot(Scope::Global, "AGENTS.md").unwrap();
        assert!(a.editable);
        assert!(!find_slot(Scope::Project, "CLAUDE.md").unwrap().editable);
        // Every slot stays inside its folder.
        let base = Path::new("/base");
        for s in SLOTS {
            let p = slot_path(s, base, Some(base)).unwrap();
            assert!(p.starts_with(base) && !s.rel.contains(".."), "{}", s.name);
            assert!(p.ends_with(s.name));
        }
        assert!(slot_path(find_slot(Scope::Project, "AGENTS.md").unwrap(), base, None).is_err());
    }

    #[test]
    fn project_dir_must_exist() {
        let d = scratch();
        assert!(project_dir(d.join("nope").to_str().unwrap()).is_err());
        std::fs::write(d.join("f"), "x").unwrap();
        assert!(project_dir(d.join("f").to_str().unwrap()).is_err());
        // `..` is resolved, not trusted.
        std::fs::create_dir_all(d.join("a/b")).unwrap();
        assert_eq!(project_dir(d.join("a/b/..").to_str().unwrap()).unwrap(), d.join("a"));
        std::fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn writes_keep_backups_and_respect_the_rules() {
        let d = scratch();
        let agents = find_slot(Scope::Project, "AGENTS.md").unwrap();
        let p = d.join("AGENTS.md");
        write_slot(agents, &p, Some("one"), false).unwrap();
        write_slot(agents, &p, Some("two"), false).unwrap();
        write_slot(agents, &p, Some("three"), false).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "three");
        let b = crate::pi_admin::backup_paths(&p);
        assert_eq!(std::fs::read_to_string(&b[0]).unwrap(), "two");
        assert_eq!(std::fs::read_to_string(&b[1]).unwrap(), "one");
        // Too big, binary, read only: refused, file unchanged.
        let big = "x".repeat(MAX_BYTES + 1);
        assert_eq!(write_slot(agents, &p, Some(&big), false).unwrap_err().0, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(write_slot(agents, &p, Some("a\0b"), false).unwrap_err().0, StatusCode::BAD_REQUEST);
        let claude = find_slot(Scope::Project, "CLAUDE.md").unwrap();
        assert_eq!(write_slot(claude, &d.join("CLAUDE.md"), Some("x"), false).unwrap_err().0, StatusCode::FORBIDDEN);
        assert!(!d.join("CLAUDE.md").exists());
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "three");
        // Project SYSTEM.md goes in .pi/, which is made.
        let sys = find_slot(Scope::Project, "SYSTEM.md").unwrap();
        let sp = slot_path(sys, Path::new("/unused"), Some(&d)).unwrap();
        write_slot(sys, &sp, Some("You are terse."), false).unwrap();
        assert_eq!(std::fs::read_to_string(d.join(".pi/SYSTEM.md")).unwrap(), "You are terse.");
        // Delete keeps it as a backup.
        write_slot(sys, &sp, None, true).unwrap();
        assert!(!sp.exists());
        assert_eq!(std::fs::read_to_string(&crate::pi_admin::backup_paths(&sp)[0]).unwrap(), "You are terse.");
        std::fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn what_pi_loads() {
        let root = scratch();
        let agent = root.join("agent");
        let proj = root.join("work/proj");
        std::fs::create_dir_all(&agent).unwrap();
        std::fs::create_dir_all(proj.join(".pi")).unwrap();
        std::fs::write(agent.join("AGENTS.md"), "g").unwrap();
        std::fs::write(root.join("work/CLAUDE.md"), "parent").unwrap();
        std::fs::write(proj.join("AGENTS.md"), "p").unwrap();
        std::fs::write(proj.join("AGENTS.override.md"), "o").unwrap();
        let l = loaded_context(&agent, Some(&proj));
        let names: Vec<_> = l.iter().map(|(p, s)| (p.strip_prefix(&root).unwrap().to_string_lossy().into_owned(), *s)).collect();
        assert_eq!(
            names,
            [
                ("agent/AGENTS.md".to_string(), "global"),
                ("work/CLAUDE.md".to_string(), "parent"),
                ("work/proj/AGENTS.override.md".to_string(), "project")
            ]
        );
        // SYSTEM.md: the project's only when trusted, and not combined.
        std::fs::write(agent.join("SYSTEM.md"), "g").unwrap();
        std::fs::write(proj.join(".pi/SYSTEM.md"), "p").unwrap();
        assert_eq!(loaded_prompt("SYSTEM.md", &agent, Some(&proj), true).unwrap(), (proj.join(".pi/SYSTEM.md"), "project"));
        assert_eq!(loaded_prompt("SYSTEM.md", &agent, Some(&proj), false).unwrap(), (agent.join("SYSTEM.md"), "global"));
        assert!(loaded_prompt("APPEND_SYSTEM.md", &agent, Some(&proj), true).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}
