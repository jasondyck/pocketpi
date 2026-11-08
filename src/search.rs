//! Full-text search across every chat (`GET /api/sessions/search`).
//!
//! pi's session files are the truth; this module keeps a **derived** SQLite
//! FTS5 index beside them and never writes to a session. Borrowed from
//! DeepSeek Harness (`packages/session-query/session-query-sqlite`): the index
//! is separate from the session store, files are reconciled by (mtime, size),
//! a search only parses the sessions that changed since the last one, and the
//! delete-the-database cost is a rebuild, not a loss.
//!
//! What is indexed (pi's session format):
//!
//! - `message` entries with role `user`, `assistant` and `toolResult`
//!   (text content blocks only; thinking, tool-call arguments, images and the
//!   `system` prompt are left out). A tool result also records its tool name,
//!   so a hit can say `bash` or `read`.
//! - `compactionSummary` and `branchSummary` messages (`summary`), as `summary`.
//!
//! Each entry's text is capped at [`MAX_TEXT`] characters: the index is for
//! finding the message, not for serving it, and a single giant tool result
//! would otherwise be stored twice.
//!
//! Queries are AND of prefix terms (`foo bar` → `"foo"* AND "bar"*`), with an
//! OR fallback when the AND finds nothing. Ranking is FTS5's `bm25`. Rows are
//! grouped by chat for the phone UI; a small aggregate query returns each
//! chat's total hit count (FTS5's `bm25`/`snippet` can't share a statement with
//! a window function). Callers pass the chats the client may see (archived and
//! workflow-stage sessions are gone before paging, so `offset`/`limit` count
//! real results). At most [`MAX_ROWS`] matching messages are grouped per call.

use crate::AppState;
use axum::{
    Json,
    extract::{Query, State},
};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Instant, UNIX_EPOCH},
};

/// Characters of one entry's text the index keeps.
const MAX_TEXT: usize = 40_000;
/// Most match terms taken from one query.
const MAX_TERMS: usize = 12;
/// Most rows read before grouping, however large `limit` is.
const MAX_ROWS: usize = 2_000;

/// The derived index: one SQLite file, opened on first use.
pub struct Index {
    path: PathBuf,
    db: Mutex<Option<Connection>>,
}

#[derive(Default, Clone, Copy, Debug, Serialize)]
pub struct Fresh {
    /// Session files under the roots.
    pub files: usize,
    /// Entries in the index.
    pub entries: usize,
    /// Files parsed again for this search (new or changed).
    pub reindexed: usize,
    /// Files dropped because they vanished.
    pub removed: usize,
}

#[derive(Default, Debug)]
pub struct Req {
    pub q: String,
    /// `user`, `assistant`, `tool`, `summary`; empty means all.
    pub roles: Vec<String>,
    pub limit: usize,
    pub offset: usize,
    /// Hits kept per chat.
    pub hits: usize,
}

#[derive(Serialize, Debug)]
pub struct Hit {
    pub entry: String,
    pub role: String,
    pub tool: String,
    pub ts: i64,
    /// Match markers are U+0001 (open) and U+0002 (close); clients escape the
    /// text and turn the markers into `<mark>`.
    pub snippet: String,
}

#[derive(Serialize, Debug)]
pub struct Group {
    pub path: String,
    pub session: String,
    pub count: u64,
    pub hits: Vec<Hit>,
}

#[derive(Serialize, Debug)]
pub struct Found {
    pub total: u64,
    pub results: Vec<Group>,
    pub indexed: Fresh,
}

impl Index {
    pub fn new(path: PathBuf) -> Self {
        Self { path, db: Mutex::new(None) }
    }

    fn with_db<T>(&self, f: impl FnOnce(&mut Connection) -> rusqlite::Result<T>) -> Result<T, String> {
        // A panic inside one query must not brick the index for the process.
        let mut guard = self.db.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            if let Some(dir) = self.path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
            }
            let conn = Connection::open(&self.path).map_err(|e| e.to_string())?;
            init(&conn).map_err(|e| e.to_string())?;
            *guard = Some(conn);
        }
        f(guard.as_mut().unwrap()).map_err(|e| e.to_string())
    }

    /// Index every session file under `roots` that changed, and drop the ones
    /// that went away. Cheap when nothing changed: it lists directories and
    /// compares (mtime, size) with the `files` table.
    pub fn sync(&self, roots: &[PathBuf]) -> Result<Fresh, String> {
        let listed = list_files(roots);
        self.with_db(|db| {
            let mut known: HashMap<String, (i64, i64)> = HashMap::new();
            {
                let mut st = db.prepare("SELECT path, mtime, size FROM files")?;
                let mut rows = st.query([])?;
                while let Some(r) = rows.next()? {
                    known.insert(r.get(0)?, (r.get(1)?, r.get(2)?));
                }
            }
            let mut out = Fresh { files: listed.len(), ..Default::default() };
            let mut seen: HashSet<String> = HashSet::new();
            let mut todo: Vec<(PathBuf, String, u64, u64)> = Vec::new();
            for path in listed {
                let s = path.to_string_lossy().to_string();
                if !seen.insert(s.clone()) {
                    continue;
                }
                let Ok(md) = std::fs::metadata(&path) else { continue };
                let (mtime, size) = mtime_size(&md);
                if known.get(&s) == Some(&(mtime as i64, size as i64)) {
                    continue;
                }
                todo.push((path, s, mtime, size));
            }

            let tx = db.transaction()?;
            let mut removed = 0;
            for path in known.keys().filter(|p| !seen.contains(*p)) {
                tx.execute("DELETE FROM entries WHERE path = ?1", params![path])?;
                tx.execute("DELETE FROM files WHERE path = ?1", params![path])?;
                removed += 1;
            }

            // Parsing is the expensive half and does not need the connection:
            // a first index can be hundreds of megabytes, so read on a few
            // threads like `usage::scan` does.
            let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).clamp(1, 8);
            let chunk = todo.len().div_ceil(threads).max(1);
            let parsed: Vec<Parsed> = std::thread::scope(|s| {
                let handles: Vec<_> = todo
                    .chunks(chunk)
                    .map(|part| s.spawn(move || part.iter().map(|(p, s, m, z)| parse(p, s.clone(), *m, *z)).collect::<Vec<_>>()))
                    .collect();
                handles.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
            });

            for p in parsed {
                // A file we couldn't read keeps whatever it had indexed.
                if matches!(p.read, Read::Failed) {
                    continue;
                }
                tx.execute("DELETE FROM entries WHERE path = ?1", params![p.path])?;
                match p.read {
                    // Not a pi session (yet): remember it so it isn't read again
                    // until it changes; `upsert` keeps a renamed/rewritten file sane.
                    Read::NotSession => {
                        tx.execute(
                            "INSERT INTO files (path, mtime, size) VALUES (?1, ?2, ?3)
                             ON CONFLICT(path) DO UPDATE SET mtime = ?2, size = ?3",
                            params![p.path, p.mtime as i64, p.size as i64],
                        )?;
                    }
                    Read::Session(session, rows) => {
                        let mut st = tx.prepare_cached(
                            "INSERT INTO entries (path, session, entry, role, tool, ts, text) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                        )?;
                        for r in &rows {
                            st.execute(params![p.path, session, r.entry, r.role, r.tool, r.ts, r.text])?;
                        }
                        tx.execute(
                            "INSERT INTO files (path, mtime, size) VALUES (?1, ?2, ?3)
                             ON CONFLICT(path) DO UPDATE SET mtime = ?2, size = ?3",
                            params![p.path, p.mtime as i64, p.size as i64],
                        )?;
                    }
                    Read::Failed => unreachable!("handled above"),
                }
            }
            tx.commit()?;

            let entries = db.query_row("SELECT count(*) FROM entries", [], |r| r.get::<_, i64>(0))?;
            out.entries = entries as usize;
            out.reindexed = todo.len();
            out.removed = removed;
            Ok(out)
        })
    }

    /// Sync, then search. `AND` of prefix terms first, `OR` when that is empty.
    ///
    /// `visible` is the set of chats the caller may show (the chat list minus
    /// archived and workflow-stage sessions); hidden chats are dropped *before*
    /// `offset`/`limit`, so pages fill and `count`/`total` agree with what the
    /// client renders. None means "everything in the index".
    pub fn search(&self, roots: &[PathBuf], req: &Req, visible: Option<&HashSet<String>>) -> Result<Found, String> {
        let indexed = self.sync(roots)?;
        let empty = |indexed| Found { total: 0, results: Vec::new(), indexed };
        let Some(and) = match_terms(&req.q, " AND ") else {
            return Ok(empty(indexed));
        };
        self.with_db(|db| {
            let asked = !req.roles.is_empty();
            let roles: Vec<&str> = req
                .roles
                .iter()
                .map(String::as_str)
                .filter(|r| matches!(*r, "user" | "assistant" | "tool" | "summary"))
                .collect();
            // `role=tools` is a typo, not "every role": answer nothing.
            if asked && roles.is_empty() {
                return Ok(empty(indexed));
            }
            let limit = req.limit.clamp(1, 50);
            let hits = req.hits.clamp(1, 20);
            let shown = |path: &str| visible.is_none_or(|v| v.contains(path));
            let mut expr = and;
            let mut per_chat = counts(db, &expr, &roles)?;
            if per_chat.is_empty()
                && let Some(or) = match_terms(&req.q, " OR ")
                && or != expr
            {
                expr = or;
                per_chat = counts(db, &expr, &roles)?;
            }
            let total: u64 = per_chat.iter().filter(|(p, _)| shown(p)).map(|(_, n)| *n).sum();
            if total == 0 {
                return Ok(empty(indexed));
            }
            let rows = rows(db, &expr, &roles, MAX_ROWS)?;
            // Group by chat in rank order (a chat's first row is its best).
            let mut order: Vec<String> = Vec::new();
            let mut groups: HashMap<String, Group> = HashMap::new();
            for r in rows {
                let g = groups.entry(r.path.clone()).or_insert_with(|| {
                    order.push(r.path.clone());
                    Group {
                        path: r.path.clone(),
                        session: r.session.clone(),
                        count: per_chat.get(&r.path).copied().unwrap_or(0),
                        hits: Vec::new(),
                    }
                });
                if g.hits.len() < hits {
                    g.hits.push(Hit { entry: r.entry, role: r.role, tool: r.tool, ts: r.ts, snippet: r.snippet });
                }
            }
            // Hidden chats never take a page slot, and offset counts shown chats.
            if visible.is_some() {
                order.retain(|p| shown(p));
            }
            let skip = req.offset.min(order.len());
            let results = order.into_iter().skip(skip).take(limit).filter_map(|p| groups.remove(&p)).collect();
            Ok(Found { total, results, indexed })
        })
    }
}

struct Parsed {
    path: String,
    mtime: u64,
    size: u64,
    read: Read,
}

/// What one session file turned out to be.
enum Read {
    Session(String, Vec<Row>),
    /// Not a pi session (yet): remembered so it isn't read again until it changes.
    NotSession,
    /// Could not be read: leave the file's entries and (mtime, size) alone and
    /// retry next time, instead of silently emptying the chat from the index.
    Failed,
}

struct Row {
    entry: String,
    role: &'static str,
    tool: String,
    ts: i64,
    text: String,
}

struct FoundRow {
    path: String,
    session: String,
    entry: String,
    role: String,
    tool: String,
    ts: i64,
    snippet: String,
}

fn init(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA busy_timeout = 5000;
         PRAGMA synchronous = NORMAL;
         PRAGMA temp_store = MEMORY;
         CREATE TABLE IF NOT EXISTS files (
             path  TEXT PRIMARY KEY,
             mtime INTEGER NOT NULL,
             size  INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS entries (
             id      INTEGER PRIMARY KEY,
             path    TEXT NOT NULL,
             session TEXT NOT NULL,
             entry   TEXT NOT NULL,
             role    TEXT NOT NULL,
             tool    TEXT NOT NULL,
             ts      INTEGER NOT NULL,
             text    TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS entries_path ON entries (path);
         CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(
             text,
             content = 'entries',
             content_rowid = 'id',
             tokenize = 'unicode61 remove_diacritics 2'
         );
         CREATE TRIGGER IF NOT EXISTS entries_ai AFTER INSERT ON entries BEGIN
             INSERT INTO entries_fts (rowid, text) VALUES (new.id, new.text);
         END;
         CREATE TRIGGER IF NOT EXISTS entries_ad AFTER DELETE ON entries BEGIN
             INSERT INTO entries_fts (entries_fts, rowid, text) VALUES ('delete', old.id, old.text);
         END;",
    )
}

/// Hits per chat. Separate from `rows` because FTS5's auxiliary functions
/// (`bm25`, `snippet`) can't run in an aggregate query, and a window function
/// in the same statement would forbid them too.
fn counts(conn: &Connection, expr: &str, roles: &[&str]) -> rusqlite::Result<HashMap<String, u64>> {
    let clause = role_clause(roles);
    let sql = format!(
        "SELECT e.path, count(*) FROM entries_fts JOIN entries e ON e.id = entries_fts.rowid
         WHERE entries_fts MATCH ?1{clause} GROUP BY e.path"
    );
    let mut args: Vec<&dyn rusqlite::ToSql> = vec![&expr];
    for r in roles {
        args.push(r);
    }
    let mut st = conn.prepare(&sql)?;
    let mut rows = st.query(args.as_slice())?;
    let mut out = HashMap::new();
    while let Some(r) = rows.next()? {
        out.insert(r.get(0)?, r.get::<_, i64>(1)? as u64);
    }
    Ok(out)
}

fn rows(conn: &Connection, expr: &str, roles: &[&str], cap: usize) -> rusqlite::Result<Vec<FoundRow>> {
    let clause = role_clause(roles);
    let sql = format!(
        "SELECT e.path, e.session, e.entry, e.role, e.tool, e.ts,
                snippet(entries_fts, 0, char(1), char(2), '…', 14)
         FROM entries_fts JOIN entries e ON e.id = entries_fts.rowid
         WHERE entries_fts MATCH ?1{clause}
         ORDER BY bm25(entries_fts)
         LIMIT ?{}",
        roles.len() + 2
    );
    let mut args: Vec<&dyn rusqlite::ToSql> = vec![&expr];
    for r in roles {
        args.push(r);
    }
    let cap = cap as i64;
    args.push(&cap);
    let mut st = conn.prepare(&sql)?;
    let iter = st.query_map(args.as_slice(), |r| {
        Ok(FoundRow {
            path: r.get(0)?,
            session: r.get(1)?,
            entry: r.get(2)?,
            role: r.get(3)?,
            tool: r.get(4)?,
            ts: r.get(5)?,
            snippet: r.get(6)?,
        })
    })?;
    iter.collect()
}

fn role_clause(roles: &[&str]) -> String {
    if roles.is_empty() {
        return String::new();
    }
    let marks: Vec<String> = (0..roles.len()).map(|i| format!("?{}", i + 2)).collect();
    format!(" AND e.role IN ({})", marks.join(", "))
}

/// `foo bar` → `"foo"* AND "bar"*`; None when nothing usable is left.
fn match_terms(q: &str, joiner: &str) -> Option<String> {
    const STRIP: &str = "\"'`()[]{}:,*^~-+&|!?<>=/\\";
    let terms: Vec<String> = q
        .split_whitespace()
        .map(|t| t.trim_matches(|c: char| c.is_whitespace() || STRIP.contains(c)))
        .filter(|t| !t.is_empty() && t.chars().any(|c| c.is_alphanumeric()))
        .take(MAX_TERMS)
        .map(|t| format!("\"{}\"*", t.replace('"', "\"\"")))
        .collect();
    (!terms.is_empty()).then(|| terms.join(joiner))
}

fn mtime_size(md: &std::fs::Metadata) -> (u64, u64) {
    let mtime = md
        .modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    (mtime, md.len())
}

/// pi's layout: one folder per working directory, or flat when a custom
/// session dir is configured. Same walk as `sessions::scan`.
fn list_files(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for root in roots {
        for entry in std::fs::read_dir(root).into_iter().flatten().flatten() {
            match entry.file_type() {
                Ok(t) if t.is_dir() => files.extend(std::fs::read_dir(entry.path()).into_iter().flatten().flatten()),
                Ok(t) if t.is_file() => files.push(entry),
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    for f in files {
        let path = f.path();
        if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
    out
}

/// Reads the searchable entries of one session file; None if it isn't a pi
/// session. Lines that don't parse (a torn tail while pi writes) are skipped;
/// the file is read again once its size changes.
fn parse(path: &Path, s: String, mtime: u64, size: u64) -> Parsed {
    let read = read_rows(path);
    Parsed { path: s, mtime, size, read }
}

fn read_rows(path: &Path) -> Read {
    let Ok(file) = std::fs::File::open(path) else {
        return Read::Failed;
    };
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut session = String::new();
    let mut rows = Vec::new();
    let mut first = true;
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => return Read::Failed,
        }
        let l = line.trim_end();
        if first {
            first = false;
            let Ok(v) = serde_json::from_str::<Value>(l) else {
                // A file pi is still writing: from the length we cached, a
                // half line is not a session header; read it again next time.
                return Read::NotSession;
            };
            if v["type"].as_str() != Some("session") {
                return Read::NotSession;
            }
            session = v["id"].as_str().unwrap_or_default().to_string();
            continue;
        }
        let msg = l.starts_with(r#"{"type":"message""#);
        if !msg {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(l) else { continue };
        let m = &v["message"];
        let role = m["role"].as_str().unwrap_or_default();
        let (role, text) = match role {
            // The system prompt is huge and identical everywhere.
            "user" => ("user", content_text(&m["content"])),
            "assistant" => ("assistant", content_text(&m["content"])),
            "toolResult" => ("tool", content_text(&m["content"])),
            "compactionSummary" | "branchSummary" => ("summary", m["summary"].as_str().unwrap_or_default().to_string()),
            _ => continue,
        };
        let text = clamp_text(&text, MAX_TEXT);
        if text.trim().is_empty() {
            continue;
        }
        rows.push(Row {
            entry: v["id"].as_str().unwrap_or_default().to_string(),
            role,
            tool: if role == "tool" { m["toolName"].as_str().unwrap_or_default().to_string() } else { String::new() },
            ts: ts_ms(&v["timestamp"]).or_else(|| m["timestamp"].as_i64()).unwrap_or(0),
            text,
        });
    }
    // A header-only file is a session being written; keeping the id is fine.
    Read::Session(session, rows)
}

fn content_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => {
            let mut out = String::new();
            for p in parts {
                // Text blocks only: thinking, images and tool calls are noise.
                if p["type"].as_str() == Some("text")
                    && let Some(t) = p["text"].as_str()
                {
                    if !out.is_empty() {
                        out.push('\n');
                    }
                    out.push_str(t);
                }
            }
            out
        }
        _ => String::new(),
    }
}

fn clamp_text(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let cut: String = s.chars().take(max).collect();
    format!("{cut}…")
}

fn ts_ms(v: &Value) -> Option<i64> {
    match v {
        Value::String(s) => chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis()),
        Value::Number(n) => n.as_f64().map(|f| f as i64),
        _ => None,
    }
}

// ------------------------------------------------------------------ HTTP

#[derive(Deserialize)]
struct SearchQuery {
    #[serde(default)]
    q: String,
    /// `user,assistant,tool,summary`; empty means all.
    #[serde(default)]
    role: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    offset: Option<usize>,
    #[serde(default)]
    hits: Option<usize>,
    /// `1` includes archived chats (they're left out otherwise).
    #[serde(default)]
    archived: Option<String>,
}

pub fn router() -> axum::Router<Arc<AppState>> {
    axum::Router::new().route("/api/sessions/search", axum::routing::get(route))
}

async fn route(State(app): State<Arc<AppState>>, Query(q): Query<SearchQuery>) -> Json<Value> {
    let started = Instant::now();
    let term = q.q.trim().to_string();
    if term.is_empty() {
        return Json(json!({ "q": "", "total": 0, "results": [], "indexed": json!(null) }));
    }
    let roles: Vec<String> = q
        .role
        .as_deref()
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    let req = Req {
        q: term.clone(),
        roles,
        limit: q.limit.unwrap_or(20),
        offset: q.offset.unwrap_or(0),
        hits: q.hits.unwrap_or(3),
    };
    // Which chats the client may see, first: session metadata (title, cwd,
    // recency) comes from the same cache the chat list uses, and archived
    // chats must not consume search page slots (see `Index::search`).
    let mut list = crate::scan_with_live(&app).await;
    let archived = crate::projects::load(&app.projects_path).archived;
    let include_archived = q.archived.as_deref().is_some_and(|v| v == "1" || v == "true");
    if !include_archived {
        list.retain(|s| !archived.contains(&s.path));
    }
    let visible: HashSet<String> = list.iter().map(|s| s.path.clone()).collect();
    let roots = [app.sessions_dir.clone(), app.chat_dir.clone()];
    let app2 = app.clone();
    let search = tokio::task::spawn_blocking(move || app2.search.search(&roots, &req, Some(&visible))).await;
    let found = match search {
        Ok(Ok(f)) => f,
        Ok(Err(e)) => return Json(json!({ "q": term, "error": e, "results": [], "total": 0 })),
        Err(_) => return Json(json!({ "q": term, "error": "search task failed", "results": [], "total": 0 })),
    };
    let by_path: HashMap<&str, &crate::sessions::SessionInfo> = list.iter().map(|s| (s.path.as_str(), s)).collect();

    let chat_dir = app.chat_dir.to_string_lossy().to_string();
    let mut results = Vec::new();
    for g in found.results {
        let meta = by_path.get(g.path.as_str());
        // A hit whose session file is gone (deleted between sync and now, or
        // archived) has no row to open: leave it out.
        let Some(meta) = meta else { continue };
        results.push(json!({
            "path": g.path,
            "id": g.session,
            "title": if meta.title.is_empty() { "Untitled" } else { meta.title.as_str() },
            "name": meta.name,
            "cwd": meta.cwd,
            "modified": meta.modified,
            "messages": meta.messages,
            "chat": meta.cwd == chat_dir,
            "live": meta.live,
            "streaming": meta.streaming,
            "count": g.count,
            "hits": g.hits,
        }));
    }
    Json(json!({
        "q": term,
        "total": found.total,
        "results": results,
        "took_ms": started.elapsed().as_millis() as u64,
        "indexed": found.indexed,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(id: &str, cwd: &str, lines: &[&str]) -> String {
        let mut s = format!(r#"{{"type":"session","version":3,"id":"{id}","cwd":"{cwd}"}}"#);
        s.push('\n');
        for l in lines {
            s.push_str(l);
            s.push('\n');
        }
        s
    }

    fn user(id: &str, text: &str) -> String {
        format!(
            r#"{{"type":"message","id":"{id}","message":{{"role":"user","content":[{{"type":"text","text":{}}}]}}}}"#,
            serde_json::to_string(text).unwrap()
        )
    }

    fn tool(id: &str, name: &str, text: &str) -> String {
        format!(
            r#"{{"type":"message","id":"{id}","message":{{"role":"toolResult","toolName":"{name}","content":[{{"type":"text","text":{}}}]}}}}"#,
            serde_json::to_string(text).unwrap()
        )
    }

    struct Fixture {
        dir: PathBuf,
        sessions: PathBuf,
        index: Index,
    }

    impl Fixture {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("pocketpi-search-{}-{tag}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            let sessions = dir.join("sessions");
            std::fs::create_dir_all(&sessions).unwrap();
            let index = Index::new(dir.join("search.sqlite"));
            Self { dir, sessions, index }
        }
        fn write(&self, name: &str, body: &str) -> PathBuf {
            let p = self.sessions.join(name);
            std::fs::write(&p, body).unwrap();
            p
        }
        fn find(&self, q: &str) -> Found {
            let req = Req { q: q.to_string(), limit: 20, offset: 0, hits: 3, ..Default::default() };
            self.index.search(std::slice::from_ref(&self.sessions), &req, None).unwrap()
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn finds_text_in_roles_and_marks_the_match() {
        let f = Fixture::new("roles");
        f.write("a.jsonl", &session("a", "/p", &[&user("u1", "fix the flaky workflow sensor"), &tool("t1", "bash", "cargo test failed: 3 tests")]));
        let found = f.find("workflow");
        assert_eq!(found.total, 1);
        assert_eq!(found.results.len(), 1);
        let g = &found.results[0];
        assert_eq!((g.path.as_str().ends_with("a.jsonl"), g.session.as_str(), g.count), (true, "a", 1));
        // Markers, not HTML: the client escapes then highlights.
        assert!(g.hits[0].snippet.contains('\u{1}') && g.hits[0].snippet.contains('\u{2}'), "{}", g.hits[0].snippet);
        assert_eq!(g.hits[0].role, "user");

        let tool_hit = f.find("Cargo"); // case-insensitive, prefix-free
        assert_eq!(tool_hit.results[0].hits[0].role, "tool");
        assert_eq!(tool_hit.results[0].hits[0].tool, "bash");

        // Prefix terms: "workfl" and "sens" both hit.
        assert_eq!(f.find("workfl sens").total, 1);
        // Role filter.
        let req = Req { q: "cargo".into(), roles: vec!["user".into()], limit: 20, hits: 3, ..Default::default() };
        assert_eq!(f.index.search(std::slice::from_ref(&f.sessions), &req, None).unwrap().total, 0);
    }

    #[test]
    fn reindexes_changed_files_and_drops_deleted_ones() {
        let f = Fixture::new("changed");
        let p = f.write("a.jsonl", &session("a", "/p", &[&user("u1", "first question about widgets")]));
        assert_eq!(f.find("widgets").total, 1);
        // Appending changes size: the new entry is searchable.
        let mut body = std::fs::read_to_string(&p).unwrap();
        body.push_str(&user("u2", "second question about gadgets"));
        body.push('\n');
        std::fs::write(&p, body).unwrap();
        let found = f.find("gadgets");
        assert_eq!(found.total, 1);
        assert_eq!(found.results[0].count, 1);
        assert_eq!(found.indexed.reindexed, 1);
        // A file that isn't a session is remembered and not re-read, and
        // never shows up in results.
        f.write("notes.jsonl", "{\"hello\":1}\n");
        let found = f.find("hello");
        assert_eq!((found.total, found.indexed.reindexed), (0, 1)); // read once
        assert_eq!(f.find("hello").indexed.reindexed, 0); // then cached
        // Deleting the session drops its rows.
        std::fs::remove_file(&p).unwrap();
        let found = f.find("widgets");
        assert_eq!((found.total, found.indexed.removed), (0, 1));
    }

    #[test]
    fn groups_by_chat_and_caps_hits_per_chat() {
        let f = Fixture::new("groups");
        let a = [user("u1", "koala one"), user("u2", "koala two"), tool("t1", "bash", "koala three")];
        f.write("a.jsonl", &session("a", "/p", &a.iter().map(String::as_str).collect::<Vec<_>>()));
        f.write("b.jsonl", &session("b", "/q", &[&user("u3", "a single koala")]));
        let found = f.find("koala");
        assert_eq!((found.total, found.results.len()), (4, 2));
        let ga = found.results.iter().find(|g| g.path.ends_with("a.jsonl")).unwrap();
        assert_eq!((ga.count, ga.hits.len()), (3, 3));
        let req = Req { q: "koala".into(), limit: 20, hits: 1, ..Default::default() };
        let found = f.index.search(std::slice::from_ref(&f.sessions), &req, None).unwrap();
        assert!(found.results.iter().all(|g| g.hits.len() == 1 && g.count >= 1));
        // Offset pages whole chats, not hits.
        let req = Req { q: "koala".into(), limit: 20, offset: 1, hits: 2, ..Default::default() };
        assert_eq!(f.index.search(std::slice::from_ref(&f.sessions), &req, None).unwrap().results.len(), 1);
    }

    #[test]
    fn hidden_chats_do_not_take_page_slots() {
        let f = Fixture::new("visible");
        f.write("a.jsonl", &session("a", "/p", &[&user("u1", "koala in a")]));
        let b = f.write("b.jsonl", &session("b", "/q", &[&user("u2", "koala in b")]));
        let visible: HashSet<String> = [b.to_string_lossy().to_string()].into();
        let req = Req { q: "koala".into(), limit: 20, offset: 0, hits: 3, ..Default::default() };
        // The hidden chat's hit is not counted and not returned.
        let found = f.index.search(std::slice::from_ref(&f.sessions), &req, Some(&visible)).unwrap();
        assert_eq!((found.total, found.results.len()), (1, 1));
        assert!(found.results[0].path.ends_with("b.jsonl"));
        // Paging counts shown chats, so offset 1 is empty rather than a repeat.
        let req = Req { offset: 1, ..Req { q: "koala".into(), limit: 20, offset: 0, hits: 3, ..Default::default() } };
        assert_eq!(f.index.search(std::slice::from_ref(&f.sessions), &req, Some(&visible)).unwrap().results.len(), 0);
        // Everything hidden: no matches at all.
        let none: HashSet<String> = HashSet::new();
        assert_eq!(f.index.search(std::slice::from_ref(&f.sessions), &req, Some(&none)).unwrap().total, 0);
    }

    #[test]
    fn unknown_role_answers_nothing() {
        let f = Fixture::new("role");
        f.write("a.jsonl", &session("a", "/p", &[&user("u1", "needle")]));
        let req = Req { q: "needle".into(), roles: vec!["system".into()], limit: 20, hits: 2, ..Default::default() };
        assert_eq!(f.index.search(std::slice::from_ref(&f.sessions), &req, None).unwrap().total, 0);
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_file_keeps_its_entries() {
        use std::os::unix::fs::PermissionsExt;
        let f = Fixture::new("unreadable");
        let p = f.write("a.jsonl", &session("a", "/p", &[&user("u1", "walrus")]));
        assert_eq!(f.find("walrus").total, 1);
        // Size changes, so the next sync tries to read it again; it can't.
        let mut body = std::fs::read_to_string(&p).unwrap();
        body.push_str(&user("u2", "second"));
        std::fs::write(&p, &body).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o000)).unwrap();
        let found = f.find("walrus");
        assert_eq!((found.total, found.results[0].count), (1, 1), "old entries survive a failed read");
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o644)).unwrap();
        // Readable again: the same (mtime, size) is now indexed.
        assert_eq!(f.find("second").total, 1);
    }

    #[test]
    fn odd_queries_do_not_error() {
        let f = Fixture::new("odd");
        f.write("a.jsonl", &session("a", "/p", &[&user("u1", "needle in a haystack")]));
        for q in ["needle", "\"needle", "needle*", "NEAR(needle haystack)", "(needle OR haystack)", "-needle", "!!!", "  ", "\u{4e2d}\u{6587}"] {
            let req = Req { q: q.to_string(), limit: 5, offset: 0, hits: 2, ..Default::default() };
            assert!(f.index.search(std::slice::from_ref(&f.sessions), &req, None).is_ok(), "query {q:?}");
        }
        assert_eq!(f.find("needle haystack").total, 1); // AND
        assert_eq!(f.find("needle zebra").total, 1); // OR fallback
        assert_eq!(f.find("zebra xylophone").total, 0);
    }

    #[test]
    fn indexes_summaries_and_skips_system() {
        let f = Fixture::new("summary");
        let compaction = r#"{"type":"message","id":"c1","message":{"role":"compactionSummary","summary":"we settled on tangerines"}}"#;
        let system = r#"{"type":"message","id":"s1","message":{"role":"system","content":"secret tangerine prompt"}}"#;
        f.write("a.jsonl", &session("a", "/p", &[compaction, system]));
        let found = f.find("tangerines");
        assert_eq!(found.total, 1);
        assert_eq!(found.results[0].hits[0].role, "summary");
        // The system prompt is not indexed.
        let found = f.find("secret");
        assert_eq!(found.total, 0);
    }
}
