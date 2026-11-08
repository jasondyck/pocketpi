//! What pi loads: project trust and the resource browser (Settings › Trust,
//! Settings › Resources; docs/pi-parity-plan.md E5, F1).
//!
//! | Route | Answer |
//! |---|---|
//! | `GET /api/pi/trust` | `{path, exists, error?, default, defaultSet, entries, projects: [{path, name, canonical, decision, from, explicit, trusted, needsTrust, protected}], epoch}` |
//! | `GET /api/pi/resources[?cwd=]` | `{cwd, trust, builtins, resources, packages, packagesError?, settings, live?, liveError?}` |
//!
//! **trust.json** (pi's `core/trust-manager.js`) is one flat JSON object:
//! canonical directory path → `true` (trusted) or `false` (not trusted);
//! `null` is allowed and means "no decision". The nearest saved decision for
//! a folder or one of its parents applies. With none, pi uses the global
//! `defaultProjectTrust` (`ask`, the default; `always`; `never`); over RPC
//! (which is how pocketpi runs pi) `ask` can't ask, so it means *skip the
//! project's protected resources*. Writes go through the generic config
//! route (`POST /api/pi/config/trust`, a patch keyed by the escaped path).
//!
//! The resource scan follows pi's `core/package-manager.js`: packages (from
//! `pi list` plus the settings `packages` arrays), the settings
//! `extensions`/`skills`/`prompts` arrays, the auto-discovered folders
//! (`<agent>/{extensions,skills,prompts}`, `~/.agents/skills`,
//! `<cwd>/.pi/{extensions,skills,prompts}`, `.agents/skills` from the cwd up
//! to the repository root) and the built-in extensions, each with whether
//! the `+`/`-`/`!` overrides in settings leave it on. A live chat in the
//! project adds what pi really loaded (`get_commands` sourceInfo). Every
//! resource carries a `toggle` (`{key, scope, entry}`: the settings array
//! and the exact entry a `+`/`-` override would use) so turning things on
//! and off later is only a patch.

use crate::{AppState, Kind};
use axum::{
    Json, Router,
    extract::{Query, State},
    routing::get,
};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, atomic::Ordering},
    time::Duration,
};

/// pi's built-in extensions (`builtin:<name>` in `extensions`).
pub const BUILTINS: &[&str] = &["mcp", "llama.cpp", "codemode", "tool-search"];

/// What in `<cwd>/.pi` makes pi ask for project trust.
const TRUST_PROTECTED: &[&str] = &["settings.json", "mcp.json", "extensions", "skills", "prompts", "themes", "SYSTEM.md", "APPEND_SYSTEM.md"];

pub fn router() -> Router<Arc<AppState>> {
    Router::new().route("/api/pi/trust", get(trust_overview)).route("/api/pi/resources", get(resources))
}

// ------------------------------------------------------------------ trust

/// Reads `trust.json`: its entries, and an error when it isn't a JSON object.
pub fn read_trust(agent_dir: &Path) -> (Map<String, Value>, bool, Option<String>) {
    let path = agent_dir.join("trust.json");
    match std::fs::read_to_string(&path) {
        Err(_) => (Map::new(), false, None),
        Ok(t) if t.trim().is_empty() => (Map::new(), true, None),
        Ok(t) => match serde_json::from_str::<Value>(t.trim_start_matches('\u{feff}')) {
            Ok(Value::Object(m)) => (m, true, None),
            Ok(_) => (Map::new(), true, Some(format!("{} is not a JSON object", path.display()))),
            Err(e) => (Map::new(), true, Some(format!("{} is not valid JSON: {e}", path.display()))),
        },
    }
}

/// The nearest saved decision for `dir` or one of its parents: (key, decision).
pub fn nearest_decision(entries: &Map<String, Value>, dir: &Path) -> Option<(String, bool)> {
    let mut cur = Some(dir);
    while let Some(d) = cur {
        let key = d.to_string_lossy();
        if let Some(Value::Bool(b)) = entries.get(key.as_ref()) {
            return Some((key.into_owned(), *b));
        }
        cur = d.parent();
    }
    None
}

/// The things in `cwd` that make pi want a trust decision: entries of
/// `.pi/` and `.agents/skills` folders in the cwd or its parents (but not
/// the user's own `~/.agents/skills`). Empty: nothing for trust to gate.
pub fn protected_resources(cwd: &Path, home: &Path) -> Vec<String> {
    let mut found: Vec<String> = TRUST_PROTECTED.iter().filter(|e| cwd.join(".pi").join(e).exists()).map(|e| format!(".pi/{e}")).collect();
    let user_skills = home.join(".agents/skills");
    let mut cur = Some(cwd);
    while let Some(d) = cur {
        let s = d.join(".agents/skills");
        if s != user_skills && s.exists() {
            found.push(s.to_string_lossy().into_owned());
        }
        cur = d.parent();
    }
    found
}

/// `defaultProjectTrust` from the global settings, and whether it is set.
pub fn default_trust(global: &Value) -> (String, bool) {
    match global.get("defaultProjectTrust").and_then(Value::as_str) {
        Some(s @ ("ask" | "always" | "never")) => (s.to_string(), true),
        _ => ("ask".to_string(), false),
    }
}

/// One folder's trust as pi in RPC mode resolves it.
pub fn trust_for(entries: &Map<String, Value>, default: &str, dir: &Path, home: &Path) -> Value {
    let canonical = std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    let near = nearest_decision(entries, &canonical);
    let protected = protected_resources(&canonical, home);
    let canonical_s = canonical.to_string_lossy().into_owned();
    json!({
        "canonical": canonical_s,
        "decision": near.as_ref().map(|n| n.1),
        "from": near.as_ref().map(|n| n.0.clone()),
        "explicit": near.as_ref().is_some_and(|n| n.0 == canonical_s),
        // RPC can't ask: only a saved yes or "always" loads the project's resources.
        "trusted": near.map(|n| n.1).unwrap_or(default == "always"),
        "needsTrust": !protected.is_empty(),
        "protected": protected,
    })
}

fn read_json(path: &Path) -> Value {
    std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}))
}

async fn trust_overview(State(app): State<Arc<AppState>>) -> Json<Value> {
    let (entries, exists, error) = read_trust(&app.agent_dir);
    let global = read_json(&app.agent_dir.join("settings.json"));
    let (default, default_set) = default_trust(&global);
    let Json(p) = crate::list_projects(State(app.clone())).await;
    let projects: Vec<Value> = p["projects"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|pr| {
            let path = pr["path"].as_str().unwrap_or("").to_string();
            let mut t = trust_for(&entries, &default, Path::new(&path), &app.home);
            t["path"] = json!(path);
            t["name"] = pr["name"].clone();
            t["exists"] = pr["exists"].clone();
            t
        })
        .collect();
    Json(json!({
        "path": app.agent_dir.join("trust.json"),
        "exists": exists,
        "error": error,
        "default": default,
        "defaultSet": default_set,
        "entries": entries,
        "projects": projects,
        "epoch": app.admin.epoch(),
    }))
}

// ------------------------------------------------------------------ patterns

/// Glob matching like minimatch for what settings use: `*` and `?` within
/// a path segment, `**` across segments.
pub fn glob_match(pattern: &str, path: &str) -> bool {
    fn seg(p: &[char], s: &[char]) -> bool {
        match (p.first(), s.first()) {
            (None, None) => true,
            (Some('*'), _) => seg(&p[1..], s) || (!s.is_empty() && seg(p, &s[1..])),
            (Some('?'), Some(_)) => seg(&p[1..], &s[1..]),
            (Some(a), Some(b)) if a == b => seg(&p[1..], &s[1..]),
            _ => false,
        }
    }
    fn segs(p: &[&str], s: &[&str]) -> bool {
        match p.first() {
            None => s.is_empty(),
            Some(&"**") => segs(&p[1..], s) || (!s.is_empty() && segs(p, &s[1..])),
            Some(first) => {
                !s.is_empty() && seg(&first.chars().collect::<Vec<_>>(), &s[0].chars().collect::<Vec<_>>()) && segs(&p[1..], &s[1..])
            }
        }
    }
    let p: Vec<&str> = pattern.split('/').collect();
    let s: Vec<&str> = path.split('/').collect();
    segs(&p, &s)
}

fn rel(base: &Path, path: &Path) -> Option<String> {
    Some(relative(base, path))
}

/// Node's `path.relative` for two absolute paths: `..` up from `base`, then
/// down to `path` ("" when they're the same).
pub fn relative(base: &Path, path: &Path) -> String {
    let b: Vec<_> = base.components().collect();
    let p: Vec<_> = path.components().collect();
    let common = b.iter().zip(&p).take_while(|(x, y)| x == y).count();
    let mut out: Vec<String> = std::iter::repeat_n("..".to_string(), b.len() - common).collect();
    out.extend(p[common..].iter().map(|c| c.as_os_str().to_string_lossy().into_owned()));
    out.join("/")
}

fn strip_dot(p: &str) -> &str {
    p.strip_prefix("./").unwrap_or(p)
}

/// pi's `matchesAnyPattern` (globs) and `matchesAnyExactPattern` (exact):
/// against the path relative to `base`, the file name, the absolute path,
/// and for a `SKILL.md` its folder the same three ways.
pub(crate) fn matches(path: &Path, pattern: &str, base: &Path, exact: bool) -> bool {
    let pattern = strip_dot(pattern);
    let test = |p: &Path| -> bool {
        let candidates = [rel(base, p), p.file_name().map(|n| n.to_string_lossy().into_owned()), Some(p.to_string_lossy().into_owned())];
        candidates.iter().flatten().any(|c| if exact { c == pattern } else { glob_match(pattern, c) })
    };
    if exact {
        // The exact forms are only the relative and the absolute path.
        let r = rel(base, path);
        if r.as_deref() == Some(pattern) || path.to_string_lossy() == pattern {
            return true;
        }
        if path.file_name().is_some_and(|n| n == "SKILL.md") {
            if let Some(dir) = path.parent() {
                return rel(base, dir).as_deref() == Some(pattern) || dir.to_string_lossy() == pattern;
            }
        }
        return false;
    }
    test(path) || (path.file_name().is_some_and(|n| n == "SKILL.md") && path.parent().is_some_and(test))
}

/// pi's `isEnabledByOverrides`: `!glob` turns off, then `+path` on, then
/// `-path` off. Plain entries don't count here.
pub fn enabled_by_overrides(path: &Path, entries: &[String], base: &Path) -> bool {
    let mut on = true;
    if entries.iter().filter_map(|e| e.strip_prefix('!')).any(|p| matches(path, p, base, false)) {
        on = false;
    }
    if entries.iter().filter_map(|e| e.strip_prefix('+')).any(|p| matches(path, p, base, true)) {
        on = true;
    }
    if entries.iter().filter_map(|e| e.strip_prefix('-')).any(|p| matches(path, p, base, true)) {
        on = false;
    }
    on
}

/// A built-in in the global `extensions` (pi's `isEnabledByOverrides` on
/// the path `builtin:<name>`): a matching `!glob` turns it off, an exact
/// `+builtin:x` back on, an exact `-builtin:x` off, whatever their order.
pub fn builtin_global_enabled(name: &str, entries: &[String]) -> bool {
    let id = format!("builtin:{name}");
    let mut on = true;
    if entries.iter().filter_map(|e| e.strip_prefix('!')).any(|p| glob_match(p, &id)) {
        on = false;
    }
    if entries.iter().filter_map(|e| e.strip_prefix('+')).any(|p| strip_dot(p) == id) {
        on = true;
    }
    if entries.iter().filter_map(|e| e.strip_prefix('-')).any(|p| strip_dot(p) == id) {
        on = false;
    }
    on
}

/// A built-in in a project's `extensions` (pi's
/// `applyAutoloadDisabledPatterns`): the last override entry naming it wins
/// (`!glob`, `-builtin:x` off; `+builtin:x` on); None when none names it.
pub fn builtin_project_override(name: &str, entries: &[String]) -> Option<bool> {
    let id = format!("builtin:{name}");
    let mut r = None;
    for e in entries {
        if let Some(p) = e.strip_prefix('!') {
            if glob_match(p, &id) {
                r = Some(false);
            }
        } else if let Some(p) = e.strip_prefix('-') {
            if strip_dot(p) == id {
                r = Some(false);
            }
        } else if let Some(p) = e.strip_prefix('+') {
            if strip_dot(p) == id {
                r = Some(true);
            }
        }
    }
    r
}

fn strings(v: &Value, key: &str) -> Vec<String> {
    v.get(key).and_then(Value::as_array).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
}

// ------------------------------------------------------------------ discovery

fn is_dir(p: &Path) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_dir())
}

fn is_file(p: &Path) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.is_file())
}

/// Directory entries, sorted, without dot files and node_modules.
fn children(dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| {
                    let n = e.file_name();
                    let n = n.to_string_lossy();
                    !n.starts_with('.') && n != "node_modules"
                })
                .map(|e| e.path())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

fn read_manifest(dir: &Path) -> Option<Value> {
    let v = read_json(&dir.join("package.json"));
    v.get("pi").filter(|p| p.is_object()).cloned()
}

/// pi's `resolveExtensionEntries`: a folder that is one extension.
fn extension_entry(dir: &Path) -> Option<Vec<PathBuf>> {
    if let Some(m) = read_manifest(dir) {
        let list: Vec<PathBuf> = strings(&m, "extensions").iter().map(|e| dir.join(strip_dot(e))).filter(|p| p.exists()).collect();
        if !list.is_empty() {
            return Some(list);
        }
    }
    ["index.ts", "index.js"].iter().map(|n| dir.join(n)).find(|p| p.exists()).map(|p| vec![p])
}

/// pi's `collectAutoExtensionEntries`: `*.ts`/`*.js` and one-level folders.
pub fn collect_extensions(dir: &Path) -> Vec<PathBuf> {
    if !is_dir(dir) {
        return vec![];
    }
    if let Some(e) = extension_entry(dir) {
        return e;
    }
    let mut out = vec![];
    for p in children(dir) {
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        if is_file(&p) && (name.ends_with(".ts") || name.ends_with(".js")) {
            out.push(p);
        } else if is_dir(&p) {
            if let Some(e) = extension_entry(&p) {
                out.extend(e);
            }
        }
    }
    out
}

/// pi's `collectSkillEntries`: a folder with `SKILL.md` is one skill (and
/// isn't searched further); otherwise its subfolders are. Loose `.md` files
/// count at the top of a pi skills folder ("pi" mode) and below the top of
/// an `.agents/skills` folder ("agents" mode).
pub fn collect_skills(dir: &Path, agents_mode: bool) -> Vec<PathBuf> {
    fn walk(dir: &Path, root: &Path, agents: bool, out: &mut Vec<PathBuf>) {
        let skill = dir.join("SKILL.md");
        if is_file(&skill) {
            out.push(skill);
            return;
        }
        for p in children(dir) {
            let md = p.extension().is_some_and(|e| e == "md");
            if is_file(&p) && md && ((!agents && dir == root) || (agents && dir != root)) {
                out.push(p);
            } else if is_dir(&p) {
                walk(&p, root, agents, out);
            }
        }
    }
    let mut out = vec![];
    if is_dir(dir) {
        walk(dir, dir, agents_mode, &mut out);
    }
    out
}

/// A prompts folder: its direct `.md` children (`recursive` for folders
/// named in settings or packages).
pub fn collect_prompts(dir: &Path, recursive: bool) -> Vec<PathBuf> {
    let mut out = vec![];
    for p in children(dir) {
        if is_file(&p) && p.extension().is_some_and(|e| e == "md") {
            out.push(p);
        } else if recursive && is_dir(&p) {
            out.extend(collect_prompts(&p, true));
        }
    }
    out
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind3 {
    Extension,
    Skill,
    Prompt,
}

impl Kind3 {
    fn key(self) -> &'static str {
        match self {
            Kind3::Extension => "extensions",
            Kind3::Skill => "skills",
            Kind3::Prompt => "prompts",
        }
    }
    fn label(self) -> &'static str {
        match self {
            Kind3::Extension => "extension",
            Kind3::Skill => "skill",
            Kind3::Prompt => "prompt",
        }
    }
    const ALL: [Kind3; 3] = [Kind3::Extension, Kind3::Skill, Kind3::Prompt];
}

/// A folder or file named in settings or a package manifest, as files.
fn collect_path(p: &Path, kind: Kind3) -> Vec<PathBuf> {
    if is_file(p) {
        return vec![p.to_path_buf()];
    }
    if !is_dir(p) {
        return vec![];
    }
    match kind {
        Kind3::Extension => collect_extensions(p),
        Kind3::Skill => collect_skills(p, false),
        Kind3::Prompt => collect_prompts(p, true),
    }
}

/// Every file under `root` matching `pattern` (relative to `root`).
fn expand_glob(root: &Path, pattern: &str) -> Vec<PathBuf> {
    let pattern = strip_dot(pattern);
    let fixed: Vec<&str> = pattern.split('/').take_while(|s| !s.contains('*') && !s.contains('?')).collect();
    let start = root.join(fixed.join("/"));
    let mut out = vec![];
    fn walk(d: &Path, root: &Path, pattern: &str, out: &mut Vec<PathBuf>, depth: usize) {
        if depth > 8 {
            return;
        }
        for p in children(d) {
            if let Some(r) = rel(root, &p) {
                if glob_match(pattern, &r) {
                    out.push(p.clone());
                    continue;
                }
            }
            if is_dir(&p) {
                walk(&p, root, pattern, out, depth + 1);
            }
        }
    }
    walk(&start, root, pattern, &mut out, 0);
    out
}

fn expand_home(s: &str, home: &Path) -> PathBuf {
    if s == "~" {
        home.to_path_buf()
    } else if let Some(r) = s.strip_prefix("~/") {
        home.join(r)
    } else {
        PathBuf::from(s)
    }
}

/// pi's `resolvePathFromBase`.
fn resolve(entry: &str, base: &Path, home: &Path) -> PathBuf {
    let p = expand_home(entry, home);
    if p.is_absolute() { p } else { base.join(strip_dot(entry)) }
}

// ------------------------------------------------------------------ metadata

/// The YAML front matter's flat `key: value` pairs (quotes taken off,
/// `>`/`|` blocks joined) and the body after it.
pub fn frontmatter(text: &str) -> (Map<String, Value>, String) {
    let text = text.trim_start_matches('\u{feff}');
    let mut map = Map::new();
    let mut lines = text.lines();
    if lines.next().map(str::trim_end) != Some("---") {
        return (map, text.to_string());
    }
    let mut body_start = None;
    let all: Vec<&str> = text.lines().collect();
    for (i, l) in all.iter().enumerate().skip(1) {
        if l.trim_end() == "---" {
            body_start = Some(i + 1);
            break;
        }
    }
    let Some(end) = body_start else { return (map, text.to_string()) };
    let head = &all[1..end - 1];
    let mut i = 0;
    while i < head.len() {
        let l = head[i];
        i += 1;
        if l.starts_with(' ') || l.starts_with('\t') || l.trim_start().starts_with('#') {
            continue;
        }
        let Some((k, v)) = l.split_once(':') else { continue };
        let k = k.trim().to_string();
        let v = v.trim();
        if v.starts_with('>') || v.starts_with('|') {
            let mut parts = vec![];
            while i < head.len() && (head[i].starts_with(' ') || head[i].starts_with('\t') || head[i].trim().is_empty()) {
                parts.push(head[i].trim());
                i += 1;
            }
            let sep = if v.starts_with('>') { " " } else { "\n" };
            map.insert(k, json!(parts.join(sep).trim()));
        } else {
            let v = v.strip_prefix('"').and_then(|x| x.strip_suffix('"')).or_else(|| v.strip_prefix('\'').and_then(|x| x.strip_suffix('\''))).unwrap_or(v);
            map.insert(k, json!(v));
        }
    }
    (map, all[end..].join("\n"))
}

fn name_of_extension(p: &Path) -> String {
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    if stem == "index" {
        if let Some(d) = p.parent().and_then(Path::file_name) {
            return d.to_string_lossy().into_owned();
        }
    }
    stem
}

/// name, description and argument hint for one resource file.
fn describe(kind: Kind3, p: &Path) -> (String, Option<String>, Option<String>) {
    match kind {
        Kind3::Extension => (name_of_extension(p), None, None),
        Kind3::Skill | Kind3::Prompt => {
            let text = std::fs::read_to_string(p).unwrap_or_default();
            let (fm, body) = frontmatter(&text);
            let s = |k: &str| fm.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from);
            let file_name = if kind == Kind3::Skill && p.file_name().is_some_and(|n| n == "SKILL.md") {
                p.parent().and_then(Path::file_name)
            } else {
                p.file_stem()
            }
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
            if kind == Kind3::Skill {
                (s("name").unwrap_or(file_name), s("description"), None)
            } else {
                let first = body.lines().map(str::trim).find(|l| !l.is_empty()).map(|l| l.chars().take(200).collect());
                (file_name, s("description").or(first), s("argument-hint"))
            }
        }
    }
}

// ------------------------------------------------------------------ the scan

/// A package as configured, with where pi installed it.
#[derive(Clone, Debug, PartialEq)]
pub struct Package {
    pub source: String,
    /// "user" or "project".
    pub scope: String,
    pub installed: Option<PathBuf>,
    /// The object form in settings, which narrows what loads.
    pub filter: Option<Value>,
}

/// `pi list`'s text: "User packages:" / "Project packages:", each source
/// indented two spaces (`(filtered)` after it for the object form) and its
/// install path, when installed, indented four.
pub fn parse_pi_list(text: &str) -> Vec<(String, String, Option<PathBuf>)> {
    let mut out: Vec<(String, String, Option<PathBuf>)> = vec![];
    let mut scope = "user";
    for raw in text.lines() {
        let line = strip_ansi(raw);
        if line.starts_with("User packages") {
            scope = "user";
        } else if line.starts_with("Project packages") {
            scope = "project";
        } else if let Some(p) = line.strip_prefix("    ") {
            if let Some(last) = out.last_mut() {
                last.2 = Some(PathBuf::from(p.trim()));
            }
        } else if let Some(s) = line.strip_prefix("  ") {
            let s = s.trim();
            let s = s.strip_suffix(" (filtered)").unwrap_or(s);
            out.push((scope.to_string(), s.to_string(), None));
        }
    }
    out
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            if chars.peek() == Some(&'[') {
                chars.next();
                for n in chars.by_ref() {
                    if n.is_ascii_alphabetic() {
                        break;
                    }
                }
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// The packages the settings name, with install paths from `pi list` when
/// it ran, else where pi would have put local and npm ones.
pub fn packages_from_settings(
    global: &Value,
    project: &Value,
    listed: Option<&[(String, String, Option<PathBuf>)]>,
    agent_dir: &Path,
    project_pi: Option<&Path>,
    home: &Path,
) -> Vec<Package> {
    let mut out = vec![];
    for (scope, doc, base) in [("project", project, project_pi), ("user", global, Some(agent_dir))] {
        let Some(base) = base else { continue };
        for p in doc.get("packages").and_then(Value::as_array).cloned().unwrap_or_default() {
            let (source, filter) = match &p {
                Value::String(s) => (s.clone(), None),
                Value::Object(o) => match o.get("source").and_then(Value::as_str) {
                    Some(s) => (s.to_string(), Some(p.clone())),
                    None => continue,
                },
                _ => continue,
            };
            let installed = match listed {
                Some(l) => l.iter().find(|(sc, s, _)| sc == scope && *s == source).and_then(|x| x.2.clone()),
                None => guess_install(&source, base, agent_dir, home),
            };
            out.push(Package { source, scope: scope.into(), installed: installed.filter(|p| p.exists()), filter });
        }
    }
    out
}

fn guess_install(source: &str, base: &Path, agent_dir: &Path, home: &Path) -> Option<PathBuf> {
    if let Some(spec) = source.strip_prefix("npm:") {
        // "@scope/name@1.2" or "name@1.2" → the name.
        let name = match spec.strip_prefix('@') {
            Some(rest) => format!("@{}", rest.split('@').next().unwrap_or(rest)),
            None => spec.split('@').next().unwrap_or(spec).to_string(),
        };
        return Some(agent_dir.join("npm/node_modules").join(name));
    }
    if ["git:", "http://", "https://", "ssh://", "git@"].iter().any(|p| source.starts_with(p)) {
        return None;
    }
    Some(resolve(source, base, home))
}

/// One package's resources: its object-form filter, else its `pi`
/// manifest, else its `extensions`/`skills`/`prompts` folders.
fn package_files(root: &Path, kind: Kind3) -> Vec<PathBuf> {
    if let Some(m) = read_manifest(root) {
        if m.get(kind.key()).is_some() || Kind3::ALL.iter().any(|k| m.get(k.key()).is_some()) {
            let mut out = vec![];
            for e in strings(&m, kind.key()) {
                if e.starts_with('!') || e.starts_with('+') || e.starts_with('-') {
                    continue;
                }
                if e.contains('*') || e.contains('?') {
                    for f in expand_glob(root, &e) {
                        out.extend(collect_path(&f, kind));
                    }
                } else {
                    out.extend(collect_path(&root.join(strip_dot(&e)), kind));
                }
            }
            return out;
        }
    }
    collect_path(&root.join(kind.key()), kind)
}

/// What a scan needs to know.
pub struct Scan<'a> {
    pub agent_dir: &'a Path,
    pub home: &'a Path,
    /// The project (canonical), if one is picked.
    pub cwd: Option<&'a Path>,
    /// Whether pi (in RPC mode) loads the project's protected resources.
    pub trusted: bool,
    pub global: &'a Value,
    pub project: &'a Value,
    pub packages: &'a [Package],
}

struct Acc {
    list: Vec<Value>,
}

impl Acc {
    fn has(&self, path: &Path) -> bool {
        let p = path.to_string_lossy();
        self.list.iter().any(|r| r["path"].as_str() == Some(p.as_ref()))
    }
}

/// Everything pi would load for `cwd`, in pi's order (the first of two
/// copies of a path wins), plus what it skips and why.
pub fn scan(s: &Scan) -> Vec<Value> {
    let mut acc = Acc { list: vec![] };
    let project_pi = s.cwd.map(|c| c.join(".pi"));
    let g = |k: Kind3| strings(s.global, k.key());
    let pr = |k: Kind3| strings(s.project, k.key());

    #[allow(clippy::too_many_arguments)]
    fn add(
        acc: &mut Acc,
        kind: Kind3,
        path: &Path,
        scope: &str,
        origin: &str,
        enabled: bool,
        skipped: Option<&str>,
        package: Option<&Package>,
        toggle: Value,
    ) {
        if acc.has(path) {
            return;
        }
        let (name, description, hint) = describe(kind, path);
        acc.list.push(json!({
            "kind": kind.label(),
            "name": name,
            "description": description,
            "argumentHint": hint,
            "path": path,
            "scope": scope,
            "origin": origin,
            "package": package.map(|p| json!({"source": p.source, "scope": p.scope})),
            "enabled": enabled,
            "loads": enabled && skipped.is_none(),
            "skipped": skipped,
            "toggle": toggle,
            "commands": [],
            "live": false,
        }));
    }
    // The settings entry a +/- override would use for this file.
    // pi's own pattern (`pi config`'s getResourcePattern): the file relative
    // to the folder its overrides are matched against.
    let toggle = |kind: Kind3, path: &Path, scope: &str, base: &Path| -> Value {
        json!({"key": kind.key(), "scope": scope, "entry": relative(base, path)})
    };
    let untrusted = (!s.trusted).then_some("project not trusted");

    // 1. Packages, project ones first.
    for p in s.packages {
        let Some(root) = &p.installed else { continue };
        let skip = if p.scope == "project" { untrusted } else { None };
        for kind in Kind3::ALL {
            let narrowed = p.filter.as_ref().and_then(|f| f.get(kind.key())).and_then(Value::as_array);
            for f in package_files(root, kind) {
                let enabled = match narrowed {
                    None => true,
                    Some(pats) => {
                        let pats: Vec<String> = pats.iter().filter_map(|x| x.as_str().map(String::from)).collect();
                        let plain: Vec<&String> = pats.iter().filter(|x| !x.starts_with(['!', '+', '-'])).collect();
                        let mut on = plain.iter().any(|x| matches(&f, x, root, false) || matches(&f, x, root, true));
                        if !pats.iter().any(|x| !x.starts_with(['!', '+', '-'])) && !pats.is_empty() {
                            on = true;
                        }
                        on && enabled_by_overrides(&f, &pats, root)
                    }
                };
                let t = json!({"key": "packages", "scope": if p.scope == "project" { "project" } else { "global" }, "package": p.source, "resource": kind.key(), "entry": rel(root, &f)});
                add(&mut acc, kind, &f, "package", "package", enabled, skip, Some(p), t);
            }
        }
    }

    // 2. Files and folders named in settings: project, then global.
    for kind in Kind3::ALL {
        if let Some(base) = &project_pi {
            let entries = pr(kind);
            for e in entries.iter().filter(|e| !e.starts_with(['!', '+', '-']) && !e.starts_with("builtin:")) {
                for f in collect_path(&resolve(e, base, s.home), kind) {
                    let on = enabled_by_overrides(&f, &entries, base);
                    add(&mut acc, kind, &f, "project", "settings", on, untrusted, None, toggle(kind, &f, "project", base));
                }
            }
        }
        let entries = g(kind);
        for e in entries.iter().filter(|e| !e.starts_with(['!', '+', '-']) && !e.starts_with("builtin:")) {
            for f in collect_path(&resolve(e, s.agent_dir, s.home), kind) {
                let on = enabled_by_overrides(&f, &entries, s.agent_dir);
                add(&mut acc, kind, &f, "global", "settings", on, None, None, toggle(kind, &f, "global", s.agent_dir));
            }
        }
    }

    // 3. Auto-discovered folders, in pi's order.
    let user_agents = s.home.join(".agents/skills");
    if let (Some(cwd), Some(base)) = (s.cwd, &project_pi) {
        for f in collect_extensions(&base.join("extensions")) {
            add(&mut acc, Kind3::Extension, &f, "project", "auto", enabled_by_overrides(&f, &pr(Kind3::Extension), base), untrusted, None, toggle(Kind3::Extension, &f, "project", base));
        }
        for f in collect_skills(&base.join("skills"), false) {
            add(&mut acc, Kind3::Skill, &f, "project", "auto", enabled_by_overrides(&f, &pr(Kind3::Skill), base), untrusted, None, toggle(Kind3::Skill, &f, "project", base));
        }
        for dir in ancestor_agents_skills(cwd).into_iter().filter(|d| *d != user_agents) {
            let agents_base = dir.parent().unwrap_or(&dir).to_path_buf();
            for f in collect_skills(&dir, true) {
                add(&mut acc, Kind3::Skill, &f, "project", "auto", enabled_by_overrides(&f, &pr(Kind3::Skill), &agents_base), untrusted, None, toggle(Kind3::Skill, &f, "project", &agents_base));
            }
        }
        for f in collect_prompts(&base.join("prompts"), false) {
            add(&mut acc, Kind3::Prompt, &f, "project", "auto", enabled_by_overrides(&f, &pr(Kind3::Prompt), base), untrusted, None, toggle(Kind3::Prompt, &f, "project", base));
        }
    }
    let a = s.agent_dir;
    for f in collect_extensions(&a.join("extensions")) {
        add(&mut acc, Kind3::Extension, &f, "global", "auto", enabled_by_overrides(&f, &g(Kind3::Extension), a), None, None, toggle(Kind3::Extension, &f, "global", a));
    }
    for f in collect_skills(&a.join("skills"), false) {
        add(&mut acc, Kind3::Skill, &f, "global", "auto", enabled_by_overrides(&f, &g(Kind3::Skill), a), None, None, toggle(Kind3::Skill, &f, "global", a));
    }
    let agents_base = s.home.join(".agents");
    for f in collect_skills(&user_agents, true) {
        add(&mut acc, Kind3::Skill, &f, "global", "auto", enabled_by_overrides(&f, &g(Kind3::Skill), &agents_base), None, None, toggle(Kind3::Skill, &f, "global", &agents_base));
    }
    for f in collect_prompts(&a.join("prompts"), false) {
        add(&mut acc, Kind3::Prompt, &f, "global", "auto", enabled_by_overrides(&f, &g(Kind3::Prompt), a), None, None, toggle(Kind3::Prompt, &f, "global", a));
    }

    // 4. Built-in extensions: on unless the global `extensions` says
    // `-builtin:x`; a project entry (when the project is trusted) wins.
    for b in BUILTINS {
        let global = builtin_global_enabled(b, &g(Kind3::Extension));
        let project = if s.trusted { builtin_project_override(b, &pr(Kind3::Extension)) } else { None };
        let on = project.unwrap_or(global);
        let scope = if project.is_some() { "project" } else { "global" };
        acc.list.push(json!({
            "kind": "extension",
            "name": b,
            "description": builtin_description(b),
            "argumentHint": null,
            "path": format!("builtin:{b}"),
            "scope": "builtin",
            "origin": "builtin",
            "package": null,
            "enabled": on,
            "loads": on,
            "skipped": null,
            "disabledBy": if on { Value::Null } else { json!(format!("-builtin:{b} in {scope} settings")) },
            "toggle": {"key": "extensions", "scope": scope, "entry": format!("builtin:{b}")},
            "commands": [],
            "live": false,
        }));
    }
    acc.list
}

fn builtin_description(name: &str) -> &'static str {
    match name {
        "mcp" => "MCP servers from mcp.json",
        "llama.cpp" => "Local models from a llama.cpp server",
        "codemode" => "Lets the model call tools from code",
        "tool-search" => "Lets the model find tools it doesn't see yet",
        _ => "",
    }
}

/// `.agents/skills` from `cwd` up to the repository root (or `/`).
fn ancestor_agents_skills(cwd: &Path) -> Vec<PathBuf> {
    let root = {
        let mut cur = Some(cwd);
        let mut found = None;
        while let Some(d) = cur {
            if d.join(".git").exists() {
                found = Some(d.to_path_buf());
                break;
            }
            cur = d.parent();
        }
        found
    };
    let mut out = vec![];
    let mut cur = Some(cwd);
    while let Some(d) = cur {
        out.push(d.join(".agents/skills"));
        if root.as_deref() == Some(d) {
            break;
        }
        cur = d.parent();
    }
    out
}

/// Folds a live chat's `get_commands` into the scan: each command marks its
/// resource as running (and lists the extension's commands); a command
/// from something the scan didn't find (`-e` extensions, packages it
/// couldn't see) becomes a resource of its own.
pub fn merge_live(list: &mut Vec<Value>, commands: &[Value]) {
    for c in commands {
        let name = c["name"].as_str().unwrap_or("");
        if name.starts_with("pp-") {
            continue;
        }
        let kind = match c["source"].as_str() {
            Some("extension") => Kind3::Extension,
            Some("skill") => Kind3::Skill,
            Some("prompt") => Kind3::Prompt,
            _ => continue,
        };
        let info = &c["sourceInfo"];
        let path = info["path"].as_str().unwrap_or("");
        let same = |r: &Value| {
            r["kind"] == kind.label()
                && r["path"].as_str().is_some_and(|p| {
                    p == path || matches!((std::fs::canonicalize(p), std::fs::canonicalize(path)), (Ok(a), Ok(b)) if a == b)
                })
        };
        if let Some(r) = list.iter_mut().find(|r| same(r)) {
            r["live"] = json!(true);
            if kind == Kind3::Extension {
                r["commands"].as_array_mut().unwrap().push(json!(name));
            }
            continue;
        }
        let scope = if info["origin"] == "package" {
            "package"
        } else if info["source"] == "builtin" {
            "builtin"
        } else {
            match info["scope"].as_str() {
                Some("project") => "project",
                Some("user") => "global",
                _ => "temporary",
            }
        };
        let (rname, description, hint) = if path.is_empty() || kind == Kind3::Extension {
            (if kind == Kind3::Extension && !path.is_empty() { name_of_extension(Path::new(path)) } else { name.trim_start_matches("skill:").to_string() }, None, None)
        } else {
            describe(kind, Path::new(path))
        };
        let description = description.or_else(|| c["description"].as_str().map(String::from));
        list.push(json!({
            "kind": kind.label(),
            "name": rname,
            "description": if kind == Kind3::Extension { Value::Null } else { json!(description) },
            "argumentHint": hint,
            "path": path,
            "scope": scope,
            "origin": "live",
            "package": info["baseDir"].as_str().filter(|_| scope == "package").map(|b| json!({"source": b, "scope": info["scope"]})),
            "enabled": true,
            "loads": true,
            "skipped": null,
            "toggle": null,
            "commands": if kind == Kind3::Extension { json!([name]) } else { json!([]) },
            "live": true,
        }));
    }
}

#[derive(Deserialize)]
struct ResourcesQuery {
    #[serde(default)]
    cwd: Option<String>,
}

async fn resources(State(app): State<Arc<AppState>>, Query(q): Query<ResourcesQuery>) -> crate::AppResult<Json<Value>> {
    let cwd = match q.cwd.as_deref().filter(|c| !c.is_empty()) {
        None => None,
        Some(c) => {
            let p = std::fs::canonicalize(c).map_err(|_| crate::err(axum::http::StatusCode::BAD_REQUEST, format!("folder not found: {c}")))?;
            Some((c.to_string(), p))
        }
    };
    let global = read_json(&app.agent_dir.join("settings.json"));
    let project = cwd.as_ref().map(|(_, p)| read_json(&p.join(".pi/settings.json"))).unwrap_or_else(|| json!({}));
    let (entries, _, _) = read_trust(&app.agent_dir);
    let (default, _) = default_trust(&global);
    let trust = cwd.as_ref().map(|(_, p)| trust_for(&entries, &default, p, &app.home));
    let trusted = trust.as_ref().is_none_or(|t| t["trusted"] == true);

    // `pi list` knows where packages are installed.
    let list_cwd = cwd.as_ref().map(|(_, p)| p.clone()).unwrap_or_else(|| app.home.clone());
    let action = crate::pi_cli::Action::List { cwd: None };
    let (listed, packages_error) = match crate::pi_cli::run_quick(&app.pi_bin, &action, &list_cwd).await {
        Ok(v) if v["code"] == 0 => (Some(parse_pi_list(v["stdout"].as_str().unwrap_or(""))), None),
        Ok(v) => (None, Some(format!("pi list exited with {}: {}", v["code"], v["stderr"].as_str().unwrap_or("").trim()))),
        Err(e) => (None, Some(e)),
    };
    let project_pi = cwd.as_ref().map(|(_, p)| p.join(".pi"));
    let packages = packages_from_settings(&global, &project, listed.as_deref(), &app.agent_dir, project_pi.as_deref(), &app.home);

    let (agent_dir, home) = (app.agent_dir.clone(), app.home.clone());
    let cwd_path = cwd.as_ref().map(|(_, p)| p.clone());
    let (g2, p2, pk2) = (global.clone(), project.clone(), packages.clone());
    let mut list = tokio::task::spawn_blocking(move || {
        scan(&Scan { agent_dir: &agent_dir, home: &home, cwd: cwd_path.as_deref(), trusted, global: &g2, project: &p2, packages: &pk2 })
    })
    .await
    .unwrap_or_default();

    // A chat already open in this project: what its pi really loaded.
    let mut live_info = Value::Null;
    let mut live_error = Value::Null;
    if let Some((raw, canon)) = &cwd {
        let live = app
            .live
            .lock()
            .unwrap()
            .values()
            .find(|l| l.kind == Kind::Chat && !l.exited.load(Ordering::Relaxed) && (l.cwd == *raw || Path::new(&l.cwd) == canon.as_path()))
            .cloned();
        if let Some(live) = live {
            match tokio::time::timeout(Duration::from_secs(5), crate::rpc_internal(&live, json!({"type": "get_commands"}))).await {
                Ok(Ok(v)) if v["success"] != false => {
                    let cmds = v.pointer("/data/commands").and_then(Value::as_array).cloned().unwrap_or_default();
                    merge_live(&mut list, &cmds);
                    live_info = json!({"key": live.key, "file": live.session_file(), "commands": cmds.iter().filter(|c| !c["name"].as_str().unwrap_or("").starts_with("pp-")).count()});
                }
                Ok(Ok(v)) => live_error = json!(v["error"].as_str().unwrap_or("get_commands failed")),
                Ok(Err((_, e))) => live_error = json!(e),
                Err(_) => live_error = json!("the chat's pi didn't answer"),
            }
        }
    }

    let pick = |v: &Value| json!({"extensions": v.get("extensions"), "skills": v.get("skills"), "prompts": v.get("prompts"), "packages": v.get("packages")});
    Ok(Json(json!({
        "cwd": cwd.as_ref().map(|(_, p)| p),
        "agentDir": app.agent_dir,
        "home": app.home,
        "trust": trust,
        "defaultTrust": default,
        "builtins": BUILTINS,
        "resources": list,
        "packages": packages.iter().map(|p| json!({"source": p.source, "scope": p.scope, "installedPath": p.installed, "filtered": p.filter.is_some()})).collect::<Vec<_>>(),
        "packagesError": packages_error,
        "settings": {"global": pick(&global), "project": if cwd.is_some() { pick(&project) } else { Value::Null }},
        "live": live_info,
        "liveError": live_error,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "pocketpi-resources-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(d).unwrap()
    }

    fn write(p: &Path, s: &str) {
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }

    fn find<'a>(list: &'a [Value], kind: &str, name: &str) -> &'a Value {
        list.iter().find(|r| r["kind"] == kind && r["name"] == name).unwrap_or_else(|| panic!("no {kind} {name} in {list:#?}"))
    }

    #[test]
    fn globs() {
        assert!(glob_match("*.ts", "a.ts"));
        assert!(!glob_match("*.ts", "x/a.ts"));
        assert!(glob_match("**/*.ts", "x/y/a.ts"));
        assert!(glob_match("**/*.ts", "a.ts"));
        assert!(glob_match("skills/?ev*", "skills/review"));
        assert!(!glob_match("skills/a", "skills/ab"));
    }

    #[test]
    fn overrides_follow_pi() {
        let base = Path::new("/agent");
        let f = Path::new("/agent/extensions/foo.ts");
        let e = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(enabled_by_overrides(f, &e(&[]), base));
        assert!(!enabled_by_overrides(f, &e(&["-extensions/foo.ts"]), base));
        assert!(!enabled_by_overrides(f, &e(&["-/agent/extensions/foo.ts"]), base));
        assert!(!enabled_by_overrides(f, &e(&["!foo.ts"]), base));
        assert!(enabled_by_overrides(f, &e(&["!*.ts", "+extensions/foo.ts"]), base));
        // A skill is matched by its folder too.
        let s = Path::new("/agent/skills/review/SKILL.md");
        assert!(!enabled_by_overrides(s, &e(&["-skills/review"]), base));
        assert!(!enabled_by_overrides(s, &e(&["!review"]), base));
        // Global: - beats + whatever the order; a !glob is undone by +.
        assert!(!builtin_global_enabled("mcp", &e(&["-builtin:mcp"])));
        assert!(!builtin_global_enabled("mcp", &e(&["+builtin:mcp", "-builtin:mcp"])));
        assert!(!builtin_global_enabled("mcp", &e(&["-builtin:mcp", "+builtin:mcp"])));
        assert!(!builtin_global_enabled("mcp", &e(&["!builtin:*"])));
        assert!(builtin_global_enabled("mcp", &e(&["!builtin:*", "+builtin:mcp"])));
        assert!(builtin_global_enabled("codemode", &e(&["-builtin:mcp"])));
        // Project: the last entry naming it wins.
        assert_eq!(builtin_project_override("mcp", &e(&["-builtin:mcp"])), Some(false));
        assert_eq!(builtin_project_override("mcp", &e(&["-builtin:mcp", "+builtin:mcp"])), Some(true));
        assert_eq!(builtin_project_override("mcp", &e(&["+builtin:mcp", "!builtin:*"])), Some(false));
        assert_eq!(builtin_project_override("codemode", &e(&["-builtin:mcp"])), None);
    }

    #[test]
    fn frontmatter_fields() {
        let (fm, body) = frontmatter("---\nname: review\ndescription: \"Review the diff\"\nargument-hint: '[focus]'\nmetadata:\n  a: b\n---\n\nBody line\n");
        assert_eq!(fm["name"], "review");
        assert_eq!(fm["description"], "Review the diff");
        assert_eq!(fm["argument-hint"], "[focus]");
        assert!(!fm.contains_key("a"));
        assert_eq!(body.trim(), "Body line");
        let (fm, _) = frontmatter("---\ndescription: >\n  folded\n  text\nname: x\n---\n");
        assert_eq!(fm["description"], "folded text");
        assert_eq!(fm["name"], "x");
        let (fm, body) = frontmatter("no front matter");
        assert!(fm.is_empty());
        assert_eq!(body, "no front matter");
    }

    #[test]
    fn trust_decisions_and_protected_resources() {
        let d = scratch();
        let home = d.join("home");
        let proj = home.join("code/proj");
        std::fs::create_dir_all(&proj).unwrap();
        let entries: Map<String, Value> = serde_json::from_value(json!({
            home.join("code").to_string_lossy(): true,
            proj.join("sub").to_string_lossy(): false,
            "/elsewhere": null,
        }))
        .unwrap();
        // Inherited from the parent.
        let t = trust_for(&entries, "ask", &proj, &home);
        assert_eq!(t["decision"], true);
        assert_eq!(t["from"], home.join("code").to_string_lossy().as_ref());
        assert_eq!(t["explicit"], false);
        assert_eq!(t["trusted"], true);
        assert_eq!(t["needsTrust"], false);
        // No decision: the default rules; "ask" can't ask over RPC.
        let other = home.join("other");
        std::fs::create_dir_all(other.join(".pi/skills")).unwrap();
        let t = trust_for(&entries, "ask", &other, &home);
        assert_eq!(t["decision"], Value::Null);
        assert_eq!(t["trusted"], false);
        assert_eq!(t["needsTrust"], true);
        assert_eq!(t["protected"], json!([".pi/skills"]));
        assert_eq!(trust_for(&entries, "always", &other, &home)["trusted"], true);
        // ~/.agents/skills is the user's own and doesn't count.
        std::fs::create_dir_all(home.join(".agents/skills")).unwrap();
        assert_eq!(trust_for(&entries, "ask", &proj, &home)["needsTrust"], false);
        std::fs::create_dir_all(home.join("code/.agents/skills")).unwrap();
        assert_eq!(trust_for(&entries, "ask", &proj, &home)["needsTrust"], true);
        assert_eq!(default_trust(&json!({"defaultProjectTrust": "never"})), ("never".into(), true));
        assert_eq!(default_trust(&json!({"defaultProjectTrust": "bogus"})), ("ask".into(), false));
        // A broken trust.json is reported, not guessed at.
        std::fs::create_dir_all(d.join("agent")).unwrap();
        write(&d.join("agent/trust.json"), "[1]");
        assert!(read_trust(&d.join("agent")).2.is_some());
        write(&d.join("agent/trust.json"), "{\"/a\": true}\n");
        assert_eq!(read_trust(&d.join("agent")).0["/a"], true);
    }

    #[test]
    fn parses_pi_list() {
        let text = "User packages:\n  /tmp/pkg\n    /tmp/pkg\n  npm:foo@1.0.0\n\nProject packages:\n  ../local (filtered)\n    /p/local\n";
        let l = parse_pi_list(text);
        assert_eq!(
            l,
            vec![
                ("user".into(), "/tmp/pkg".into(), Some(PathBuf::from("/tmp/pkg"))),
                ("user".into(), "npm:foo@1.0.0".into(), None),
                ("project".into(), "../local".into(), Some(PathBuf::from("/p/local"))),
            ]
        );
        assert!(parse_pi_list("No packages installed.\n").is_empty());
        assert_eq!(parse_pi_list("\u{1b}[1mUser packages:\u{1b}[22m\n  x\n").len(), 1);
    }

    /// A scratch HOME with one of everything.
    fn seeded() -> (PathBuf, PathBuf, PathBuf, PathBuf) {
        let d = scratch();
        let home = d.join("home");
        let agent = home.join(".pi/agent");
        let proj = home.join("proj");
        std::fs::create_dir_all(proj.join(".git")).unwrap();
        write(&agent.join("extensions/hello.ts"), "export default function () {}\n");
        write(&agent.join("extensions/multi/index.ts"), "export default function () {}\n");
        write(&agent.join("extensions/off.ts"), "export default function () {}\n");
        write(&agent.join("skills/review/SKILL.md"), "---\nname: review\ndescription: Review the diff\n---\nDo it.\n");
        write(&agent.join("skills/loose.md"), "---\ndescription: A loose skill\n---\n");
        write(&agent.join("prompts/fix.md"), "---\ndescription: Fix tests\nargument-hint: \"<file>\"\n---\nFix $1\n");
        write(&agent.join("prompts/plain.md"), "\nFirst line is the description\n");
        write(&home.join(".agents/skills/shared/SKILL.md"), "---\nname: shared\ndescription: From ~/.agents\n---\n");
        write(&proj.join(".pi/extensions/projext.ts"), "export default function () {}\n");
        write(&proj.join(".pi/prompts/deploy.md"), "---\ndescription: Deploy\n---\n");
        write(&proj.join(".agents/skills/local/SKILL.md"), "---\nname: local\ndescription: Project skill\n---\n");
        let pkg = home.join("pkg");
        write(&pkg.join("package.json"), "{\"name\":\"mypkg\",\"pi\":{\"skills\":[\"./res/skills\"],\"prompts\":[\"./res/*.md\"]}}");
        write(&pkg.join("res/skills/pkgskill/SKILL.md"), "---\nname: pkgskill\ndescription: From a package\n---\n");
        write(&pkg.join("res/hello.md"), "---\ndescription: Package prompt\n---\n");
        write(&pkg.join("extensions/ignored.ts"), "// not in the manifest\n");
        let extra = home.join("extra");
        write(&extra.join("x.ts"), "export default function () {}\n");
        (home, agent, proj, pkg)
    }

    #[test]
    fn scans_like_pi() {
        let (home, agent, proj, pkg) = seeded();
        let global = json!({
            "extensions": ["../../extra", "-extensions/off.ts", "-builtin:mcp"],
            "packages": [pkg.to_string_lossy()],
        });
        let project = json!({"prompts": ["!deploy.md"]});
        let packages = packages_from_settings(&global, &project, None, &agent, Some(&proj.join(".pi")), &home);
        assert_eq!(packages.len(), 1);
        assert_eq!(packages[0].installed.as_deref(), Some(pkg.as_path()));
        let run = |trusted: bool| {
            scan(&Scan { agent_dir: &agent, home: &home, cwd: Some(&proj), trusted, global: &global, project: &project, packages: &packages })
        };
        let list = run(false);

        let e = find(&list, "extension", "hello");
        assert_eq!((e["scope"].as_str(), e["origin"].as_str(), e["loads"].as_bool()), (Some("global"), Some("auto"), Some(true)));
        assert_eq!(e["toggle"], json!({"key": "extensions", "scope": "global", "entry": "extensions/hello.ts"}));
        assert_eq!(find(&list, "extension", "multi")["path"], agent.join("extensions/multi/index.ts").to_string_lossy().as_ref());
        assert_eq!(find(&list, "extension", "off")["enabled"], false);
        assert_eq!(find(&list, "extension", "x")["origin"], "settings");

        let s = find(&list, "skill", "review");
        assert_eq!(s["description"], "Review the diff");
        assert_eq!(s["toggle"]["entry"], "skills/review/SKILL.md");
        assert_eq!(find(&list, "skill", "loose")["description"], "A loose skill");
        assert_eq!(find(&list, "skill", "shared")["scope"], "global");

        let p = find(&list, "prompt", "fix");
        assert_eq!((p["description"].as_str(), p["argumentHint"].as_str()), (Some("Fix tests"), Some("<file>")));
        assert_eq!(find(&list, "prompt", "plain")["description"], "First line is the description");

        // Package resources come from its manifest only.
        let ps = find(&list, "skill", "pkgskill");
        assert_eq!(ps["scope"], "package");
        assert_eq!(ps["package"]["source"], pkg.to_string_lossy().as_ref());
        assert_eq!(find(&list, "prompt", "hello")["scope"], "package");
        assert!(!list.iter().any(|r| r["name"] == "ignored"));

        // The project's resources are listed but skipped while untrusted.
        let pe = find(&list, "extension", "projext");
        assert_eq!((pe["scope"].as_str(), pe["loads"].as_bool(), pe["skipped"].as_str()), (Some("project"), Some(false), Some("project not trusted")));
        assert_eq!(find(&list, "skill", "local")["scope"], "project");
        let d = find(&list, "prompt", "deploy");
        assert_eq!(d["enabled"], false);

        // Built-ins: mcp turned off by -builtin:mcp.
        let mcp = find(&list, "extension", "mcp");
        assert_eq!((mcp["scope"].as_str(), mcp["enabled"].as_bool()), (Some("builtin"), Some(false)));
        assert!(mcp["disabledBy"].as_str().unwrap().contains("-builtin:mcp"));
        assert_eq!(find(&list, "extension", "codemode")["enabled"], true);

        // Trusted: project resources load.
        let list = run(true);
        assert_eq!(find(&list, "extension", "projext")["loads"], true);
        assert_eq!(find(&list, "skill", "local")["loads"], true);
    }

    #[test]
    fn project_builtin_override_wins_when_trusted() {
        let (home, agent, proj, _) = seeded();
        let global = json!({"extensions": ["-builtin:codemode"]});
        let project = json!({"extensions": ["+builtin:codemode"]});
        let run = |trusted| scan(&Scan { agent_dir: &agent, home: &home, cwd: Some(&proj), trusted, global: &global, project: &project, packages: &[] });
        assert_eq!(find(&run(false), "extension", "codemode")["enabled"], false);
        let l = run(true);
        let c = find(&l, "extension", "codemode");
        assert_eq!((c["enabled"].as_bool(), c["toggle"]["scope"].as_str()), (Some(true), Some("project")));
    }

    #[test]
    fn merges_a_live_chats_commands() {
        let (home, agent, proj, _) = seeded();
        let mut list = scan(&Scan { agent_dir: &agent, home: &home, cwd: Some(&proj), trusted: true, global: &json!({}), project: &json!({}), packages: &[] });
        let hello = agent.join("extensions/hello.ts");
        let fix = agent.join("prompts/fix.md");
        merge_live(
            &mut list,
            &[
                json!({"name": "hi", "source": "extension", "sourceInfo": {"path": hello, "source": "auto", "scope": "user", "origin": "top-level"}}),
                json!({"name": "fix", "source": "prompt", "sourceInfo": {"path": fix, "source": "auto", "scope": "user", "origin": "top-level"}}),
                json!({"name": "pp-tools", "source": "extension", "sourceInfo": {"path": "/x/pocketpi-control.ts", "source": "cli", "scope": "temporary"}}),
                json!({"name": "wf", "source": "extension", "sourceInfo": {"path": "/x/workflows.ts", "source": "cli", "scope": "temporary", "origin": "top-level"}}),
            ],
        );
        let h = find(&list, "extension", "hello");
        assert_eq!((h["live"].as_bool(), h["commands"].clone()), (Some(true), json!(["hi"])));
        assert_eq!(find(&list, "prompt", "fix")["live"], true);
        let wf = find(&list, "extension", "workflows");
        assert_eq!((wf["scope"].as_str(), wf["origin"].as_str()), (Some("temporary"), Some("live")));
        assert!(!list.iter().any(|r| r["name"] == "pocketpi-control"));
    }
}
