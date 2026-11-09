//! The files panel (docs/dsh-features-plan.md §3.5): browsing, reading and
//! searching a chat's folder, and the files each turn changed.
//!
//! Every endpoint is rooted at a folder a client may look into: a live chat's
//! cwd, a pinned project, or the cwd of a chat on disk (`allowed_root`).
//!
//! - `GET /api/files/list?root=&dir=`: one folder, folders first, then a
//!   natural sort; dotfiles shown; at most `LIST_MAX` entries (`truncated`).
//! - `GET /api/files/read?root=&path=&from=&lines=`: a page of a text file,
//!   at most `PAGE_LINES` lines or `PAGE_BYTES` bytes, with a `version`
//!   (mtime and size). 422 `not-text` for NUL bytes or invalid UTF-8, 413
//!   `too-large` for a file over `READ_MAX` or a line over `PAGE_BYTES`.
//! - `GET /api/files/raw?root=&path=[&download=1]`: the bytes (at most
//!   `RAW_MAX`), for images, PDFs and downloads, always with
//!   `Content-Security-Policy: sandbox` and `nosniff`, so an SVG or HTML file
//!   never runs as the app's origin.
//! - `GET /api/files/search?root=&q=`: paths for `@` mentions, ranked like
//!   dsh (exact name, prefix, substring, path substring, subsequence) over a
//!   bounded index (`INDEX_MAX`) that is rebuilt lazily after a turn.
//! - `GET /api/files/changes?key=|path=[&turn=N|all][&file=]`: the files each
//!   turn changed, or one file's diff.
//!
//! Path safety: every path is `lstat`ed, canonicalized and must stay under
//! the canonical root (the pattern of `exports::session_file_in`); `..` is
//! refused outright, a final symlink is never read, and a listing shows
//! symlinks as links without following one that leaves the root.
//!
//! Changed files: on `agent_start` and `agent_settled` of a chat (`observe`,
//! called from main.rs's stdout reader) the work tree is snapshotted with
//! `git add --all` into a private index and `git write-tree`, writing to a
//! private object store with the repository's objects as an alternate: the
//! repository's index, objects and refs are never written. The tree ids and
//! each turn's numstat are kept in `chat_state` under `"files"`, so they
//! survive restarts. Outside git, a turn's changed files are the paths its
//! `edit` and `write` tool calls named. Each settled turn is also announced to
//! the chat's clients as `{"type":"pocketpi_turn_files", …}`. The start
//! snapshot runs beside the turn, not before it: a tool call that lands
//! before the snapshot has walked the tree (a model acting within a few
//! hundred milliseconds of the prompt) counts as part of the "before".

use crate::{AppResult, AppState, Kind, Live, err, exports, projects, sessions};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    cmp::Ordering,
    collections::{BTreeSet, HashMap},
    io::{BufRead, BufReader, Read},
    path::{Component, Path, PathBuf},
    sync::{Arc, LazyLock, Mutex},
    time::{Duration, Instant, UNIX_EPOCH},
};

/// Entries one listing returns at most.
const LIST_MAX: usize = 2000;
/// A read page: at most this many lines, and this many bytes.
const PAGE_LINES: usize = 5000;
const PAGE_BYTES: usize = 2 * 1024 * 1024;
/// Text files larger than this aren't paged through at all.
const READ_MAX: u64 = 64 * 1024 * 1024;
/// The most `raw` serves.
const RAW_MAX: u64 = 32 * 1024 * 1024;
/// Entries the search index keeps per root.
const INDEX_MAX: usize = 50_000;
/// Search results returned by default and at most.
const SEARCH_DEFAULT: usize = 20;
const SEARCH_MAX: usize = 50;
/// An index older than this is rebuilt (in the background) on the next query.
const INDEX_TTL: Duration = Duration::from_secs(300);
/// Turns kept per chat (the oldest go; the chat's first tree stays).
const TURNS_MAX: usize = 300;
/// The most a diff answers with.
const DIFF_MAX: usize = 2 * 1024 * 1024;
/// How long one git command may take.
const GIT_TIMEOUT: Duration = Duration::from_secs(90);

/// dsh's folders that search never descends into (dependency stores, build
/// output, version control), which already include `target`.
const EXCLUDED_DIRS: &[&str] = &[
    ".git", "node_modules", "dist", "build", "out", "coverage", "target", ".next", ".nuxt", ".turbo", ".venv",
    "__pycache__", ".pytest_cache", ".mypy_cache", ".gradle",
];

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/api/files/list", get(list))
        .route("/api/files/read", get(read))
        .route("/api/files/raw", get(raw))
        .route("/api/files/search", get(search))
        .route("/api/files/changes", get(changes))
}

// ------------------------------------------------------------------ roots

/// Roots recently found allowed, so a listing doesn't rescan the sessions.
static ALLOWED: LazyLock<Mutex<HashMap<PathBuf, Instant>>> = LazyLock::new(Default::default);
const ALLOWED_TTL: Duration = Duration::from_secs(60);

/// The canonical form of `raw` when it is a folder a client may browse: a
/// live chat's cwd, a pinned project, or the cwd of a chat on disk (not the
/// Chat tab's folder, not workflow worktrees).
async fn allowed_root(app: &Arc<AppState>, raw: &str) -> AppResult<PathBuf> {
    let root = std::fs::canonicalize(raw.trim()).map_err(|_| err(StatusCode::NOT_FOUND, "no such folder"))?;
    if !root.is_dir() {
        return Err(err(StatusCode::BAD_REQUEST, "not a folder"));
    }
    if ALLOWED.lock().unwrap().get(&root).is_some_and(|t| t.elapsed() < ALLOWED_TTL) {
        return Ok(root);
    }
    let same = |p: &str| std::fs::canonicalize(p).is_ok_and(|c| c == root);
    let live: Vec<String> = app.live.lock().unwrap().values().filter(|l| l.kind == Kind::Chat).map(|l| l.cwd.clone()).collect();
    let mut ok = live.iter().any(|c| same(c)) || projects::load(&app.projects_path).pinned.iter().any(|p| same(&p.path));
    if !ok && root != app.chat_dir {
        let app2 = app.clone();
        let list = tokio::task::spawn_blocking(move || sessions::scan(&app2.sessions_dir, &app2.meta_cache)).await.unwrap_or_default();
        let wt = app.engine.worktrees_dir.clone();
        let mut seen = BTreeSet::new();
        ok = list.iter().filter(|s| !Path::new(&s.cwd).starts_with(&wt)).any(|s| seen.insert(s.cwd.clone()) && same(&s.cwd));
    }
    if !ok {
        return Err(err(StatusCode::FORBIDDEN, "not a project folder"));
    }
    let mut a = ALLOWED.lock().unwrap();
    if a.len() > 256 {
        a.clear();
    }
    a.insert(root.clone(), Instant::now());
    Ok(root)
}

// ------------------------------------------------------------------ paths

#[derive(Debug, PartialEq)]
pub enum FileError {
    NotFound,
    /// The path leaves the root (`..`, an absolute path, a symlink out).
    Outside,
    /// The file itself is a symlink: never read.
    Symlink,
    NotDir,
    NotFile,
    NotText,
    TooLarge,
    Io(String),
}

impl FileError {
    fn status(&self) -> (StatusCode, String) {
        match self {
            FileError::NotFound => err(StatusCode::NOT_FOUND, "not found"),
            FileError::Outside => err(StatusCode::FORBIDDEN, "outside the folder"),
            FileError::Symlink => err(StatusCode::FORBIDDEN, "symlink"),
            FileError::NotDir => err(StatusCode::BAD_REQUEST, "not a folder"),
            FileError::NotFile => err(StatusCode::BAD_REQUEST, "not a file"),
            FileError::NotText => err(StatusCode::UNPROCESSABLE_ENTITY, "not-text"),
            FileError::TooLarge => err(StatusCode::PAYLOAD_TOO_LARGE, "too-large"),
            FileError::Io(e) => err(StatusCode::INTERNAL_SERVER_ERROR, e.clone()),
        }
    }
}

/// A path under a root, checked.
#[derive(Debug)]
pub struct Resolved {
    /// Where it really is: under the root.
    pub canonical: PathBuf,
    /// `lstat` of `joined`: says whether the last component is a symlink.
    pub lmeta: std::fs::Metadata,
}

/// `rel` (slash-separated, relative; "" or "." is the root itself) under the
/// canonical `root`: lstat'ed, canonicalized and required to stay under the
/// root. `..`, absolute paths and NUL bytes are refused before touching the
/// file system.
pub fn resolve(root: &Path, rel: &str) -> Result<Resolved, FileError> {
    let rel = rel.trim_start_matches("./");
    if rel.contains('\0') {
        return Err(FileError::Outside);
    }
    let p = Path::new(rel);
    if p.components().any(|c| !matches!(c, Component::Normal(_) | Component::CurDir)) {
        return Err(FileError::Outside);
    }
    let joined = root.join(p);
    let lmeta = std::fs::symlink_metadata(&joined).map_err(|_| FileError::NotFound)?;
    // A dangling symlink, or a loop: nothing there to show.
    let canonical = std::fs::canonicalize(&joined).map_err(|_| FileError::NotFound)?;
    if !canonical.starts_with(root) {
        return Err(FileError::Outside);
    }
    Ok(Resolved { canonical, lmeta })
}

fn mtime_ms(m: &std::fs::Metadata) -> u64 {
    m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn version_of(m: &std::fs::Metadata) -> String {
    format!("{}-{}", mtime_ms(m), m.len())
}

// ------------------------------------------------------------------ list

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct Entry {
    pub name: String,
    /// "dir", "file", "link" or "other".
    pub kind: &'static str,
    pub size: u64,
    pub mtime: u64,
    /// For a link: "dir" or "file" when it points inside the root (so it
    /// can be opened), absent when it leaves the root or dangles.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<&'static str>,
}

#[derive(Debug, Serialize)]
pub struct Listing {
    pub dir: String,
    pub entries: Vec<Entry>,
    pub truncated: bool,
}

/// Natural order: digit runs compare as numbers, the rest ignoring case
/// ("file2" before "file10", "a" before "B").
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return a.cmp(b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let mut n = String::new();
                while let Some(c) = x.next_if(|c| c.is_ascii_digit()) {
                    n.push(c);
                }
                let mut m = String::new();
                while let Some(d) = y.next_if(|d| d.is_ascii_digit()) {
                    m.push(d);
                }
                let (nt, mt) = (n.trim_start_matches('0'), m.trim_start_matches('0'));
                let o = nt.len().cmp(&mt.len()).then_with(|| nt.cmp(mt));
                if o != Ordering::Equal {
                    return o;
                }
            }
            (Some(c), Some(d)) => {
                let o = c.to_lowercase().cmp(d.to_lowercase());
                if o != Ordering::Equal {
                    return o;
                }
                x.next();
                y.next();
            }
        }
    }
}

/// The folder `rel` under `root`, at most `cap` entries.
pub fn list_dir(root: &Path, rel: &str, cap: usize) -> Result<Listing, FileError> {
    let r = resolve(root, rel)?;
    if !r.canonical.is_dir() {
        return Err(FileError::NotDir);
    }
    let rd = std::fs::read_dir(&r.canonical).map_err(|e| FileError::Io(e.to_string()))?;
    let mut entries = Vec::new();
    for e in rd.flatten() {
        let Ok(m) = e.path().symlink_metadata() else { continue };
        let name = e.file_name().to_string_lossy().to_string();
        let ft = m.file_type();
        let (kind, target) = if ft.is_dir() {
            ("dir", None)
        } else if ft.is_file() {
            ("file", None)
        } else if ft.is_symlink() {
            // Followed only to say what it is, and only inside the root.
            let t = std::fs::canonicalize(e.path()).ok().filter(|c| c.starts_with(root)).and_then(|c| {
                let m = std::fs::metadata(c).ok()?;
                Some(if m.is_dir() { "dir" } else { "file" })
            });
            ("link", t)
        } else {
            ("other", None)
        };
        entries.push(Entry { name, kind, size: if ft.is_file() { m.len() } else { 0 }, mtime: mtime_ms(&m), target });
    }
    let is_dir = |e: &Entry| e.kind == "dir" || e.target == Some("dir");
    entries.sort_by(|a, b| is_dir(b).cmp(&is_dir(a)).then_with(|| natural_cmp(&a.name, &b.name)));
    let truncated = entries.len() > cap;
    entries.truncate(cap);
    let dir = r.canonical.strip_prefix(root).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    Ok(Listing { dir, entries, truncated })
}

#[derive(Deserialize)]
struct ListQuery {
    root: String,
    #[serde(default)]
    dir: String,
}

async fn list(State(app): State<Arc<AppState>>, Query(q): Query<ListQuery>) -> AppResult<Json<Value>> {
    let root = allowed_root(&app, &q.root).await?;
    let r = root.clone();
    let l = tokio::task::spawn_blocking(move || list_dir(&r, &q.dir, LIST_MAX))
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| e.status())?;
    Ok(Json(json!({"root": root, "dir": l.dir, "entries": l.entries, "truncated": l.truncated})))
}

// ------------------------------------------------------------------ read

#[derive(Debug, Serialize, PartialEq)]
pub struct Page {
    /// The first line's number (1-based).
    pub from: usize,
    pub lines: Vec<String>,
    /// The next page's first line, or None at the end of the file.
    pub next: Option<usize>,
    pub size: u64,
    pub mtime: u64,
    pub version: String,
}

/// Limits of `read_page`, so tests can use small ones.
#[derive(Clone, Copy)]
pub struct ReadLimits {
    pub lines: usize,
    pub bytes: usize,
    pub file: u64,
}

const LIMITS: ReadLimits = ReadLimits { lines: PAGE_LINES, bytes: PAGE_BYTES, file: READ_MAX };

/// A page of a text file: up to `want` lines (capped by `lim`) from line
/// `from` (1-based). A final symlink is refused. `NotText` for a NUL in the
/// file's first 8 KiB or in the page, or a line that isn't UTF-8.
pub fn read_page(root: &Path, rel: &str, from: usize, want: usize, lim: ReadLimits) -> Result<Page, FileError> {
    let r = resolve(root, rel)?;
    if r.lmeta.file_type().is_symlink() {
        return Err(FileError::Symlink);
    }
    if !r.lmeta.is_file() {
        return Err(FileError::NotFile);
    }
    let m = &r.lmeta;
    if m.len() > lim.file {
        return Err(FileError::TooLarge);
    }
    let file = std::fs::File::open(&r.canonical).map_err(|e| FileError::Io(e.to_string()))?;
    // git's test for binary: a NUL early on.
    let mut head = Vec::with_capacity(8192);
    (&file).take(8192).read_to_end(&mut head).map_err(|e| FileError::Io(e.to_string()))?;
    if head.contains(&0) {
        return Err(FileError::NotText);
    }
    let file = std::fs::File::open(&r.canonical).map_err(|e| FileError::Io(e.to_string()))?;
    let mut rd = BufReader::new(file);
    let from = from.max(1);
    let want = want.clamp(1, lim.lines);
    let mut buf = Vec::new();
    for _ in 1..from {
        buf.clear();
        if rd.read_until(b'\n', &mut buf).map_err(|e| FileError::Io(e.to_string()))? == 0 {
            break;
        }
    }
    let mut lines = Vec::new();
    let mut bytes = 0usize;
    let mut held: Option<Vec<u8>> = None; // a line read but not taken (page full)
    loop {
        if lines.len() >= want {
            break;
        }
        buf.clear();
        if rd.read_until(b'\n', &mut buf).map_err(|e| FileError::Io(e.to_string()))? == 0 {
            break;
        }
        if bytes + buf.len() > lim.bytes {
            if lines.is_empty() {
                return Err(FileError::TooLarge);
            }
            held = Some(std::mem::take(&mut buf));
            break;
        }
        bytes += buf.len();
        while matches!(buf.last(), Some(b'\n' | b'\r')) {
            buf.pop();
        }
        if buf.contains(&0) {
            return Err(FileError::NotText);
        }
        lines.push(String::from_utf8(std::mem::take(&mut buf)).map_err(|_| FileError::NotText)?);
    }
    let more = held.is_some() || !rd.fill_buf().map_err(|e| FileError::Io(e.to_string()))?.is_empty();
    let next = more.then_some(from + lines.len());
    Ok(Page { from, lines, next, size: m.len(), mtime: mtime_ms(m), version: version_of(m) })
}

#[derive(Deserialize)]
struct ReadQuery {
    root: String,
    path: String,
    from: Option<usize>,
    lines: Option<usize>,
}

async fn read(State(app): State<Arc<AppState>>, Query(q): Query<ReadQuery>) -> AppResult<Json<Value>> {
    let root = allowed_root(&app, &q.root).await?;
    let path = q.path.clone();
    let p = tokio::task::spawn_blocking(move || read_page(&root, &q.path, q.from.unwrap_or(1), q.lines.unwrap_or(PAGE_LINES), LIMITS))
        .await
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
        .map_err(|e| e.status())?;
    let mut v = serde_json::to_value(p).unwrap_or_default();
    v["path"] = json!(path);
    Ok(Json(v))
}

// ------------------------------------------------------------------ raw

/// A media type for previews; anything else downloads.
pub fn media_type(name: &str) -> Option<&'static str> {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase())?;
    Some(match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "svg" => "image/svg+xml",
        "heic" => "image/heic",
        "pdf" => "application/pdf",
        _ => return None,
    })
}

#[derive(Deserialize)]
struct RawQuery {
    root: String,
    path: String,
    download: Option<String>,
}

async fn raw(State(app): State<Arc<AppState>>, Query(q): Query<RawQuery>) -> AppResult<Response> {
    let root = allowed_root(&app, &q.root).await?;
    let rel = q.path.clone();
    let (bytes, name) = tokio::task::spawn_blocking(move || -> Result<(Vec<u8>, String), FileError> {
        let r = resolve(&root, &rel)?;
        if r.lmeta.file_type().is_symlink() {
            return Err(FileError::Symlink);
        }
        if !r.lmeta.is_file() {
            return Err(FileError::NotFile);
        }
        if r.lmeta.len() > RAW_MAX {
            return Err(FileError::TooLarge);
        }
        let name = r.canonical.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "file".into());
        Ok((std::fs::read(&r.canonical).map_err(|e| FileError::Io(e.to_string()))?, name))
    })
    .await
    .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?
    .map_err(|e| e.status())?;
    let ctype = media_type(&name);
    let attach = q.download.is_some() || ctype.is_none();
    let mut res = bytes.into_response();
    let hs = res.headers_mut();
    hs.insert(header::CONTENT_TYPE, HeaderValue::from_static(ctype.unwrap_or("application/octet-stream")));
    // Chrome refuses to show a PDF in a sandboxed document, and its viewer
    // runs a PDF's scripts in its own origin, so PDFs go out without it.
    // Everything else (SVG, HTML) never runs as the app's origin.
    if ctype != Some("application/pdf") {
        hs.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static("sandbox"));
    }
    hs.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    hs.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    let ascii: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || "._-".contains(c) { c } else { '_' }).collect();
    let disp = format!("{}; filename=\"{ascii}\"; filename*=UTF-8''{}", if attach { "attachment" } else { "inline" }, crate::urlencode(&name));
    if let Ok(v) = HeaderValue::from_str(&disp) {
        hs.insert(header::CONTENT_DISPOSITION, v);
    }
    Ok(res)
}

// ------------------------------------------------------------------ search

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Candidate {
    pub path: String,
    /// "file" or "dir".
    pub kind: &'static str,
}

/// Walks `root` breadth first, in name order, without following symlinks or
/// entering `EXCLUDED_DIRS`, up to `max` entries.
pub fn build_index(root: &Path, max: usize) -> Vec<Candidate> {
    let mut out = Vec::new();
    let mut dirs = std::collections::VecDeque::from([(root.to_path_buf(), String::new())]);
    while let Some((abs, rel)) = dirs.pop_front() {
        let Ok(rd) = std::fs::read_dir(&abs) else { continue };
        let mut items: Vec<_> = rd.flatten().collect();
        items.sort_by_key(|e| e.file_name());
        for e in items {
            if out.len() >= max {
                return out;
            }
            let Ok(ft) = e.file_type() else { continue };
            let name = e.file_name().to_string_lossy().to_string();
            let path = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            if ft.is_dir() {
                if EXCLUDED_DIRS.contains(&name.as_str()) {
                    continue;
                }
                out.push(Candidate { path: path.clone(), kind: "dir" });
                dirs.push_back((e.path(), path));
            } else if ft.is_file() {
                out.push(Candidate { path, kind: "file" });
            }
        }
    }
    out
}

/// dsh's score: exact name, name prefix, name substring, path substring,
/// then a subsequence (fewer gaps scoring higher). Folders get a small bonus.
fn score(c: &Candidate, q: &str) -> Option<i64> {
    if q.is_empty() {
        return Some(0);
    }
    let path = c.path.to_lowercase();
    let name = path.rsplit('/').next().unwrap_or(&path);
    let needle = q.to_lowercase();
    let bonus = if c.kind == "dir" { 25 } else { 0 };
    if name == needle {
        return Some(1000 + bonus);
    }
    if name.starts_with(&needle) {
        return Some(900 + bonus);
    }
    if name.contains(&needle) {
        return Some(700 + bonus);
    }
    if path.contains(&needle) {
        return Some(500 + bonus);
    }
    let mut at = 0usize;
    let mut gap = 0usize;
    for ch in needle.chars() {
        let found = path[at..].find(ch)?;
        gap += found;
        at += found + ch.len_utf8();
    }
    Some(300 + 100i64.saturating_sub(gap as i64).max(0) + bonus)
}

/// Dot paths only show up when the query asks for them.
fn visible(path: &str, q: &str) -> bool {
    q.starts_with('.') || q.contains("/.") || !path.split('/').any(|s| s.starts_with('.'))
}

/// The best `limit` candidates for `q`: score, then folders first, then the
/// shorter path, then by name.
pub fn rank<'a>(cands: impl IntoIterator<Item = &'a Candidate>, q: &str, limit: usize) -> Vec<Candidate> {
    let mut hits: Vec<(i64, &Candidate)> = cands.into_iter().filter_map(|c| score(c, q).map(|s| (s, c))).collect();
    hits.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| (a.1.kind != "dir").cmp(&(b.1.kind != "dir")))
            .then_with(|| if q.is_empty() { Ordering::Equal } else { a.1.path.len().cmp(&b.1.path.len()) })
            .then_with(|| a.1.path.cmp(&b.1.path))
    });
    hits.into_iter().take(limit).map(|(_, c)| c.clone()).collect()
}

/// Search answers for `q` from `index`: a query with a slash (or an empty
/// one) lists that folder live, like dsh; anything else ranks the index.
pub fn search_in(root: &Path, index: &[Candidate], q: &str, limit: usize) -> Vec<Candidate> {
    if q.is_empty() || q.contains('/') {
        let (dir, frag) = q.rsplit_once('/').map(|(d, f)| (d, f)).unwrap_or(("", q));
        if dir.split('/').any(|s| EXCLUDED_DIRS.contains(&s)) {
            return Vec::new();
        }
        // Each step must be a real folder, not a symlink.
        let mut cur = root.to_path_buf();
        for seg in dir.split('/').filter(|s| !s.is_empty()) {
            if seg == ".." || seg == "." {
                return Vec::new();
            }
            cur.push(seg);
            match std::fs::symlink_metadata(&cur) {
                Ok(m) if m.is_dir() => {}
                _ => return Vec::new(),
            }
        }
        let prefix = if dir.is_empty() { String::new() } else { format!("{dir}/") };
        let mut cands = Vec::new();
        for e in std::fs::read_dir(&cur).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') && !frag.starts_with('.') {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() && !EXCLUDED_DIRS.contains(&name.as_str()) {
                cands.push(Candidate { path: format!("{prefix}{name}"), kind: "dir" });
            } else if ft.is_file() {
                cands.push(Candidate { path: format!("{prefix}{name}"), kind: "file" });
            }
        }
        // Rank by the name part only.
        let scored: Vec<Candidate> = cands.iter().map(|c| Candidate { path: c.path[prefix.len()..].to_string(), kind: c.kind }).collect();
        return rank(&scored, frag, limit).into_iter().map(|c| Candidate { path: format!("{prefix}{}", c.path), kind: c.kind }).collect();
    }
    rank(index.iter().filter(|c| visible(&c.path, q)), q, limit)
}

struct Index {
    entries: Arc<Vec<Candidate>>,
    built: Instant,
    stale: bool,
    building: bool,
}

static INDEXES: LazyLock<Mutex<HashMap<PathBuf, Index>>> = LazyLock::new(Default::default);

/// Marks the search index of `cwd` (and folders under it) out of date: the
/// next query answers from it and rebuilds it behind.
pub fn invalidate(cwd: &Path) {
    for (root, ix) in INDEXES.lock().unwrap().iter_mut() {
        if root.starts_with(cwd) || cwd.starts_with(root) {
            ix.stale = true;
        }
    }
}

async fn index_for(root: &Path) -> Arc<Vec<Candidate>> {
    let rebuild = {
        let mut m = INDEXES.lock().unwrap();
        match m.get_mut(root) {
            Some(ix) => {
                let old = ix.stale || ix.built.elapsed() > INDEX_TTL;
                if old && !ix.building {
                    ix.building = true;
                    let r = root.to_path_buf();
                    tokio::spawn(async move {
                        let r2 = r.clone();
                        let entries = tokio::task::spawn_blocking(move || build_index(&r2, INDEX_MAX)).await.unwrap_or_default();
                        if let Some(ix) = INDEXES.lock().unwrap().get_mut(&r) {
                            *ix = Index { entries: Arc::new(entries), built: Instant::now(), stale: false, building: false };
                        }
                    });
                }
                return ix.entries.clone();
            }
            None => true,
        }
    };
    debug_assert!(rebuild);
    let r = root.to_path_buf();
    let entries = Arc::new(tokio::task::spawn_blocking(move || build_index(&r, INDEX_MAX)).await.unwrap_or_default());
    let mut m = INDEXES.lock().unwrap();
    if m.len() >= 32 {
        m.clear();
    }
    m.insert(root.to_path_buf(), Index { entries: entries.clone(), built: Instant::now(), stale: false, building: false });
    entries
}

#[derive(Deserialize)]
struct SearchQuery {
    root: String,
    #[serde(default)]
    q: String,
    limit: Option<usize>,
}

async fn search(State(app): State<Arc<AppState>>, Query(q): Query<SearchQuery>) -> AppResult<Json<Value>> {
    let root = allowed_root(&app, &q.root).await?;
    let query = q.q.replace('\\', "/");
    let limit = q.limit.unwrap_or(SEARCH_DEFAULT).clamp(1, SEARCH_MAX);
    let index = if query.is_empty() || query.contains('/') { Arc::new(Vec::new()) } else { index_for(&root).await };
    let capped = index.len() >= INDEX_MAX;
    let r = root.clone();
    let results = tokio::task::spawn_blocking(move || search_in(&r, &index, &query, limit)).await.unwrap_or_default();
    Ok(Json(json!({"results": results, "truncated": capped})))
}

// ------------------------------------------------------------------ git snapshots

/// A git work tree, as seen from a chat's cwd.
#[derive(Debug, Clone)]
pub struct Repo {
    /// The work tree's top folder.
    pub top: PathBuf,
    pub git_dir: PathBuf,
    /// The repository's object store (an alternate of the private one).
    pub objects: PathBuf,
    /// The cwd relative to `top` ("" or ending in "/").
    pub prefix: String,
}

fn git_cmd(dir: &Path) -> tokio::process::Command {
    let mut c = tokio::process::Command::new("git");
    c.current_dir(dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    for v in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_PARAMETERS", "GIT_LITERAL_PATHSPECS"] {
        c.env_remove(v);
    }
    c.env("GIT_TERMINAL_PROMPT", "0").env("GIT_OPTIONAL_LOCKS", "0").env("LC_ALL", "C");
    c
}

async fn run_git(mut c: tokio::process::Command, what: &str) -> Result<std::process::Output, String> {
    match tokio::time::timeout(GIT_TIMEOUT, c.output()).await {
        Err(_) => Err(format!("git {what} timed out")),
        Ok(Err(e)) => Err(format!("git {what}: {e}")),
        Ok(Ok(o)) => Ok(o),
    }
}

fn failed(what: &str, o: &std::process::Output) -> String {
    format!("git {what} failed: {}", String::from_utf8_lossy(&o.stderr).trim())
}

/// The work tree `cwd` is in, or None outside git (or in a bare repository).
pub async fn locate(cwd: &Path) -> Option<Repo> {
    let mut c = git_cmd(cwd);
    c.args(["rev-parse", "--show-toplevel", "--absolute-git-dir", "--git-path", "objects", "--show-prefix"]);
    let o = run_git(c, "rev-parse").await.ok()?;
    if !o.status.success() {
        return None;
    }
    let text = String::from_utf8(o.stdout).ok()?;
    let mut l = text.lines();
    let top = PathBuf::from(l.next()?);
    let git_dir = PathBuf::from(l.next()?);
    let objects = cwd.join(l.next()?);
    let prefix = l.next().unwrap_or("").to_string();
    Some(Repo { top, git_dir, objects, prefix })
}

/// The private store of a repository's snapshots: `<data>/snapshots/<hash>`.
pub fn store_for(snapshots: &Path, repo: &Repo) -> PathBuf {
    // FNV-1a of the git dir: stable, and no dependency for it.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in repo.git_dir.to_string_lossy().bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    snapshots.join(format!("{h:016x}"))
}

fn store_env(c: &mut tokio::process::Command, repo: &Repo, store: &Path) {
    c.env("GIT_OBJECT_DIRECTORY", store.join("objects")).env("GIT_ALTERNATE_OBJECT_DIRECTORIES", &repo.objects);
}

static SNAP_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// The whole work tree (tracked, modified and untracked files, not ignored
/// ones) as a tree id, written through a private index seeded from the
/// repository's, into the private object store `store`.
pub async fn snapshot(repo: &Repo, store: &Path) -> Result<String, String> {
    std::fs::create_dir_all(store.join("objects")).map_err(|e| e.to_string())?;
    let n = SNAP_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let index = store.join(format!("index-{}-{n}", std::process::id()));
    let res = async {
        for seeded in [true, false] {
            let _ = std::fs::remove_file(&index);
            if seeded {
                // The repository's stat cache: only changed files get hashed.
                if std::fs::copy(repo.git_dir.join("index"), &index).is_err() {
                    continue;
                }
            }
            let mut add = git_cmd(&repo.top);
            store_env(&mut add, repo, store);
            add.env("GIT_INDEX_FILE", &index).args(["add", "--all", "--ignore-errors"]);
            // The store inside the work tree (a data dir under a home that is
            // a repository): keep it out.
            if let Ok(rel) = store.strip_prefix(&repo.top) {
                add.arg("--").arg(".").arg(format!(":(exclude){}", rel.to_string_lossy()));
            }
            let o = run_git(add, "add").await?;
            // 1: some files couldn't be read (--ignore-errors); the rest is in.
            if !matches!(o.status.code(), Some(0 | 1)) {
                if seeded {
                    continue; // an index the copy can't stand on (split index): start empty
                }
                return Err(failed("add", &o));
            }
            let mut wt = git_cmd(&repo.top);
            store_env(&mut wt, repo, store);
            wt.env("GIT_INDEX_FILE", &index).arg("write-tree");
            let o = run_git(wt, "write-tree").await?;
            if !o.status.success() {
                if seeded {
                    continue;
                }
                return Err(failed("write-tree", &o));
            }
            return Ok(String::from_utf8_lossy(&o.stdout).trim().to_string());
        }
        Err("git snapshot failed".to_string())
    }
    .await;
    let _ = std::fs::remove_file(&index);
    let _ = std::fs::remove_file(index.with_extension("lock"));
    res
}

/// One changed file of a turn.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Changed {
    /// Relative to the chat's cwd (with `../` for files above it).
    pub path: String,
    /// Lines added and removed; None for a binary file, or outside git.
    pub added: Option<u64>,
    pub removed: Option<u64>,
    /// A rename's old path.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

/// Parses `git diff-tree -r -M -z --numstat` (paths relative to the top).
pub fn parse_numstat(out: &[u8]) -> Vec<(Option<u64>, Option<u64>, String, Option<String>)> {
    let text = String::from_utf8_lossy(out);
    let mut toks = text.split('\0');
    let mut res = Vec::new();
    while let Some(t) = toks.next() {
        if t.is_empty() {
            continue;
        }
        let mut f = t.splitn(3, '\t');
        let (Some(a), Some(d), Some(p)) = (f.next(), f.next(), f.next()) else { continue };
        let (path, from) = if p.is_empty() {
            let old = toks.next().unwrap_or("").to_string();
            (toks.next().unwrap_or("").to_string(), Some(old))
        } else {
            (p.to_string(), None)
        };
        res.push((a.parse().ok(), d.parse().ok(), path, from));
    }
    res
}

/// A top-relative path as seen from the cwd `prefix` ("sub/dir/").
pub fn from_prefix(prefix: &str, path: &str) -> String {
    if prefix.is_empty() {
        return path.to_string();
    }
    if let Some(rest) = path.strip_prefix(prefix) {
        return rest.to_string();
    }
    let depth = prefix.trim_end_matches('/').split('/').count();
    format!("{}{path}", "../".repeat(depth))
}

/// The other way: a cwd-relative path to a top-relative one; None when it
/// would leave the work tree.
pub fn to_top(prefix: &str, path: &str) -> Option<String> {
    let mut parts: Vec<&str> = prefix.split('/').filter(|s| !s.is_empty()).collect();
    for seg in path.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            s => parts.push(s),
        }
    }
    (!parts.is_empty()).then(|| parts.join("/"))
}

/// The files that differ between two snapshot trees.
pub async fn numstat(repo: &Repo, store: &Path, a: &str, b: &str) -> Result<Vec<Changed>, String> {
    if a == b {
        return Ok(Vec::new());
    }
    let mut c = git_cmd(&repo.top);
    store_env(&mut c, repo, store);
    c.args(["diff-tree", "-r", "-M", "-z", "--numstat", a, b]);
    let o = run_git(c, "diff-tree").await?;
    if !o.status.success() {
        return Err(failed("diff-tree", &o));
    }
    Ok(parse_numstat(&o.stdout)
        .into_iter()
        .map(|(added, removed, path, from)| Changed {
            path: from_prefix(&repo.prefix, &path),
            added,
            removed,
            from: from.map(|f| from_prefix(&repo.prefix, &f)),
        })
        .collect())
}

/// One file's patch between two snapshot trees (`paths` cwd-relative: the
/// file, and a rename's old path).
pub async fn diff(repo: &Repo, store: &Path, a: &str, b: &str, paths: &[&str]) -> Result<String, String> {
    let mut c = git_cmd(&repo.top);
    store_env(&mut c, repo, store);
    c.env("GIT_LITERAL_PATHSPECS", "1").args(["diff-tree", "-p", "-M", "--no-color", "--no-ext-diff", "--no-textconv", a, b, "--"]);
    for p in paths {
        c.arg(to_top(&repo.prefix, p).ok_or("outside the repository")?);
    }
    let o = run_git(c, "diff-tree").await?;
    if !o.status.success() {
        return Err(failed("diff-tree", &o));
    }
    let mut out = o.stdout;
    let cut = out.len() > DIFF_MAX;
    out.truncate(DIFF_MAX);
    let mut s = String::from_utf8_lossy(&out).to_string();
    if cut {
        s.push_str("\n… (diff cut at 2 MiB)\n");
    }
    Ok(s)
}

// ------------------------------------------------------------------ turns

/// A turn being run: from `agent_start` to `agent_settled`.
struct Pending {
    /// Which pi (a restarted chat keeps its key): a turn its predecessor
    /// never finished doesn't carry over.
    pi: usize,
    start: u64,
    cwd: PathBuf,
    /// The snapshot at the start (None outside git).
    before: tokio::task::JoinHandle<Option<(Repo, Result<String, String>)>>,
    /// Paths `edit` and `write` named (the record outside git).
    paths: BTreeSet<String>,
}

static PENDING: LazyLock<Mutex<HashMap<String, Pending>>> = LazyLock::new(Default::default);

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

fn snapshots_dir(app: &AppState) -> PathBuf {
    app.exports_dir.parent().map(|d| d.join("snapshots")).unwrap_or_else(|| app.exports_dir.join("../snapshots"))
}

async fn snap(snapshots: PathBuf, cwd: PathBuf) -> Option<(Repo, Result<String, String>)> {
    let repo = locate(&cwd).await?;
    let store = store_for(&snapshots, &repo);
    let tree = snapshot(&repo, &store).await;
    Some((repo, tree))
}

/// A path an edit/write tool call named, relative to the cwd when under it.
fn tool_path(cwd: &Path, v: &Value) -> Option<String> {
    let name = v.get("toolName").and_then(Value::as_str)?;
    if name != "edit" && name != "write" {
        return None;
    }
    let p = v.pointer("/args/path").and_then(Value::as_str)?.trim();
    if p.is_empty() {
        return None;
    }
    let p = p.strip_prefix('@').unwrap_or(p);
    Some(match Path::new(p).strip_prefix(cwd) {
        Ok(rel) => rel.to_string_lossy().to_string(),
        Err(_) => p.trim_start_matches("./").to_string(),
    })
}

/// Called for each record a chat's pi prints (main.rs): snapshots around
/// each turn and the edit/write paths in between.
pub fn observe(app: &Arc<AppState>, live: &Arc<Live>, ty: &str, v: &Value) {
    if live.kind != Kind::Chat {
        return;
    }
    match ty {
        "agent_start" => {
            let pi = Arc::as_ptr(live) as usize;
            let mut p = PENDING.lock().unwrap();
            if p.get(&live.key).is_some_and(|t| t.pi == pi) {
                return; // still the same turn
            }
            let cwd = PathBuf::from(&live.cwd);
            let before = tokio::spawn(snap(snapshots_dir(app), cwd.clone()));
            p.insert(live.key.clone(), Pending { pi, start: now_ms(), cwd, before, paths: BTreeSet::new() });
        }
        "tool_execution_start" => {
            if let Some(p) = PENDING.lock().unwrap().get_mut(&live.key) {
                if let Some(path) = tool_path(&p.cwd, v) {
                    p.paths.insert(path);
                }
            }
        }
        "agent_settled" => {
            let Some(p) = PENDING.lock().unwrap().remove(&live.key) else { return };
            let (app, live) = (app.clone(), live.clone());
            tokio::spawn(async move { settle(&app, &live, p).await });
        }
        _ => {}
    }
}

async fn settle(app: &Arc<AppState>, live: &Arc<Live>, p: Pending) {
    let end = now_ms();
    let before = p.before.await.ok().flatten();
    let snapshots = snapshots_dir(app);
    let mut turn = json!({"start": p.start, "end": end});
    let mut git = false;
    match before {
        Some((repo, Ok(before))) => {
            git = true;
            let store = store_for(&snapshots, &repo);
            match snapshot(&repo, &store).await {
                Ok(after) => {
                    let files = numstat(&repo, &store, &before, &after).await;
                    turn["before"] = json!(before);
                    turn["after"] = json!(after);
                    match files {
                        Ok(f) => turn["files"] = json!(f),
                        Err(e) => {
                            turn["files"] = json!([]);
                            turn["error"] = json!(e);
                        }
                    }
                }
                Err(e) => {
                    turn["files"] = json!([]);
                    turn["error"] = json!(e);
                }
            }
        }
        Some((_, Err(e))) => {
            git = true;
            turn["files"] = json!([]);
            turn["error"] = json!(e);
        }
        None => {
            let files: Vec<Changed> = p.paths.iter().map(|path| Changed { path: path.clone(), added: None, removed: None, from: None }).collect();
            turn["files"] = json!(files);
        }
    }
    invalidate(&p.cwd);
    // A new chat's file is known once pi has written it.
    let file = match live.session_file() {
        Some(f) => Some(f),
        None => {
            let _ = crate::rpc_internal(live, json!({"type": "get_state"})).await;
            live.session_file()
        }
    };
    let Some(file) = file else { return };
    let cwd = p.cwd.to_string_lossy().to_string();
    let saved = app.chat_state.update(&file, "files", |mut st| {
        if !st.is_object() {
            st = json!({"turns": []});
        }
        st["cwd"] = json!(cwd);
        st["git"] = json!(git);
        if st.get("base").is_none_or(Value::is_null) {
            if let Some(b) = turn.get("before") {
                st["base"] = b.clone();
            }
        }
        let turns = st["turns"].as_array_mut().map(std::mem::take).unwrap_or_default();
        let n = turns.last().and_then(|t| t["turn"].as_u64()).unwrap_or(0) + 1;
        let mut turns = turns;
        let mut t = turn.clone();
        t["turn"] = json!(n);
        turns.push(t);
        if turns.len() > TURNS_MAX {
            turns.drain(..turns.len() - TURNS_MAX);
        }
        st["turns"] = json!(turns);
        st
    });
    let Ok(st) = saved else { return };
    if let Some(t) = st["turns"].as_array().and_then(|a| a.last()) {
        let ev = json!({"type": "pocketpi_turn_files", "turn": t["turn"], "start": t["start"], "end": t["end"], "files": t["files"], "git": git, "error": t.get("error")});
        let _ = live.tx.send(Arc::from(ev.to_string().as_str()));
    }
}

#[derive(Deserialize)]
struct ChangesQuery {
    /// A live chat's key, or
    key: Option<String>,
    /// a session file.
    path: Option<String>,
    /// A turn number or "all" (since the chat opened): that turn's files,
    /// or with `file`, that file's diff.
    turn: Option<String>,
    file: Option<String>,
}

fn public_turn(t: &Value) -> Value {
    json!({"turn": t["turn"], "start": t["start"], "end": t["end"], "files": t.get("files").cloned().unwrap_or(json!([])), "error": t.get("error")})
}

async fn changes(State(app): State<Arc<AppState>>, Query(q): Query<ChangesQuery>) -> AppResult<Json<Value>> {
    let file = if let Some(p) = &q.path {
        let roots = [app.sessions_dir.clone(), app.chat_dir.clone()];
        exports::session_file_in(&roots, p).ok_or_else(|| err(StatusCode::NOT_FOUND, "no such session file"))?.to_string_lossy().to_string()
    } else if let Some(k) = &q.key {
        let live = crate::get_live(&app, k)?;
        match live.session_file() {
            Some(f) => f,
            None => return Ok(Json(json!({"git": Value::Null, "turns": []}))),
        }
    } else {
        return Err(err(StatusCode::BAD_REQUEST, "key or path is required"));
    };
    let st = app.chat_state.get(&file, "files");
    let turns: Vec<Value> = st["turns"].as_array().cloned().unwrap_or_default();
    let git = st["git"].as_bool();
    let Some(which) = q.turn.as_deref() else {
        return Ok(Json(json!({"git": git, "cwd": st.get("cwd"), "turns": turns.iter().map(public_turn).collect::<Vec<_>>()})));
    };
    // The trees to compare: one turn's, or the chat's first and last.
    let (a, b, recorded) = if which == "all" {
        let last = turns.iter().rev().find(|t| t["after"].is_string());
        (st["base"].as_str().map(String::from), last.and_then(|t| t["after"].as_str()).map(String::from), None)
    } else {
        let n: u64 = which.parse().map_err(|_| err(StatusCode::BAD_REQUEST, "bad turn"))?;
        let t = turns.iter().find(|t| t["turn"].as_u64() == Some(n)).ok_or_else(|| err(StatusCode::NOT_FOUND, "no such turn"))?;
        (t["before"].as_str().map(String::from), t["after"].as_str().map(String::from), Some(t.clone()))
    };
    if git != Some(true) || a.is_none() || b.is_none() {
        // Outside git: the paths the edit/write calls named, no diffs.
        if q.file.is_some() {
            return Err(err(StatusCode::NOT_FOUND, "no diff outside git"));
        }
        let files = match recorded {
            Some(t) => t["files"].clone(),
            None => {
                let mut seen = BTreeSet::new();
                let all: Vec<Value> = turns.iter().flat_map(|t| t["files"].as_array().cloned().unwrap_or_default()).filter(|f| seen.insert(f["path"].as_str().unwrap_or("").to_string())).collect();
                json!(all)
            }
        };
        return Ok(Json(json!({"turn": which, "files": files})));
    }
    let (a, b) = (a.unwrap(), b.unwrap());
    let cwd = st["cwd"].as_str().map(PathBuf::from).ok_or_else(|| err(StatusCode::NOT_FOUND, "no folder recorded"))?;
    let repo = locate(&cwd).await.ok_or_else(|| err(StatusCode::NOT_FOUND, "the folder is no longer a git repository"))?;
    let store = store_for(&snapshots_dir(&app), &repo);
    if let Some(f) = &q.file {
        let from = recorded
            .as_ref()
            .and_then(|t| t["files"].as_array().and_then(|fs| fs.iter().find(|x| x["path"] == f.as_str())).and_then(|x| x["from"].as_str()).map(String::from));
        let mut paths = vec![f.as_str()];
        if let Some(o) = from.as_deref() {
            paths.push(o);
        }
        let d = diff(&repo, &store, &a, &b, &paths).await.map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?;
        return Ok(Json(json!({"turn": which, "path": f, "diff": d})));
    }
    let files = match recorded {
        Some(t) => t["files"].clone(),
        None => json!(numstat(&repo, &store, &a, &b).await.map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e))?),
    };
    Ok(Json(json!({"turn": which, "files": files})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tmp(tag: &str) -> PathBuf {
        let n = std::time::SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let d = std::env::temp_dir().join(format!("pp-files-{tag}-{}-{n}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::canonicalize(d).unwrap()
    }

    #[test]
    fn resolve_refuses_escapes() {
        let base = tmp("resolve");
        let root = base.join("root");
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/a.rs"), "x").unwrap();
        std::fs::write(base.join("secret"), "s").unwrap();
        std::fs::create_dir_all(base.join("outside")).unwrap();
        symlink(base.join("secret"), root.join("leak")).unwrap();
        symlink(base.join("outside"), root.join("out-dir")).unwrap();
        symlink(root.join("src"), root.join("src-link")).unwrap();
        symlink(root.join("src/a.rs"), root.join("a-link")).unwrap();

        assert!(resolve(&root, "src/a.rs").is_ok());
        assert!(resolve(&root, "").is_ok());
        assert!(resolve(&root, ".").is_ok());
        assert_eq!(resolve(&root, "../secret").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "src/../../secret").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "src/../a.rs").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "/etc/passwd").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "a\0b").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "leak").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "out-dir").unwrap_err(), FileError::Outside);
        assert_eq!(resolve(&root, "nope").unwrap_err(), FileError::NotFound);
        // A link that stays inside is fine to list through...
        assert!(list_dir(&root, "src-link", 10).is_ok());
        assert_eq!(list_dir(&root, "out-dir", 10).unwrap_err(), FileError::Outside);
        // ...but a file that is itself a link is never read.
        assert_eq!(read_page(&root, "a-link", 1, 10, LIMITS).unwrap_err(), FileError::Symlink);
        assert_eq!(read_page(&root, "leak", 1, 10, LIMITS).unwrap_err(), FileError::Outside);
        assert_eq!(read_page(&root, "src", 1, 10, LIMITS).unwrap_err(), FileError::NotFile);
        // The listing shows links without following those that leave.
        let l = list_dir(&root, "", 100).unwrap();
        let get = |n: &str| l.entries.iter().find(|e| e.name == n).unwrap().clone();
        assert_eq!((get("leak").kind, get("leak").target), ("link", None));
        assert_eq!((get("out-dir").kind, get("out-dir").target), ("link", None));
        assert_eq!(get("src-link").target, Some("dir"));
        assert_eq!(get("a-link").target, Some("file"));
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn natural_order() {
        let mut v = vec!["file10", "File2", "file1", "b", "A", "a10b", "a9b", "file02"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["A", "a9b", "a10b", "b", "file1", "File2", "file02", "file10"]);
    }

    #[test]
    fn list_sorts_folders_first_and_caps() {
        let root = tmp("list");
        for f in ["b.txt", "a10.txt", "a2.txt", ".env"] {
            std::fs::write(root.join(f), "hello").unwrap();
        }
        for d in ["zeta", "Alpha"] {
            std::fs::create_dir(root.join(d)).unwrap();
        }
        let l = list_dir(&root, "", 100).unwrap();
        let names: Vec<_> = l.entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, ["Alpha", "zeta", ".env", "a2.txt", "a10.txt", "b.txt"]);
        assert!(!l.truncated);
        assert_eq!(l.entries[3].size, 5);
        assert_eq!(l.entries[0].kind, "dir");
        let l = list_dir(&root, "", 3).unwrap();
        assert_eq!(l.entries.len(), 3);
        assert!(l.truncated);
        assert_eq!(list_dir(&root, "b.txt", 3).unwrap_err(), FileError::NotDir);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn read_pages_and_refuses_binary_and_huge() {
        let root = tmp("read");
        let text: String = (1..=25).map(|i| format!("line {i}\r\n")).collect();
        std::fs::write(root.join("t.txt"), &text).unwrap();
        let lim = ReadLimits { lines: 10, bytes: 1024, file: 4096 };
        let p = read_page(&root, "t.txt", 1, 100, lim).unwrap();
        assert_eq!(p.lines.len(), 10);
        assert_eq!(p.lines[0], "line 1");
        assert_eq!(p.next, Some(11));
        let p = read_page(&root, "t.txt", 21, 10, lim).unwrap();
        assert_eq!(p.lines, ["line 21", "line 22", "line 23", "line 24", "line 25"]);
        assert_eq!(p.next, None);
        assert_eq!(p.version, format!("{}-{}", p.mtime, text.len()));
        // The byte cap ends a page early (each line is 8-9 bytes).
        let p = read_page(&root, "t.txt", 1, 10, ReadLimits { bytes: 30, ..lim }).unwrap();
        assert_eq!(p.lines.len(), 3);
        assert_eq!(p.next, Some(4));
        // Past the end: an empty last page.
        let p = read_page(&root, "t.txt", 99, 10, lim).unwrap();
        assert!(p.lines.is_empty() && p.next.is_none());
        // A file with no final newline keeps its last line.
        std::fs::write(root.join("n.txt"), "a\nb").unwrap();
        assert_eq!(read_page(&root, "n.txt", 1, 10, lim).unwrap().lines, ["a", "b"]);

        std::fs::write(root.join("bin"), b"abc\0def").unwrap();
        assert_eq!(read_page(&root, "bin", 1, 10, lim).unwrap_err(), FileError::NotText);
        std::fs::write(root.join("latin1"), b"caf\xe9\n").unwrap();
        assert_eq!(read_page(&root, "latin1", 1, 10, lim).unwrap_err(), FileError::NotText);
        std::fs::write(root.join("big"), "x".repeat(5000)).unwrap();
        assert_eq!(read_page(&root, "big", 1, 10, lim).unwrap_err(), FileError::TooLarge);
        std::fs::write(root.join("longline"), format!("{}\nshort\n", "y".repeat(2000))).unwrap();
        assert_eq!(read_page(&root, "longline", 1, 10, lim).unwrap_err(), FileError::TooLarge);
        assert_eq!(read_page(&root, "longline", 2, 10, lim).unwrap().lines, ["short"]);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn media_types() {
        assert_eq!(media_type("a.PNG"), Some("image/png"));
        assert_eq!(media_type("doc.pdf"), Some("application/pdf"));
        assert_eq!(media_type("x.svg"), Some("image/svg+xml"));
        assert_eq!(media_type("index.html"), None);
        assert_eq!(media_type("Makefile"), None);
    }

    fn c(path: &str, kind: &'static str) -> Candidate {
        Candidate { path: path.into(), kind }
    }

    #[test]
    fn search_ranks_like_dsh() {
        let idx = vec![
            c("src", "dir"),
            c("src/main.rs", "file"),
            c("src/files.rs", "file"),
            c("web/files.js", "file"),
            c("docs/profile.md", "file"),
            c("web/app.js", "file"),
            c("files", "dir"),
            c(".github/ci.yml", "file"),
        ];
        let paths = |v: Vec<Candidate>| v.into_iter().map(|c| c.path).collect::<Vec<_>>();
        // Exact name (a folder's bonus first), then prefix, then substring.
        assert_eq!(paths(rank(&idx, "files", 10)), ["files", "src/files.rs", "web/files.js"]);
        let r = paths(rank(&idx, "main", 10));
        assert_eq!(r, ["src/main.rs"]);
        // Path substring beats a subsequence.
        let r = paths(rank(&idx, "web/a", 10));
        assert_eq!(r[0], "web/app.js");
        // Subsequence: "fjs" matches web/files.js.
        assert!(paths(rank(&idx, "fjs", 10)).contains(&"web/files.js".to_string()));
        assert!(rank(&idx, "zzz", 10).is_empty());
        // Dot paths only for dot queries.
        let root = tmp("search");
        assert!(!paths(search_in(&root, &idx, "ci", 10)).contains(&".github/ci.yml".to_string()));
        assert_eq!(paths(search_in(&root, &idx, ".gi", 10)), [".github/ci.yml"]);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn index_skips_excluded_and_symlinks_and_lists_folders() {
        let root = tmp("index");
        std::fs::create_dir_all(root.join("src/deep")).unwrap();
        std::fs::create_dir_all(root.join("node_modules/x")).unwrap();
        std::fs::create_dir_all(root.join("target/debug")).unwrap();
        std::fs::write(root.join("src/deep/z.rs"), "").unwrap();
        std::fs::write(root.join("README.md"), "").unwrap();
        std::fs::write(root.join(".hidden"), "").unwrap();
        symlink("/etc", root.join("etc-link")).unwrap();
        let ix = build_index(&root, 100);
        let paths: Vec<_> = ix.iter().map(|c| c.path.as_str()).collect();
        assert_eq!(paths, [".hidden", "README.md", "src", "src/deep", "src/deep/z.rs"]);
        assert_eq!(build_index(&root, 2).len(), 2);
        // A slash lists that folder live.
        let r = search_in(&root, &ix, "src/", 10);
        assert_eq!(r, vec![c("src/deep", "dir")]);
        let r = search_in(&root, &ix, "src/deep/z", 10);
        assert_eq!(r, vec![c("src/deep/z.rs", "file")]);
        assert!(search_in(&root, &ix, "etc-link/", 10).is_empty());
        assert!(search_in(&root, &ix, "../", 10).is_empty());
        assert!(search_in(&root, &ix, "node_modules/", 10).is_empty());
        let top: Vec<_> = search_in(&root, &ix, "", 10).into_iter().map(|c| c.path).collect();
        assert_eq!(top, ["src", "README.md"]);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn prefix_paths() {
        assert_eq!(from_prefix("", "a/b.rs"), "a/b.rs");
        assert_eq!(from_prefix("sub/", "sub/x.rs"), "x.rs");
        assert_eq!(from_prefix("sub/dir/", "top.rs"), "../../top.rs");
        assert_eq!(to_top("sub/dir/", "../../top.rs").as_deref(), Some("top.rs"));
        assert_eq!(to_top("sub/", "x.rs").as_deref(), Some("sub/x.rs"));
        assert_eq!(to_top("", "../x"), None);
        assert_eq!(to_top("sub/", "../../x"), None);
    }

    #[test]
    fn numstat_parsing() {
        let out = b"3\t1\tsrc/a.rs\0-\t-\timg.png\x002\t0\t\0old.rs\0new.rs\0";
        let r = parse_numstat(out);
        assert_eq!(r[0], (Some(3), Some(1), "src/a.rs".to_string(), None));
        assert_eq!(r[1], (None, None, "img.png".to_string(), None));
        assert_eq!(r[2], (Some(2), Some(0), "new.rs".to_string(), Some("old.rs".to_string())));
    }

    #[test]
    fn tool_paths() {
        let cwd = Path::new("/p");
        assert_eq!(tool_path(cwd, &json!({"toolName": "edit", "args": {"path": "/p/src/a.rs"}})).as_deref(), Some("src/a.rs"));
        assert_eq!(tool_path(cwd, &json!({"toolName": "write", "args": {"path": "./b.md"}})).as_deref(), Some("b.md"));
        assert_eq!(tool_path(cwd, &json!({"toolName": "write", "args": {"path": "/elsewhere/c"}})).as_deref(), Some("/elsewhere/c"));
        assert_eq!(tool_path(cwd, &json!({"toolName": "bash", "args": {"command": "ls"}})), None);
    }

    fn git(dir: &Path, args: &[&str]) -> String {
        let o = std::process::Command::new("git")
            .current_dir(dir)
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .env_remove("GIT_DIR")
            .env_remove("GIT_INDEX_FILE")
            .output()
            .unwrap();
        assert!(o.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).to_string()
    }

    fn tree_of(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = walk(dir).into_iter().map(|p| p.strip_prefix(dir).unwrap().to_string_lossy().to_string()).collect();
        v.sort();
        v
    }
    fn walk(d: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for e in std::fs::read_dir(d).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                out.extend(walk(&p));
            } else {
                out.push(p);
            }
        }
        out
    }

    #[tokio::test]
    async fn snapshots_diff_without_touching_the_repo() {
        let base = tmp("git");
        let repo_dir = base.join("repo");
        std::fs::create_dir_all(repo_dir.join("sub")).unwrap();
        git(&repo_dir, &["init", "-q", "-b", "main"]);
        std::fs::write(repo_dir.join("a.txt"), "one\ntwo\n").unwrap();
        std::fs::write(repo_dir.join("sub/b.txt"), "b\n").unwrap();
        std::fs::write(repo_dir.join(".gitignore"), "ignored.log\n").unwrap();
        git(&repo_dir, &["add", "-A"]);
        git(&repo_dir, &["commit", "-q", "-m", "init"]);
        // Something staged, so the user's index differs from HEAD.
        std::fs::write(repo_dir.join("staged.txt"), "s\n").unwrap();
        git(&repo_dir, &["add", "staged.txt"]);

        let index_before = std::fs::read(repo_dir.join(".git/index")).unwrap();
        let objects_before = tree_of(&repo_dir.join(".git/objects"));
        let status_before = git(&repo_dir, &["status", "--porcelain"]);

        // From a subfolder, like a chat whose cwd is inside the repository.
        let cwd = repo_dir.join("sub");
        let repo = locate(&cwd).await.expect("a repository");
        assert_eq!(repo.prefix, "sub/");
        let store = store_for(&base.join("snapshots"), &repo);
        let t0 = snapshot(&repo, &store).await.unwrap();
        // The turn: edit, add (untracked), delete, and an ignored file.
        std::fs::write(repo_dir.join("a.txt"), "one\n2\nthree\n").unwrap();
        std::fs::write(repo_dir.join("sub/new.txt"), "new\n").unwrap();
        std::fs::remove_file(repo_dir.join("sub/b.txt")).unwrap();
        std::fs::write(repo_dir.join("ignored.log"), "noise\n").unwrap();
        let t1 = snapshot(&repo, &store).await.unwrap();
        assert_ne!(t0, t1);
        // Nothing changed: the same tree.
        assert_eq!(snapshot(&repo, &store).await.unwrap(), t1);

        let mut files = numstat(&repo, &store, &t0, &t1).await.unwrap();
        files.sort_by(|a, b| a.path.cmp(&b.path));
        let got: Vec<_> = files.iter().map(|f| (f.path.as_str(), f.added, f.removed)).collect();
        assert_eq!(got, [("../a.txt", Some(2), Some(1)), ("b.txt", Some(0), Some(1)), ("new.txt", Some(1), Some(0))]);
        assert!(numstat(&repo, &store, &t1, &t1).await.unwrap().is_empty());
        let d = diff(&repo, &store, &t0, &t1, &["../a.txt"]).await.unwrap();
        assert!(d.contains("-two") && d.contains("+2") && d.contains("+three"), "{d}");
        assert!(!d.contains("new.txt"));
        assert!(diff(&repo, &store, &t0, &t1, &["../../escape"]).await.is_err());

        // The user's repository: same index, same objects, same status
        // (apart from the files the "turn" changed).
        assert_eq!(std::fs::read(repo_dir.join(".git/index")).unwrap(), index_before);
        assert_eq!(tree_of(&repo_dir.join(".git/objects")), objects_before);
        let status_after = git(&repo_dir, &["status", "--porcelain"]);
        assert!(status_before.contains("A  staged.txt") && status_after.contains("A  staged.txt"));
        // New blobs went to the private store.
        assert!(!tree_of(&store.join("objects")).is_empty());
        // No leftover scratch indexes.
        assert!(std::fs::read_dir(&store).unwrap().flatten().all(|e| e.file_name() == "objects"));

        assert!(locate(&base).await.is_none());
        let _ = std::fs::remove_dir_all(base);
    }
}
