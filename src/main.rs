//! pocketpi: a small phone-friendly web front end for the pi coding agent.
//!
//! Each open chat is one `pi --mode rpc` child process. The browser sends pi
//! RPC commands through `POST /api/s/{key}/cmd` and receives pi's raw event
//! stream over SSE at `GET /api/s/{key}/events`. Sessions on disk are listed
//! from pi's own session directory, so chats started in the terminal show up
//! here and vice versa.

mod sessions;
mod spaces;

use axum::{
    Json, Router,
    extract::{ConnectInfo, DefaultBodyLimit, Path, Request, State},
    http::{HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{
        IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    convert::Infallible,
    net::SocketAddr,
    path::PathBuf,
    sync::{
        Arc, Mutex as StdMutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{ChildStdin, Command},
    sync::{Mutex, broadcast, oneshot},
};
use tokio_stream::{StreamExt, wrappers::BroadcastStream};

/// pi RPC commands the browser may send. Everything else is rejected.
const ALLOWED_COMMANDS: &[&str] = &[
    "prompt",
    "steer",
    "follow_up",
    "abort",
    "clear_queue",
    "get_state",
    "get_messages",
    "set_model",
    "get_available_models",
    "set_thinking_level",
    "get_available_thinking_levels",
    "compact",
    "get_session_stats",
    "set_session_name",
    "get_commands",
    "abort_retry",
    "extension_ui_response",
];

/// How long an unwatched, idle pi process is kept before it is shut down.
const IDLE_REAP: Duration = Duration::from_secs(20 * 60);

pub struct AppState {
    pi_bin: String,
    sessions_dir: PathBuf,
    home: PathBuf,
    allowed_users: Option<Vec<String>>,
    live: StdMutex<HashMap<String, Arc<Live>>>,
    next_key: AtomicU64,
    meta_cache: sessions::Cache,
    spaces_path: PathBuf,
    spaces_lock: StdMutex<()>,
}

pub struct Live {
    key: String,
    cwd: String,
    stdin: Mutex<Option<ChildStdin>>,
    tx: broadcast::Sender<Arc<str>>,
    pending: StdMutex<HashMap<String, oneshot::Sender<Value>>>,
    seq: AtomicU64,
    streaming: AtomicBool,
    last_active: StdMutex<Instant>,
    session_file: StdMutex<Option<String>>,
    stderr_tail: StdMutex<VecDeque<String>>,
}

impl Live {
    fn touch(&self) {
        *self.last_active.lock().unwrap() = Instant::now();
    }
    fn session_file(&self) -> Option<String> {
        self.session_file.lock().unwrap().clone()
    }
}

type AppResult<T> = Result<T, (StatusCode, String)>;

fn err(code: StatusCode, msg: impl Into<String>) -> (StatusCode, String) {
    (code, msg.into())
}

#[tokio::main]
async fn main() {
    let home = PathBuf::from(std::env::var("HOME").expect("HOME not set"));
    let agent_dir = std::env::var("PI_CODING_AGENT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home.join(".pi/agent"));
    let sessions_dir = std::env::var("PI_CODING_AGENT_SESSION_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| agent_dir.join("sessions"));
    let allowed_users = std::env::var("POCKETPI_ALLOWED_USERS").ok().map(|s| {
        s.split(',')
            .map(|u| u.trim().to_string())
            .filter(|u| !u.is_empty())
            .collect()
    });
    let port: u16 = std::env::var("POCKETPI_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3457);

    let app = Arc::new(AppState {
        pi_bin: std::env::var("POCKETPI_PI").unwrap_or_else(|_| "pi".into()),
        sessions_dir,
        spaces_path: spaces::config_path(&home),
        spaces_lock: StdMutex::new(()),
        home,
        allowed_users,
        live: StdMutex::new(HashMap::new()),
        next_key: AtomicU64::new(1),
        meta_cache: sessions::Cache::default(),
    });

    tokio::spawn(reaper(app.clone()));

    let router = Router::new()
        .route("/", get(|| async { static_file("index.html") }))
        .route("/app.js", get(|| async { static_file("app.js") }))
        .route("/app.css", get(|| async { static_file("app.css") }))
        .route("/icon.svg", get(|| async { static_file("icon.svg") }))
        .route("/icon-180.png", get(|| async { static_file("icon-180.png") }))
        .route("/icon-512.png", get(|| async { static_file("icon-512.png") }))
        .route("/manifest.webmanifest", get(|| async { static_file("manifest.webmanifest") }))
        .route("/fonts/geist.woff2", get(|| async { static_file("geist.woff2") }))
        .route("/fonts/geist-mono.woff2", get(|| async { static_file("geist-mono.woff2") }))
        .route("/api/spaces", get(list_spaces))
        .route("/api/spaces/save", post(save_space))
        .route("/api/spaces/hide", post(hide_space))
        .route("/api/sessions", get(list_sessions))
        .route("/api/dirs", get(list_dirs))
        .route("/api/new", post(new_session))
        .route("/api/open", post(open_session))
        .route("/api/s/{key}/cmd", post(send_command))
        .route("/api/s/{key}/events", get(events))
        .route("/api/s/{key}/close", post(close_session))
        .layer(DefaultBodyLimit::max(40 * 1024 * 1024))
        .layer(middleware::from_fn_with_state(app.clone(), guard))
        .with_state(app.clone());

    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    eprintln!("pocketpi listening on http://{addr}");
    axum::serve(listener, router.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .unwrap();
}

/// Only loopback connections are accepted: either a local browser, or
/// Tailscale Serve proxying a tailnet user (which adds Tailscale-User-Login).
/// Mutating requests must carry `X-Pocketpi: 1`, which a cross-site page
/// cannot send without a CORS preflight that this server never approves.
async fn guard(
    State(app): State<Arc<AppState>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let h = req.headers();
    if !peer.ip().is_loopback() || h.contains_key("tailscale-funnel-request") {
        return StatusCode::FORBIDDEN.into_response();
    }
    let login = h.get("tailscale-user-login").and_then(|v| v.to_str().ok());
    let host = h.get(header::HOST).and_then(|v| v.to_str().ok()).unwrap_or("");
    let local_host = host.starts_with("127.0.0.1") || host.starts_with("localhost");
    if login.is_none() && !local_host {
        return StatusCode::FORBIDDEN.into_response();
    }
    if let (Some(allowed), Some(login)) = (&app.allowed_users, login) {
        if !allowed.iter().any(|a| a.eq_ignore_ascii_case(login)) {
            return StatusCode::FORBIDDEN.into_response();
        }
    }
    if req.method() != Method::GET
        && h.get("x-pocketpi").and_then(|v| v.to_str().ok()) != Some("1")
    {
        return StatusCode::FORBIDDEN.into_response();
    }
    next.run(req).await
}

fn static_file(name: &str) -> Response {
    let (body, ctype): (&'static [u8], &str) = match name {
        "index.html" => (include_bytes!("../web/index.html"), "text/html; charset=utf-8"),
        "app.js" => (include_bytes!("../web/app.js"), "text/javascript; charset=utf-8"),
        "app.css" => (include_bytes!("../web/app.css"), "text/css; charset=utf-8"),
        "icon.svg" => (include_bytes!("../web/icon.svg"), "image/svg+xml"),
        "icon-180.png" => (include_bytes!("../web/icon-180.png"), "image/png"),
        "icon-512.png" => (include_bytes!("../web/icon-512.png"), "image/png"),
        "geist.woff2" => (include_bytes!("../web/Geist-Variable.woff2"), "font/woff2"),
        "geist-mono.woff2" => (include_bytes!("../web/GeistMono-Variable.woff2"), "font/woff2"),
        "manifest.webmanifest" => (include_bytes!("../web/manifest.webmanifest"), "application/manifest+json"),
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    let mut res = body.into_response();
    let hs = res.headers_mut();
    hs.insert(header::CONTENT_TYPE, HeaderValue::from_str(ctype).unwrap());
    let cache = if ctype.starts_with("font/") { "public, max-age=31536000, immutable" } else { "no-cache" };
    hs.insert(header::CACHE_CONTROL, HeaderValue::from_static(cache));
    res
}

fn get_live(app: &AppState, key: &str) -> AppResult<Arc<Live>> {
    app.live
        .lock()
        .unwrap()
        .get(key)
        .cloned()
        .ok_or_else(|| err(StatusCode::NOT_FOUND, "session not running"))
}

fn find_live_by_path(app: &AppState, path: &str) -> Option<Arc<Live>> {
    app.live
        .lock()
        .unwrap()
        .values()
        .find(|l| l.session_file().as_deref() == Some(path))
        .cloned()
}

async fn spawn_pi(app: &Arc<AppState>, cwd: &str, session: Option<&str>) -> AppResult<Arc<Live>> {
    let mut cmd = Command::new(&app.pi_bin);
    cmd.arg("--mode").arg("rpc");
    if let Some(s) = session {
        cmd.arg("--session").arg(s);
    }
    cmd.current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, format!("failed to start pi: {e}")))?;

    let key = format!(
        "{:x}{:x}",
        app.next_key.fetch_add(1, Ordering::Relaxed),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .subsec_nanos()
    );
    let (tx, _) = broadcast::channel(8192);
    let live = Arc::new(Live {
        key: key.clone(),
        cwd: cwd.to_string(),
        stdin: Mutex::new(child.stdin.take()),
        tx,
        pending: StdMutex::new(HashMap::new()),
        seq: AtomicU64::new(1),
        streaming: AtomicBool::new(false),
        last_active: StdMutex::new(Instant::now()),
        session_file: StdMutex::new(session.map(String::from)),
        stderr_tail: StdMutex::new(VecDeque::new()),
    });
    app.live.lock().unwrap().insert(key.clone(), live.clone());

    // stderr: keep a short tail for error reporting and echo to our log.
    if let Some(mut stderr) = child.stderr.take() {
        let live = live.clone();
        tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = stderr.read_to_end(&mut buf).await;
            let text = String::from_utf8_lossy(&buf);
            let mut tail = live.stderr_tail.lock().unwrap();
            for line in text.lines().filter(|l| !l.trim().is_empty()) {
                eprintln!("[pi {}] {}", live.key, line);
                tail.push_back(line.to_string());
                if tail.len() > 20 {
                    tail.pop_front();
                }
            }
        });
    }

    // stdout: strict LF framing (pi docs warn against splitting on U+2028).
    let stdout = child.stdout.take().expect("stdout piped");
    let app2 = app.clone();
    let live2 = live.clone();
    tokio::spawn(async move {
        let mut reader = BufReader::new(stdout);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match reader.read_until(b'\n', &mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            while matches!(buf.last(), Some(b'\n' | b'\r')) {
                buf.pop();
            }
            let Ok(line) = std::str::from_utf8(&buf) else { continue };
            let Ok(v) = serde_json::from_str::<Value>(line) else { continue };
            handle_record(&live2, line, v);
        }
        let _ = child.wait().await;
        live2.streaming.store(false, Ordering::Relaxed);
        for (_, tx) in live2.pending.lock().unwrap().drain() {
            let _ = tx.send(json!({"success": false, "error": "pi exited"}));
        }
        let tail: Vec<String> = live2.stderr_tail.lock().unwrap().iter().cloned().collect();
        let exit = json!({"type": "pocketpi_exit", "stderr": tail}).to_string();
        let _ = live2.tx.send(Arc::from(exit.as_str()));
        app2.live.lock().unwrap().remove(&live2.key);
    });

    Ok(live)
}

fn handle_record(live: &Live, line: &str, v: Value) {
    let ty = v.get("type").and_then(Value::as_str).unwrap_or("");
    if ty == "response" {
        if let Some(id) = v.get("id").and_then(Value::as_str) {
            if id.starts_with("pp-") {
                if v.get("command").and_then(Value::as_str) == Some("get_state") {
                    if let Some(f) = v.pointer("/data/sessionFile").and_then(Value::as_str) {
                        *live.session_file.lock().unwrap() = Some(f.to_string());
                    }
                }
                if let Some(tx) = live.pending.lock().unwrap().remove(id) {
                    let _ = tx.send(v);
                }
                return;
            }
        }
    }
    match ty {
        "agent_start" => live.streaming.store(true, Ordering::Relaxed),
        "agent_settled" => live.streaming.store(false, Ordering::Relaxed),
        _ => {}
    }
    live.touch();
    let _ = live.tx.send(Arc::from(line));
}

async fn rpc(live: &Live, mut cmd: Value) -> AppResult<Value> {
    let ty = cmd.get("type").and_then(Value::as_str).unwrap_or("").to_string();
    if !ALLOWED_COMMANDS.contains(&ty.as_str()) {
        return Err(err(StatusCode::BAD_REQUEST, format!("command not allowed: {ty}")));
    }
    live.touch();
    let wait = ty != "extension_ui_response";
    let mut rx = None;
    if wait {
        let id = format!("pp-{}", live.seq.fetch_add(1, Ordering::Relaxed));
        cmd["id"] = Value::String(id.clone());
        let (tx, r) = oneshot::channel();
        live.pending.lock().unwrap().insert(id, tx);
        rx = Some(r);
    }
    let mut line = cmd.to_string();
    line.push('\n');
    {
        let mut stdin = live.stdin.lock().await;
        let pipe = stdin
            .as_mut()
            .ok_or_else(|| err(StatusCode::GONE, "session closed"))?;
        pipe.write_all(line.as_bytes())
            .await
            .map_err(|e| err(StatusCode::GONE, format!("pi stdin: {e}")))?;
        let _ = pipe.flush().await;
    }
    let Some(rx) = rx else { return Ok(json!({"success": true})) };
    match tokio::time::timeout(Duration::from_secs(900), rx).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(_)) => Err(err(StatusCode::GONE, "pi exited")),
        Err(_) => Err(err(StatusCode::GATEWAY_TIMEOUT, "pi did not answer")),
    }
}

async fn send_command(
    State(app): State<Arc<AppState>>,
    Path(key): Path<String>,
    Json(cmd): Json<Value>,
) -> AppResult<Json<Value>> {
    let live = get_live(&app, &key)?;
    Ok(Json(rpc(&live, cmd).await?))
}

async fn events(State(app): State<Arc<AppState>>, Path(key): Path<String>) -> AppResult<impl IntoResponse> {
    let live = get_live(&app, &key)?;
    let rx = live.tx.subscribe();
    let hello = json!({
        "type": "pocketpi_hello",
        "streaming": live.streaming.load(Ordering::Relaxed),
    })
    .to_string();
    drop(live);
    let first = tokio_stream::once(Ok::<_, Infallible>(Event::default().data(hello)));
    let rest = BroadcastStream::new(rx).map(|r| {
        Ok::<_, Infallible>(match r {
            Ok(line) => Event::default().data(&*line),
            Err(_) => Event::default().data(r#"{"type":"pocketpi_resync"}"#),
        })
    });
    let mut res = Sse::new(first.chain(rest))
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
        .into_response();
    res.headers_mut()
        .insert("x-accel-buffering", HeaderValue::from_static("no"));
    Ok(res)
}

#[derive(Deserialize)]
struct NewReq {
    cwd: String,
}

async fn new_session(State(app): State<Arc<AppState>>, Json(req): Json<NewReq>) -> AppResult<Json<Value>> {
    let cwd = resolve_dir(&app, &req.cwd)?;
    let live = spawn_pi(&app, &cwd, None).await?;
    Ok(Json(json!({"key": live.key, "cwd": cwd})))
}

#[derive(Deserialize)]
struct OpenReq {
    path: String,
}

async fn open_session(State(app): State<Arc<AppState>>, Json(req): Json<OpenReq>) -> AppResult<Json<Value>> {
    let path = std::fs::canonicalize(&req.path)
        .map_err(|_| err(StatusCode::NOT_FOUND, "session file not found"))?;
    let root = std::fs::canonicalize(&app.sessions_dir).unwrap_or(app.sessions_dir.clone());
    if !path.starts_with(&root) || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Err(err(StatusCode::FORBIDDEN, "not a pi session file"));
    }
    let path_s = path.to_string_lossy().to_string();
    if let Some(live) = find_live_by_path(&app, &path_s) {
        return Ok(Json(json!({"key": live.key, "cwd": live.cwd})));
    }
    let meta = sessions::read_meta(&path).ok_or_else(|| err(StatusCode::BAD_REQUEST, "unreadable session"))?;
    if !std::path::Path::new(&meta.cwd).is_dir() {
        return Err(err(
            StatusCode::CONFLICT,
            format!("this chat's folder no longer exists: {}", meta.cwd),
        ));
    }
    let live = spawn_pi(&app, &meta.cwd, Some(&path_s)).await?;
    Ok(Json(json!({"key": live.key, "cwd": live.cwd})))
}

async fn close_session(State(app): State<Arc<AppState>>, Path(key): Path<String>) -> AppResult<Json<Value>> {
    let live = get_live(&app, &key)?;
    // Closing stdin asks pi for an orderly shutdown.
    live.stdin.lock().await.take();
    Ok(Json(json!({"ok": true})))
}

async fn scan_with_live(app: &Arc<AppState>) -> Vec<sessions::SessionInfo> {
    let app2 = app.clone();
    let mut list = tokio::task::spawn_blocking(move || sessions::scan(&app2.sessions_dir, &app2.meta_cache))
        .await
        .unwrap_or_default();
    let live: Vec<Arc<Live>> = app.live.lock().unwrap().values().cloned().collect();
    for s in list.iter_mut() {
        if let Some(l) = live.iter().find(|l| l.session_file().as_deref() == Some(s.path.as_str())) {
            s.live = true;
            s.streaming = l.streaming.load(Ordering::Relaxed);
        }
    }
    list
}

async fn list_sessions(State(app): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({ "sessions": scan_with_live(&app).await }))
}

async fn list_spaces(State(app): State<Arc<AppState>>) -> Json<Value> {
    let list = scan_with_live(&app).await;
    let cfg = spaces::load(&app.spaces_path);
    let home = app.home.to_string_lossy().to_string();
    Json(json!({ "spaces": spaces::build(&cfg, &list, &home), "home": home }))
}

#[derive(Deserialize)]
struct SpaceReq {
    path: String,
    #[serde(default)]
    name: Option<String>,
}

fn resolve_dir(app: &AppState, raw: &str) -> AppResult<String> {
    let raw = raw.trim();
    let expanded = if raw == "~" || raw.is_empty() {
        app.home.clone()
    } else if let Some(rest) = raw.strip_prefix("~/") {
        app.home.join(rest)
    } else {
        PathBuf::from(raw)
    };
    let dir = std::fs::canonicalize(&expanded)
        .map_err(|_| err(StatusCode::BAD_REQUEST, format!("folder not found: {raw}")))?;
    if !dir.is_dir() {
        return Err(err(StatusCode::BAD_REQUEST, format!("not a folder: {raw}")));
    }
    Ok(dir.to_string_lossy().to_string())
}

async fn save_space(State(app): State<Arc<AppState>>, Json(req): Json<SpaceReq>) -> AppResult<Json<Value>> {
    let path = resolve_dir(&app, &req.path)?;
    let _g = app.spaces_lock.lock().unwrap();
    let mut cfg = spaces::load(&app.spaces_path);
    cfg.hidden.retain(|h| h != &path);
    let name = req.name.map(|n| n.trim().to_string()).filter(|n| !n.is_empty());
    match cfg.pinned.iter_mut().find(|p| p.path == path) {
        Some(p) => p.name = name,
        None => cfg.pinned.push(spaces::Pinned { path: path.clone(), name }),
    }
    spaces::save(&app.spaces_path, &cfg).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(json!({ "path": path })))
}

async fn hide_space(State(app): State<Arc<AppState>>, Json(req): Json<SpaceReq>) -> AppResult<Json<Value>> {
    let _g = app.spaces_lock.lock().unwrap();
    let mut cfg = spaces::load(&app.spaces_path);
    cfg.pinned.retain(|p| p.path != req.path);
    if !cfg.hidden.contains(&req.path) {
        cfg.hidden.push(req.path.clone());
    }
    spaces::save(&app.spaces_path, &cfg).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(json!({ "ok": true })))
}

async fn list_dirs(State(app): State<Arc<AppState>>) -> Json<Value> {
    let app2 = app.clone();
    let dirs = tokio::task::spawn_blocking(move || {
        let mut out: Vec<String> = Vec::new();
        for s in sessions::scan(&app2.sessions_dir, &app2.meta_cache) {
            if !out.contains(&s.cwd) && std::path::Path::new(&s.cwd).is_dir() {
                out.push(s.cwd);
            }
        }
        let mut projects: Vec<String> = std::fs::read_dir(app2.home.join("projects"))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .map(|e| e.path().to_string_lossy().to_string())
            .filter(|p| !p.rsplit('/').next().unwrap_or("").starts_with('.'))
            .collect();
        projects.sort_by_key(|p| p.to_lowercase());
        for p in projects {
            if !out.contains(&p) {
                out.push(p);
            }
        }
        let home = app2.home.to_string_lossy().to_string();
        if !out.contains(&home) {
            out.push(home);
        }
        out
    })
    .await
    .unwrap_or_default();
    Json(json!({ "dirs": dirs, "home": app.home }))
}

async fn reaper(app: Arc<AppState>) {
    loop {
        tokio::time::sleep(Duration::from_secs(60)).await;
        let idle: Vec<Arc<Live>> = app
            .live
            .lock()
            .unwrap()
            .values()
            .filter(|l| {
                l.tx.receiver_count() == 0
                    && !l.streaming.load(Ordering::Relaxed)
                    && l.last_active.lock().unwrap().elapsed() > IDLE_REAP
            })
            .cloned()
            .collect();
        for l in idle {
            eprintln!("closing idle pi session {}", l.key);
            l.stdin.lock().await.take();
        }
    }
}
