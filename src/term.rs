//! Terminal panel (docs/dsh-features-plan.md §3.6): a login shell in a pty,
//! started in a chat's or a project's folder, streamed over a WebSocket.
//!
//! - `GET /api/term/ws?root=&id=&cols=&rows=` attaches to terminal `id`, or
//!   starts a new one in `root` when `id` is missing or gone. The first text
//!   frame is `{type:"hello", id, root, new}`, then the replay ring (binary),
//!   then live output as binary frames. Client text frames are
//!   `{type:"input",data}`, `{type:"resize",cols,rows}` and `{type:"close"}`.
//!   The server may send `{type:"reset"}` (a replay follows; the client lagged
//!   behind), `{type:"exit",code,signal}` and `{type:"error",message}`.
//! - `GET /api/term/list` and `POST /api/term/close {id}`.
//!
//! A WebSocket upgrade is a GET, so `guard` doesn't ask it for `X-Pocketpi`;
//! instead the `Origin` must name the same host as `Host`, which a cross-site
//! page can't fake. `root` must be a live chat's cwd or a known project
//! folder, never any path a client picks.
//!
//! Terminals live in a process-wide registry (not `AppState`, so the rest of
//! the server doesn't change): at most 8, each with a 256 KiB output ring
//! replayed on reattach, closed after 2 h with nothing attached. Closing one
//! hangs up its whole process group.

use crate::{AppResult, AppState, Kind, err, projects, sessions};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{
        Query, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    io::{Read, Write},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use tokio::sync::broadcast;

/// At most this many terminals at once (alive, attached or not).
pub const MAX_TERMS: usize = 8;
/// Output kept per terminal and sent again when a client reattaches.
pub const REPLAY_BYTES: usize = 256 * 1024;
/// A terminal with nothing attached for this long is closed.
pub const IDLE_CLOSE: Duration = Duration::from_secs(2 * 60 * 60);
/// The xterm.js build under web/vendor/; it's in the asset paths so they can
/// be cached for good.
const XTERM_DIR: &str = "/vendor/xterm-5.5.0";

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/term.js", get(|| async { asset(include_bytes!("../web/term.js"), "text/javascript; charset=utf-8", false) }))
        .route(&format!("{XTERM_DIR}/xterm.js"), get(|| async { asset(include_bytes!("../web/vendor/xterm/xterm.js"), "text/javascript; charset=utf-8", true) }))
        .route(&format!("{XTERM_DIR}/addon-fit.js"), get(|| async { asset(include_bytes!("../web/vendor/xterm/addon-fit.js"), "text/javascript; charset=utf-8", true) }))
        .route(&format!("{XTERM_DIR}/xterm.css"), get(|| async { asset(include_bytes!("../web/vendor/xterm/xterm.css"), "text/css; charset=utf-8", true) }))
        .route("/api/term/ws", get(ws))
        .route("/api/term/list", get(list))
        .route("/api/term/close", post(close))
}

fn asset(body: &'static [u8], ctype: &'static str, immutable: bool) -> Response {
    let mut res = body.into_response();
    let hs = res.headers_mut();
    hs.insert(header::CONTENT_TYPE, HeaderValue::from_static(ctype));
    let cache = if immutable { "public, max-age=31536000, immutable" } else { "no-cache" };
    hs.insert(header::CACHE_CONTROL, HeaderValue::from_static(cache));
    res
}

// ---------------------------------------------------------------- checks

/// True when `origin` (`scheme://host[:port]`) names the same host and port
/// as the `Host` header. Missing, `null` or malformed origins never match.
pub fn origin_matches_host(origin: Option<&str>, host: Option<&str>) -> bool {
    let (Some(origin), Some(host)) = (origin, host) else { return false };
    let Some((scheme, rest)) = origin.trim().split_once("://") else { return false };
    let default_port = match scheme.to_ascii_lowercase().as_str() {
        "http" => ":80",
        "https" => ":443",
        _ => return false,
    };
    if rest.is_empty() || rest.contains(['/', '?', '#', '@']) || host.trim().is_empty() {
        return false;
    }
    let norm = |s: &str| {
        let s = s.trim().to_ascii_lowercase();
        s.strip_suffix(default_port).map(str::to_string).unwrap_or(s)
    };
    norm(rest) == norm(host)
}

fn origin_ok(h: &HeaderMap) -> bool {
    let get = |name| h.get(name).and_then(|v: &HeaderValue| v.to_str().ok());
    origin_matches_host(get(header::ORIGIN), get(header::HOST))
}

/// `raw` as a canonical folder, when it is exactly one of the `known` folders
/// (live chats' cwds and project folders) and still exists.
pub fn check_root(raw: &str, known: &[String]) -> Result<String, String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err("root is required".into());
    }
    if !raw.starts_with('/') || !known.iter().any(|k| k == raw) {
        return Err(format!("not a chat or project folder: {raw}"));
    }
    let dir = std::fs::canonicalize(raw).map_err(|_| format!("folder not found: {raw}"))?;
    if !dir.is_dir() {
        return Err(format!("not a folder: {raw}"));
    }
    Ok(dir.to_string_lossy().into_owned())
}

/// A terminal root: a live chat's cwd, a pinned project, or the cwd of a
/// chat on disk (an auto project). The Chat tab's folder and workflow
/// worktrees aren't projects.
pub(crate) async fn resolve_root(app: &Arc<AppState>, raw: &str) -> AppResult<String> {
    let raw = raw.trim();
    let mut known: Vec<String> = app
        .live
        .lock()
        .unwrap()
        .values()
        .filter(|l| l.kind == Kind::Chat)
        .map(|l| l.cwd.clone())
        .collect();
    known.extend(projects::load(&app.projects_path).pinned.into_iter().map(|p| p.path));
    if !known.iter().any(|k| k == raw) {
        let app2 = app.clone();
        let scanned = tokio::task::spawn_blocking(move || sessions::scan(&app2.sessions_dir, &app2.meta_cache))
            .await
            .unwrap_or_default();
        let wt = app.engine.worktrees_dir.to_string_lossy().into_owned();
        let chat_dir = app.chat_dir.to_string_lossy().into_owned();
        known.extend(scanned.into_iter().map(|s| s.cwd).filter(|c| !c.starts_with(&wt) && *c != chat_dir));
    }
    check_root(raw, &known).map_err(|e| err(StatusCode::BAD_REQUEST, e))
}

// ---------------------------------------------------------------- replay ring

/// The last `cap` bytes of output.
pub struct Ring {
    buf: VecDeque<u8>,
    cap: usize,
}

impl Ring {
    pub fn new(cap: usize) -> Self {
        Ring { buf: VecDeque::with_capacity(cap.min(64 * 1024)), cap }
    }
    pub fn push(&mut self, b: &[u8]) {
        if b.len() >= self.cap {
            self.buf.clear();
            self.buf.extend(&b[b.len() - self.cap..]);
            return;
        }
        let over = (self.buf.len() + b.len()).saturating_sub(self.cap);
        self.buf.drain(..over);
        self.buf.extend(b);
    }
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.buf.len()
    }
    /// The kept bytes, without a cut UTF-8 sequence at the start.
    pub fn snapshot(&self) -> Vec<u8> {
        let skip = self.buf.iter().take(3).take_while(|b| (**b & 0xC0) == 0x80).count();
        self.buf.iter().skip(skip).copied().collect()
    }
}

// ---------------------------------------------------------------- terminals

#[derive(Clone, Debug)]
enum Out {
    Data(Bytes),
    Exit(Exit),
}

/// How a shell ended: its exit code, or the signal that ended it.
#[derive(Clone, Debug, PartialEq)]
pub struct Exit {
    pub code: u32,
    pub signal: Option<String>,
}

impl Exit {
    fn to_json(&self) -> Value {
        json!({ "type": "exit", "code": self.code, "signal": self.signal })
    }
}

/// Output state, behind one lock so attaching (snapshot + subscribe) never
/// misses or repeats a chunk, and never misses the exit.
struct OutState {
    ring: Ring,
    exit: Option<Exit>,
}

pub struct Term {
    pub id: String,
    pub root: String,
    pid: Option<i32>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    input: Mutex<mpsc::Sender<Vec<u8>>>,
    out: Mutex<OutState>,
    tx: broadcast::Sender<Out>,
    attached: AtomicUsize,
    idle_since: Mutex<Instant>,
}

impl Term {
    fn write(&self, data: Vec<u8>) {
        if !data.is_empty() {
            let _ = self.input.lock().unwrap().send(data);
        }
    }
    fn resize(&self, cols: u16, rows: u16) {
        let size = PtySize { cols: cols.clamp(2, 1000), rows: rows.clamp(1, 500), pixel_width: 0, pixel_height: 0 };
        let _ = self.master.lock().unwrap().resize(size);
    }
    fn attach(&self) {
        self.attached.fetch_add(1, Ordering::SeqCst);
    }
    fn detach(&self) {
        if self.attached.fetch_sub(1, Ordering::SeqCst) == 1 {
            *self.idle_since.lock().unwrap() = Instant::now();
        }
    }
    pub fn exited(&self) -> Option<Exit> {
        self.out.lock().unwrap().exit.clone()
    }
    /// Hangs up the shell's process group, then kills it if it's still there
    /// after 3 s. The waiter thread frees the slot once the shell is gone.
    pub fn kill(self: &Arc<Self>) {
        let Some(pid) = self.pid else { return };
        signal_group(pid, libc::SIGHUP);
        let me = self.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(3));
            if me.exited().is_none() {
                signal_group(pid, libc::SIGKILL);
            }
        });
    }
}

fn signal_group(pid: i32, sig: i32) {
    // Never 0 or 1 (the caller's own group, or init).
    if pid > 1 {
        unsafe {
            libc::killpg(pid, sig);
        }
    }
}

/// What to run in a terminal.
pub struct Shell {
    pub program: String,
    pub args: Vec<String>,
}

impl Shell {
    /// The user's `$SHELL` as a login shell (for the PATH a service lacks),
    /// or `/bin/sh`.
    fn user() -> Self {
        let program = std::env::var("SHELL")
            .ok()
            .filter(|s| s.starts_with('/') && std::path::Path::new(s).is_file())
            .unwrap_or_else(|| "/bin/sh".into());
        Shell { program, args: vec!["-l".into()] }
    }
}

pub struct Terms {
    map: Mutex<HashMap<String, Arc<Term>>>,
    max: usize,
}

static TERMS: LazyLock<Arc<Terms>> = LazyLock::new(|| Arc::new(Terms::new(MAX_TERMS)));

fn new_id() -> String {
    let mut b = [0u8; 16];
    let ok = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).is_ok();
    if !ok {
        let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
        b = (n ^ ((std::process::id() as u128) << 64)).to_le_bytes();
    }
    b.iter().map(|x| format!("{x:02x}")).collect()
}

impl Terms {
    pub fn new(max: usize) -> Self {
        Terms { map: Mutex::new(HashMap::new()), max }
    }
    pub fn get(&self, id: &str) -> Option<Arc<Term>> {
        self.map.lock().unwrap().get(id).cloned()
    }
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.map.lock().unwrap().len()
    }
    fn all(&self) -> Vec<Arc<Term>> {
        self.map.lock().unwrap().values().cloned().collect()
    }

    /// Starts `shell` in `root` (already checked). Blocking: call it off the
    /// async runtime.
    pub fn spawn(self: &Arc<Self>, root: &str, shell: &Shell, cols: u16, rows: u16) -> Result<Arc<Term>, String> {
        let mut map = self.map.lock().unwrap();
        if map.len() >= self.max {
            return Err(format!("At most {} terminals can be open; close one first.", self.max));
        }
        let size = PtySize { cols: cols.clamp(2, 1000), rows: rows.clamp(1, 500), pixel_width: 0, pixel_height: 0 };
        let pair = native_pty_system().openpty(size).map_err(|e| format!("couldn't open a pty: {e}"))?;
        let mut cmd = CommandBuilder::new(&shell.program);
        cmd.args(&shell.args);
        cmd.cwd(root);
        cmd.env("TERM", "xterm-256color");
        cmd.env("COLORTERM", "truecolor");
        let mut child = pair.slave.spawn_command(cmd).map_err(|e| format!("couldn't start {}: {e}", shell.program))?;
        // Only the shell holds the slave now, so output ends when it's gone.
        drop(pair.slave);
        let started = (|| Ok::<_, String>((pair.master.try_clone_reader().map_err(|e| e.to_string())?, pair.master.take_writer().map_err(|e| e.to_string())?)))();
        let pid = child.process_id().map(|p| p as i32);
        let (mut reader, mut writer) = match started {
            Ok(rw) => rw,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e);
            }
        };
        let (in_tx, in_rx) = mpsc::channel::<Vec<u8>>();
        let term = Arc::new(Term {
            id: new_id(),
            root: root.to_string(),
            pid,
            master: Mutex::new(pair.master),
            input: Mutex::new(in_tx),
            out: Mutex::new(OutState { ring: Ring::new(REPLAY_BYTES), exit: None }),
            tx: broadcast::channel(1024).0,
            attached: AtomicUsize::new(0),
            idle_since: Mutex::new(Instant::now()),
        });
        map.insert(term.id.clone(), term.clone());
        drop(map);

        // Input, in order, without blocking the WebSocket on a busy shell.
        std::thread::spawn(move || {
            for data in in_rx {
                if writer.write_all(&data).and_then(|_| writer.flush()).is_err() {
                    break;
                }
            }
        });
        // Output into the ring and out to every attached client.
        let (done_tx, done_rx) = mpsc::channel::<()>();
        let t = term.clone();
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 32 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let mut o = t.out.lock().unwrap();
                        o.ring.push(&buf[..n]);
                        let _ = t.tx.send(Out::Data(Bytes::copy_from_slice(&buf[..n])));
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(_) => break,
                }
            }
            let _ = done_tx.send(());
        });
        // The shell's exit: hang up what it left in its group, tell the
        // clients, free the slot.
        let (t, terms) = (term.clone(), self.clone());
        std::thread::spawn(move || {
            let exit = match child.wait() {
                Ok(s) => Exit { code: s.exit_code(), signal: s.signal().map(str::to_string) },
                Err(_) => Exit { code: 255, signal: None },
            };
            if let Some(pid) = t.pid {
                signal_group(pid, libc::SIGHUP);
            }
            // Let the last output through before the exit message.
            let _ = done_rx.recv_timeout(Duration::from_millis(500));
            {
                let mut o = t.out.lock().unwrap();
                o.exit = Some(exit.clone());
                let _ = t.tx.send(Out::Exit(exit));
            }
            terms.map.lock().unwrap().remove(&t.id);
        });
        Ok(term)
    }

    /// Terminals with nothing attached for longer than `limit`.
    pub fn idle(&self, limit: Duration) -> Vec<Arc<Term>> {
        self.all()
            .into_iter()
            .filter(|t| t.attached.load(Ordering::SeqCst) == 0 && t.idle_since.lock().unwrap().elapsed() >= limit)
            .collect()
    }
}

/// Closes idle terminals; started with the first terminal.
fn start_reaper() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        tokio::spawn(async {
            loop {
                tokio::time::sleep(Duration::from_secs(60)).await;
                for t in TERMS.idle(IDLE_CLOSE) {
                    eprintln!("closing idle terminal {}", t.id);
                    t.kill();
                }
            }
        });
    });
}

// ---------------------------------------------------------------- routes

#[derive(Deserialize)]
struct WsQuery {
    #[serde(default)]
    root: String,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum ClientMsg {
    Input { data: String },
    Resize { cols: u16, rows: u16 },
    Close,
}

async fn ws(State(app): State<Arc<AppState>>, headers: HeaderMap, Query(q): Query<WsQuery>, upgrade: WebSocketUpgrade) -> Response {
    if !origin_ok(&headers) {
        return (StatusCode::FORBIDDEN, "Origin must match Host").into_response();
    }
    let root = match resolve_root(&app, &q.root).await {
        Ok(r) => r,
        Err(e) => return e.into_response(),
    };
    start_reaper();
    let id = q.id.filter(|s| !s.is_empty());
    let (cols, rows) = (q.cols.unwrap_or(80), q.rows.unwrap_or(24));
    upgrade.max_message_size(1 << 20).on_upgrade(move |sock| session(sock, TERMS.clone(), root, id, cols, rows))
}

async fn send_json(sock: &mut WebSocket, v: Value) -> bool {
    sock.send(Message::Text(v.to_string().into())).await.is_ok()
}

async fn session(mut sock: WebSocket, terms: Arc<Terms>, root: String, id: Option<String>, cols: u16, rows: u16) {
    let (term, fresh) = match id.as_deref().and_then(|i| terms.get(i)) {
        Some(t) => (t, false),
        None => {
            let t2 = terms.clone();
            match tokio::task::spawn_blocking(move || t2.spawn(&root, &Shell::user(), cols, rows)).await {
                Ok(Ok(t)) => (t, true),
                Ok(Err(e)) => {
                    send_json(&mut sock, json!({ "type": "error", "message": e })).await;
                    let _ = sock.send(Message::Close(None)).await;
                    return;
                }
                Err(e) => {
                    send_json(&mut sock, json!({ "type": "error", "message": e.to_string() })).await;
                    return;
                }
            }
        }
    };
    let snapshot = |t: &Term| {
        let o = t.out.lock().unwrap();
        (o.ring.snapshot(), t.tx.subscribe(), o.exit.clone())
    };
    let (replay, mut rx, exited) = snapshot(&term);
    term.attach();
    let hello = json!({ "type": "hello", "id": term.id, "root": term.root, "new": fresh });
    let mut ok = send_json(&mut sock, hello).await;
    if ok && !replay.is_empty() {
        ok = sock.send(Message::Binary(replay.into())).await.is_ok();
    }
    if let (true, Some(exit)) = (ok, exited) {
        send_json(&mut sock, exit.to_json()).await;
        ok = false;
    }
    let mut ping = tokio::time::interval(Duration::from_secs(30));
    ping.tick().await;
    while ok {
        tokio::select! {
            m = sock.recv() => match m {
                Some(Ok(Message::Text(t))) => match serde_json::from_str::<ClientMsg>(&t) {
                    Ok(ClientMsg::Input { data }) => term.write(data.into_bytes()),
                    Ok(ClientMsg::Resize { cols, rows }) => term.resize(cols, rows),
                    Ok(ClientMsg::Close) => term.kill(),
                    Err(_) => {}
                },
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                Some(Ok(_)) => {}
            },
            o = rx.recv() => match o {
                Ok(Out::Data(b)) => ok = sock.send(Message::Binary(b)).await.is_ok(),
                Ok(Out::Exit(exit)) => {
                    send_json(&mut sock, exit.to_json()).await;
                    break;
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    // Too far behind to patch up: start the screen over.
                    let (replay, rx2, _) = snapshot(&term);
                    rx = rx2;
                    ok = send_json(&mut sock, json!({ "type": "reset" })).await
                        && sock.send(Message::Binary(replay.into())).await.is_ok();
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            _ = ping.tick() => ok = sock.send(Message::Ping(Bytes::new())).await.is_ok(),
        }
    }
    term.detach();
    let _ = sock.send(Message::Close(None)).await;
}

async fn list() -> Json<Value> {
    let terms: Vec<Value> = TERMS
        .all()
        .iter()
        .map(|t| json!({ "id": t.id, "root": t.root, "attached": t.attached.load(Ordering::SeqCst), "exited": t.exited().is_some() }))
        .collect();
    Json(json!({ "terms": terms, "max": MAX_TERMS }))
}

#[derive(Deserialize)]
struct CloseReq {
    id: String,
}

async fn close(Json(req): Json<CloseReq>) -> AppResult<Json<Value>> {
    let t = TERMS.get(&req.id).ok_or_else(|| err(StatusCode::NOT_FOUND, "no such terminal"))?;
    t.kill();
    Ok(Json(json!({ "ok": true })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin_must_match_host() {
        assert!(origin_matches_host(Some("http://127.0.0.1:3457"), Some("127.0.0.1:3457")));
        assert!(origin_matches_host(Some("https://arlo.tail1234.ts.net"), Some("arlo.tail1234.ts.net")));
        assert!(origin_matches_host(Some("https://Arlo.ts.net"), Some("arlo.ts.net:443")));
        assert!(origin_matches_host(Some("http://localhost"), Some("localhost:80")));
        assert!(!origin_matches_host(None, Some("127.0.0.1:3457")));
        assert!(!origin_matches_host(Some("http://127.0.0.1:3457"), None));
        assert!(!origin_matches_host(Some("null"), Some("127.0.0.1:3457")));
        assert!(!origin_matches_host(Some("http://evil.example"), Some("127.0.0.1:3457")));
        assert!(!origin_matches_host(Some("http://127.0.0.1:9999"), Some("127.0.0.1:3457")));
        assert!(!origin_matches_host(Some("https://localhost:80"), Some("localhost")));
        assert!(!origin_matches_host(Some("http://127.0.0.1:3457/x"), Some("127.0.0.1:3457")));
        assert!(!origin_matches_host(Some("http://a@127.0.0.1:3457"), Some("127.0.0.1:3457")));
        assert!(!origin_matches_host(Some("file://"), Some("")));
        assert!(!origin_matches_host(Some("chrome-extension://abc"), Some("abc")));
    }

    #[test]
    fn root_must_be_known_and_exist() {
        let dir = std::env::temp_dir().join(format!("pp-term-root-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("sub")).unwrap();
        let d = dir.to_string_lossy().to_string();
        let canon = std::fs::canonicalize(&dir).unwrap().to_string_lossy().to_string();
        let known = vec![d.clone(), "/nonexistent/pp-term-gone".to_string()];
        assert_eq!(check_root(&d, &known).unwrap(), canon);
        assert_eq!(check_root(&format!(" {d} "), &known).unwrap(), canon);
        assert!(check_root("", &known).is_err());
        assert!(check_root(&format!("{d}/sub"), &known).is_err());
        assert!(check_root(&format!("{d}/../"), &known).is_err());
        assert!(check_root("/", &known).is_err());
        assert!(check_root("relative", &["relative".to_string()]).is_err());
        assert!(check_root("/nonexistent/pp-term-gone", &known).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn ring_keeps_the_last_bytes() {
        let mut r = Ring::new(8);
        r.push(b"abc");
        assert_eq!(r.snapshot(), b"abc");
        r.push(b"defgh");
        assert_eq!(r.snapshot(), b"abcdefgh");
        r.push(b"ij");
        assert_eq!(r.len(), 8);
        assert_eq!(r.snapshot(), b"cdefghij");
        r.push(b"0123456789xyz");
        assert_eq!(r.snapshot(), b"56789xyz");
        // A cut multi-byte character at the start is dropped.
        let mut r = Ring::new(4);
        r.push("aé€".as_bytes()); // 1 + 2 + 3 bytes: keeps the last 4 = é's 2nd byte + €
        assert_eq!(r.snapshot(), "€".as_bytes());
        let mut r = Ring::new(REPLAY_BYTES);
        for _ in 0..100 {
            r.push(&[b'x'; 10_000]);
        }
        assert_eq!(r.len(), REPLAY_BYTES);
    }

    fn sh() -> Shell {
        Shell { program: "/bin/sh".into(), args: vec![] }
    }

    fn tmp_root() -> String {
        std::env::temp_dir().to_string_lossy().into_owned()
    }

    /// Waits for `pred` on the ring's contents, up to 10 s.
    fn wait_for(t: &Term, pred: impl Fn(&str) -> bool) -> String {
        let start = Instant::now();
        loop {
            let s = String::from_utf8_lossy(&t.out.lock().unwrap().ring.snapshot()).into_owned();
            if pred(&s) || start.elapsed() > Duration::from_secs(10) {
                return s;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn wait_gone(terms: &Terms, id: &str) -> bool {
        let start = Instant::now();
        while terms.get(id).is_some() {
            if start.elapsed() > Duration::from_secs(10) {
                return false;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        true
    }

    #[test]
    fn shell_runs_and_exits() {
        let terms = Arc::new(Terms::new(MAX_TERMS));
        let t = terms.spawn(&tmp_root(), &sh(), 80, 24).unwrap();
        let mut rx = t.tx.subscribe();
        t.write(b"echo h''i-from-pty\n".to_vec());
        let out = wait_for(&t, |s| s.contains("hi-from-pty"));
        assert!(out.contains("hi-from-pty"), "output was {out:?}");
        t.resize(100, 30);
        t.write(b"exit 3\n".to_vec());
        assert!(wait_gone(&terms, &t.id), "terminal still registered after exit");
        assert_eq!(t.exited(), Some(Exit { code: 3, signal: None }));
        // The exit reaches attached clients after the output.
        let mut saw_exit = None;
        while let Ok(m) = rx.try_recv() {
            if let Out::Exit(e) = m {
                saw_exit = Some(e.code);
            }
        }
        assert_eq!(saw_exit, Some(3));
    }

    #[test]
    fn at_most_max_terminals_and_kill_frees_a_slot() {
        let terms = Arc::new(Terms::new(3));
        let ts: Vec<_> = (0..3).map(|_| terms.spawn(&tmp_root(), &sh(), 80, 24).unwrap()).collect();
        assert_eq!(terms.len(), 3);
        assert!(terms.spawn(&tmp_root(), &sh(), 80, 24).is_err());
        ts[0].kill();
        assert!(wait_gone(&terms, &ts[0].id));
        assert!(ts[0].exited().unwrap().signal.is_some(), "a hung-up shell reports the signal");
        let extra = terms.spawn(&tmp_root(), &sh(), 80, 24).unwrap();
        for t in ts.iter().skip(1).chain([&extra]) {
            t.kill();
            assert!(wait_gone(&terms, &t.id));
        }
        assert_eq!(terms.len(), 0);
        assert_eq!(MAX_TERMS, 8);
    }

    #[test]
    fn idle_only_counts_unattached_terminals() {
        let terms = Arc::new(Terms::new(MAX_TERMS));
        let a = terms.spawn(&tmp_root(), &sh(), 80, 24).unwrap();
        let b = terms.spawn(&tmp_root(), &sh(), 80, 24).unwrap();
        b.attach();
        let idle: Vec<String> = terms.idle(Duration::ZERO).into_iter().map(|t| t.id.clone()).collect();
        assert_eq!(idle, vec![a.id.clone()]);
        assert!(terms.idle(IDLE_CLOSE).is_empty());
        b.detach();
        assert_eq!(terms.idle(Duration::ZERO).len(), 2);
        for t in [&a, &b] {
            t.kill();
            assert!(wait_gone(&terms, &t.id));
        }
    }
}
