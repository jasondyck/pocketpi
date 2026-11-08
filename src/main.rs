//! pocketpi: a small phone-friendly web front end for the pi coding agent.
//!
//! Each open chat is one `pi --mode rpc` child process. The browser sends pi
//! RPC commands through `POST /api/s/{key}/cmd` and receives pi's raw event
//! stream over SSE at `GET /api/s/{key}/events`. Sessions on disk are listed
//! from pi's own session directory, so chats started in the terminal show up
//! here and vice versa.

mod sessions;
mod projects;
mod cron;
mod workflows;
mod engine;
mod notify;
mod sensors;
mod apns;
mod push;
mod improve;
mod llama;

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

/// Changes on every restart (deploy); the page polls it to live-reload.
static BUILD_ID: std::sync::LazyLock<u64> = std::sync::LazyLock::new(|| {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
});

/// How long an unwatched, idle pi process is kept before it is shut down.
const IDLE_REAP: Duration = Duration::from_secs(20 * 60);

pub struct AppState {
    pub(crate) pi_bin: String,
    pub(crate) sessions_dir: PathBuf,
    /// pi's own folder (settings.json: the models people picked in pi).
    pub(crate) agent_dir: PathBuf,
    pub(crate) home: PathBuf,
    /// Where the app's Chat tab keeps its chats: plain conversations, pi
    /// without tools, left out of the projects and the Work chat list.
    pub(crate) chat_dir: PathBuf,
    pub(crate) allowed_users: Option<Vec<String>>,
    pub(crate) suggest_model: String,
    pub(crate) suggest_slots: tokio::sync::Semaphore,
    pub(crate) live: StdMutex<HashMap<String, Arc<Live>>>,
    pub(crate) next_key: AtomicU64,
    pub(crate) meta_cache: sessions::Cache,
    pub(crate) projects_path: PathBuf,
    pub(crate) projects_lock: StdMutex<()>,
    pub(crate) engine: Arc<engine::Engine>,
    pub(crate) sensors: sensors::Sensors,
    pub(crate) push: push::Push,
}

pub struct Live {
    pub(crate) key: String,
    pub(crate) cwd: String,
    pub(crate) stdin: Mutex<Option<ChildStdin>>,
    pub(crate) tx: broadcast::Sender<Arc<str>>,
    pub(crate) pending: StdMutex<HashMap<String, oneshot::Sender<Value>>>,
    pub(crate) seq: AtomicU64,
    pub(crate) streaming: AtomicBool,
    pub(crate) last_active: StdMutex<Instant>,
    pub(crate) session_file: StdMutex<Option<String>>,
    pub(crate) stderr_tail: StdMutex<VecDeque<String>>,
    pub(crate) turn_started: StdMutex<Option<Instant>>,
}

impl Live {
    fn touch(&self) {
        *self.last_active.lock().unwrap() = Instant::now();
    }
    pub(crate) fn session_file(&self) -> Option<String> {
        self.session_file.lock().unwrap().clone()
    }
}

pub(crate) type AppResult<T> = Result<T, (StatusCode, String)>;

pub(crate) fn err(code: StatusCode, msg: impl Into<String>) -> (StatusCode, String) {
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

    std::sync::LazyLock::force(&BUILD_ID);
    let chat_dir = std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".local/share")).join("pocketpi/chat");
    let _ = std::fs::create_dir_all(&chat_dir);
    let chat_dir = std::fs::canonicalize(&chat_dir).unwrap_or(chat_dir);
    let app = Arc::new(AppState {
        chat_dir,
        pi_bin: std::env::var("POCKETPI_PI").unwrap_or_else(|_| "pi".into()),
        sessions_dir,
        agent_dir: agent_dir.clone(),
        projects_path: projects::config_path(&home),
        projects_lock: StdMutex::new(()),
        engine: Arc::new(engine::Engine::new(&home)),
        sensors: sensors::Sensors::new(&home),
        push: push::Push::new(&home),
        home,
        allowed_users,
        suggest_model: std::env::var("POCKETPI_SUGGEST_MODEL").unwrap_or_else(|_| "opencode-go/deepseek-v4.1-flash".into()),
        suggest_slots: tokio::sync::Semaphore::new(2),
        live: StdMutex::new(HashMap::new()),
        next_key: AtomicU64::new(1),
        meta_cache: sessions::Cache::default(),
    });

    tokio::spawn(reaper(app.clone()));
    tokio::spawn(sensors::run(app.clone()));

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
        .route("/api/version", get(|| async { Json(json!({ "build": *BUILD_ID })) }))
        .route("/api/projects", get(list_projects))
        .route("/api/projects/save", post(save_project))
        .route("/api/projects/hide", post(hide_project))
        .route("/api/sessions", get(list_sessions))
        .route("/api/llama", get(llama::list))
        .route("/api/llama/load", post(llama::load))
        .route("/api/sessions/archive", post(archive_session))
        .route("/api/sessions/delete", post(delete_session))
        .route("/api/models/enabled", get(enabled_models))
        .route("/api/dirs", get(list_dirs))
        .route("/api/new", post(new_session))
        .route("/api/suggest", post(suggest))
        .route("/api/busy", get(busy))
        .route("/api/workflows", get(list_workflows).post(save_workflow))
        .route("/api/workflows/schema", get(|| async { Json(workflows::schema_doc()) }))
        .route("/api/workflows/{id}", get(get_workflow))
        .route("/api/workflows/{id}/run", post(run_workflow))
        .route("/api/workflows/{id}/enable", post(enable_workflow))
        .route("/api/workflows/{id}/delete", post(delete_workflow))
        .route("/api/workflows/{id}/webhook/rotate", post(rotate_webhook))
        .route("/api/workflows/{id}/improve", post(set_improve))
        .route("/api/workflows/{id}/reflect", post(reflect_now))
        .route("/api/workflows/{id}/proposal/apply", post(apply_proposal))
        .route("/api/workflows/{id}/proposal/dismiss", post(dismiss_proposal))
        .route("/api/workflows/{id}/revert", post(revert_workflow))
        .route("/hook/{id}/{token}", post(webhook))
        .route("/api/push", get(push_info))
        .route("/api/push/subscribe", post(push_subscribe))
        .route("/api/push/unsubscribe", post(push_unsubscribe))
        .route("/api/push/test", post(push_test))
        .route("/api/apns/register", post(apns_register))
        .route("/api/apns/unregister", post(apns_unregister))
        .route("/sw.js", get(|| async { static_file("sw.js") }))
        .route("/api/runs", get(list_runs))
        .route("/api/runs/events", get(run_events))
        .route("/api/runs/{id}", get(get_run))
        .route("/api/runs/{id}/approve", post(approve_run))
        .route("/api/runs/{id}/cancel", post(cancel_run))
        .route("/api/runs/{id}/cleanup", post(cleanup_run))
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
    // Webhooks come from tailnet services (Home Assistant, CI...) that have no
    // user identity; they authenticate with the per-workflow token instead.
    if req.uri().path().starts_with("/hook/") && req.method() == Method::POST {
        return next.run(req).await;
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
        "sw.js" => (include_bytes!("../web/sw.js"), "text/javascript; charset=utf-8"),
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

const CHAT_SYSTEM_PROMPT: &str = "You are a helpful, knowledgeable assistant chatting with the user from their phone. \
Answer directly and conversationally. Use Markdown when it helps (lists, tables, code blocks). \
You have no tools in this chat: you can't read files, run commands or browse.";

fn is_chat_dir(app: &AppState, cwd: &str) -> bool {
    std::path::Path::new(cwd) == app.chat_dir
}

async fn spawn_pi(app: &Arc<AppState>, cwd: &str, session: Option<&str>) -> AppResult<Arc<Live>> {
    spawn_pi_with(app, cwd, session, &[]).await
}

pub async fn spawn_pi_with(app: &Arc<AppState>, cwd: &str, session: Option<&str>, extra: &[String]) -> AppResult<Arc<Live>> {
    let mut cmd = Command::new(&app.pi_bin);
    cmd.arg("--mode").arg("rpc");
    if let Some(s) = session {
        cmd.arg("--session").arg(s);
    }
    // The Chat tab: a conversation, not a coding agent (also on reopen).
    if is_chat_dir(app, cwd) {
        cmd.arg("--no-tools").arg("--system-prompt").arg(CHAT_SYSTEM_PROMPT);
    }
    cmd.args(extra);
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
        turn_started: StdMutex::new(None),
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
            let ty = v.get("type").and_then(Value::as_str).unwrap_or("").to_string();
            handle_record(&live2, line, v);
            match ty.as_str() {
                "agent_start" => {
                    let mut t = live2.turn_started.lock().unwrap();
                    if t.is_none() {
                        *t = Some(Instant::now());
                    }
                }
                "agent_settled" => {
                    let took = live2.turn_started.lock().unwrap().take().map(|t| t.elapsed());
                    // Long reply finished and nobody has the chat open: tell the phone.
                    if took.is_some_and(|d| d > Duration::from_secs(45)) && live2.tx.receiver_count() == 0 {
                        let (app3, live3) = (app2.clone(), live2.clone());
                        tokio::spawn(async move {
                            let file = live3.session_file().unwrap_or_default();
                            let project = live3.cwd.rsplit('/').next().unwrap_or("").to_string();
                            let url = format!("/?s={}", urlencode(&file));
                            app3.push.send(&format!("pi finished · {project}"), "Your chat has a new reply.", &url, &format!("chat-{}", live3.key)).await;
                        });
                    }
                }
                _ => {}
            }
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

async fn rpc(live: &Live, cmd: Value) -> AppResult<Value> {
    let ty = cmd.get("type").and_then(Value::as_str).unwrap_or("").to_string();
    if !ALLOWED_COMMANDS.contains(&ty.as_str()) {
        return Err(err(StatusCode::BAD_REQUEST, format!("command not allowed: {ty}")));
    }
    rpc_internal(live, cmd).await
}

/// Sends any pi RPC command (no allow-list); used by the workflow engine.
pub async fn rpc_internal(live: &Live, mut cmd: Value) -> AppResult<Value> {
    let ty = cmd.get("type").and_then(Value::as_str).unwrap_or("").to_string();
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
    // Workflow stages run in their own worktrees; keep those out of the chat list.
    let wt = app.engine.worktrees_dir.to_string_lossy().to_string();
    list.retain(|s| !s.cwd.starts_with(&wt));
    let live: Vec<Arc<Live>> = app.live.lock().unwrap().values().cloned().collect();
    for s in list.iter_mut() {
        if let Some(l) = live.iter().find(|l| l.session_file().as_deref() == Some(s.path.as_str())) {
            s.live = true;
            s.streaming = l.streaming.load(Ordering::Relaxed);
        }
    }
    list
}

#[derive(Deserialize)]
struct SessionsQuery {
    /// `?archived=1`: only the archived chats (default: only the others).
    #[serde(default)]
    archived: Option<String>,
    /// `?chat=1`: only the Chat tab's chats (default: everything else).
    #[serde(default)]
    chat: Option<String>,
}

async fn list_sessions(
    State(app): State<Arc<AppState>>,
    axum::extract::Query(q): axum::extract::Query<SessionsQuery>,
) -> Json<Value> {
    let want_archived = q.archived.as_deref().is_some_and(|v| v == "1" || v == "true");
    let want_chat = q.chat.as_deref().is_some_and(|v| v == "1" || v == "true");
    let cfg = projects::load(&app.projects_path);
    let mut list = scan_with_live(&app).await;
    list.retain(|s| cfg.archived.contains(&s.path) == want_archived && is_chat_dir(&app, &s.cwd) == want_chat);
    Json(json!({ "sessions": list, "chat_dir": app.chat_dir }))
}

/// The models chosen in pi (`enabledModels` in pi's settings.json, the ones
/// pi cycles through), in pi's order, as "provider/id" or patterns with `*`.
/// pi's RPC has no command for this, so the app's model sheet gets it here.
async fn enabled_models(State(app): State<Arc<AppState>>) -> Json<Value> {
    let list: Vec<String> = std::fs::read_to_string(app.agent_dir.join("settings.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.get("enabledModels").cloned())
        .and_then(|v| serde_json::from_value(v).ok())
        .unwrap_or_default();
    Json(json!({ "enabled": list }))
}

#[derive(Deserialize)]
struct ArchiveReq {
    path: String,
    #[serde(default = "yes")]
    archived: bool,
}

fn yes() -> bool {
    true
}

/// Archive (or bring back) a chat. Its session file stays where it is; only
/// the lists leave it out.
async fn archive_session(State(app): State<Arc<AppState>>, Json(req): Json<ArchiveReq>) -> AppResult<Json<Value>> {
    let path = std::fs::canonicalize(&req.path).map_err(|_| err(StatusCode::NOT_FOUND, "session file not found"))?;
    let root = std::fs::canonicalize(&app.sessions_dir).unwrap_or(app.sessions_dir.clone());
    if !path.starts_with(&root) || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Err(err(StatusCode::FORBIDDEN, "not a pi session file"));
    }
    let path = path.to_string_lossy().to_string();
    let _g = app.projects_lock.lock().unwrap();
    let mut cfg = projects::load(&app.projects_path);
    cfg.archived.retain(|p| p != &path);
    if req.archived {
        cfg.archived.push(path.clone());
    }
    projects::save(&app.projects_path, &cfg).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(json!({ "path": path, "archived": req.archived })))
}

#[derive(Deserialize)]
struct DeleteReq {
    path: String,
}

/// Delete an archived chat for good: its pi session file is removed. Only
/// archived chats (archiving is the step before), and never one whose pi is
/// running.
async fn delete_session(State(app): State<Arc<AppState>>, Json(req): Json<DeleteReq>) -> AppResult<Json<Value>> {
    let path = std::fs::canonicalize(&req.path).map_err(|_| err(StatusCode::NOT_FOUND, "session file not found"))?;
    let root = std::fs::canonicalize(&app.sessions_dir).unwrap_or(app.sessions_dir.clone());
    if !path.starts_with(&root) || path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
        return Err(err(StatusCode::FORBIDDEN, "not a pi session file"));
    }
    let path_s = path.to_string_lossy().to_string();
    if !projects::load(&app.projects_path).archived.contains(&path_s) {
        return Err(err(StatusCode::CONFLICT, "only archived chats can be deleted"));
    }
    // Viewed a moment ago: its pi may still be up (the reaper takes a while).
    // Stop it first, unless it's in the middle of a reply.
    if let Some(live) = find_live_by_path(&app, &path_s) {
        if live.streaming.load(Ordering::Relaxed) {
            return Err(err(StatusCode::CONFLICT, "pi is replying in this chat; stop it first"));
        }
        live.stdin.lock().await.take();
        for _ in 0..50 {
            if find_live_by_path(&app, &path_s).is_none() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        if find_live_by_path(&app, &path_s).is_some() {
            return Err(err(StatusCode::CONFLICT, "this chat's pi didn't stop; try again"));
        }
    }
    let _g = app.projects_lock.lock().unwrap();
    let mut cfg = projects::load(&app.projects_path);
    std::fs::remove_file(&path).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    cfg.archived.retain(|p| p != &path_s);
    projects::save(&app.projects_path, &cfg).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(json!({ "deleted": path_s })))
}

async fn list_projects(State(app): State<Arc<AppState>>) -> Json<Value> {
    let mut list = scan_with_live(&app).await;
    let cfg = projects::load(&app.projects_path);
    // Counts and recency leave archived chats out, like the chat list.
    list.retain(|s| !cfg.archived.contains(&s.path) && !is_chat_dir(&app, &s.cwd));
    let home = app.home.to_string_lossy().to_string();
    Json(json!({ "projects": projects::build(&cfg, &list, &home), "home": home }))
}

#[derive(Deserialize)]
struct ProjectReq {
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

async fn save_project(State(app): State<Arc<AppState>>, Json(req): Json<ProjectReq>) -> AppResult<Json<Value>> {
    let path = resolve_dir(&app, &req.path)?;
    let _g = app.projects_lock.lock().unwrap();
    let mut cfg = projects::load(&app.projects_path);
    cfg.hidden.retain(|h| h != &path);
    let name = req.name.map(|n| n.trim().to_string()).filter(|n| !n.is_empty());
    match cfg.pinned.iter_mut().find(|p| p.path == path) {
        Some(p) => p.name = name,
        None => cfg.pinned.push(projects::Pinned { path: path.clone(), name }),
    }
    projects::save(&app.projects_path, &cfg).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(json!({ "path": path })))
}

async fn hide_project(State(app): State<Arc<AppState>>, Json(req): Json<ProjectReq>) -> AppResult<Json<Value>> {
    let _g = app.projects_lock.lock().unwrap();
    let mut cfg = projects::load(&app.projects_path);
    cfg.pinned.retain(|p| p.path != req.path);
    if !cfg.hidden.contains(&req.path) {
        cfg.hidden.push(req.path.clone());
    }
    projects::save(&app.projects_path, &cfg).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    Ok(Json(json!({ "ok": true })))
}

const SUGGEST_PROMPT: &str = "You predict what someone chatting with a coding agent on their phone will type next. \
Read the agent's last message (and the user's previous message for context). \
Return the 1-3 messages the user would most plausibly send next, written exactly as the user would type them: \
short, casual, first person, each under 60 characters. Most likely first. \
If the agent asked a question or offered options, give one answer per option it offered (its recommended option first), up to 3. \
Otherwise they are natural follow-ups such as asking it to test, commit, continue, explain, or fix something it mentioned. \
Never repeat the agent's words back, never add pleasantries. If nothing sensible fits, return an empty list. \
Output ONLY JSON, no prose: {\"replies\":[\"...\"]}";

#[derive(Deserialize)]
struct SuggestReq {
    assistant: String,
    #[serde(default)]
    user: String,
}

fn tail_chars(s: &str, n: usize) -> String {
    let count = s.chars().count();
    s.chars().skip(count.saturating_sub(n)).collect()
}

/// Suggested replies via a one-shot `pi -p` on a cheap model, so the API key
/// never leaves pi. No tools, context files, skills or session are loaded.
async fn suggest(State(app): State<Arc<AppState>>, Json(req): Json<SuggestReq>) -> AppResult<Json<Value>> {
    let _slot = app.suggest_slots.acquire().await.map_err(|_| err(StatusCode::SERVICE_UNAVAILABLE, "busy"))?;
    let user: String = req.user.chars().take(1200).collect();
    let prompt = format!(
        "USER'S LAST MESSAGE:\n{}\n\nAGENT'S LAST MESSAGE:\n{}",
        user.trim(),
        tail_chars(req.assistant.trim(), 4000)
    );
    let run = Command::new(&app.pi_bin)
        .args(["--no-session", "-p", "--model", &app.suggest_model, "--thinking", "low"])
        .args(["--no-tools", "--no-context-files", "--no-skills", "--no-extensions", "--no-prompt-templates"])
        .arg("--system-prompt")
        .arg(SUGGEST_PROMPT)
        .arg(prompt)
        .current_dir(std::env::temp_dir())
        .env("PI_OFFLINE", "1")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(45), run)
        .await
        .map_err(|_| err(StatusCode::GATEWAY_TIMEOUT, "suggestion timed out"))?
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, format!("pi: {e}")))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let replies: Vec<String> = match (text.find('{'), text.rfind('}')) {
        (Some(a), Some(b)) if b > a => serde_json::from_str::<Value>(&text[a..=b])
            .ok()
            .and_then(|v| v.get("replies").cloned())
            .and_then(|v| v.as_array().cloned())
            .unwrap_or_default()
            .into_iter()
            .filter_map(|r| r.as_str().map(|s| s.trim().chars().take(120).collect::<String>()))
            .filter(|s| !s.is_empty())
            .take(3)
            .collect(),
        _ => Vec::new(),
    };
    Ok(Json(json!({ "replies": replies })))
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

// ---------------------------------------------------------------- workflows API

async fn busy(State(app): State<Arc<AppState>>) -> Json<Value> {
    let chats = app.live.lock().unwrap().values().filter(|l| l.streaming.load(Ordering::Relaxed)).count();
    let runs = app.engine.busy();
    Json(json!({ "busy": chats > 0 || runs, "streaming": chats, "runs": runs }))
}

async fn list_workflows(State(app): State<Arc<AppState>>) -> Json<Value> {
    let wfs = workflows::load_all(&app.engine.workflows_dir);
    let runs = app.engine.list_runs(None);
    let out: Vec<Value> = wfs
        .iter()
        .map(|w| {
            let last = runs.iter().find(|r| r.workflow_id == w.id);
            json!({
                "workflow": w,
                "errors": workflows::validate(w),
                "last_run": last.map(|r| json!({"id": r.id, "status": r.status, "created": r.created, "ended": r.ended, "cost": r.cost})),
                "runs": runs.iter().filter(|r| r.workflow_id == w.id).count(),
            })
        })
        .collect();
    Json(json!({ "workflows": out }))
}

async fn get_workflow(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    let w = workflows::load(&app.engine.workflows_dir, &id).ok_or_else(|| err(StatusCode::NOT_FOUND, "workflow not found"))?;
    let errors = workflows::validate(&w);
    let runs: Vec<engine::Run> = app.engine.list_runs(Some(&id)).into_iter().take(30).collect();
    let webhook = w
        .triggers
        .iter()
        .any(|t| matches!(t, workflows::Trigger::Webhook))
        .then(|| format!("/hook/{}/{}", w.id, app.sensors.token(&w.id)));
    let next: Vec<Option<String>> = w
        .triggers
        .iter()
        .map(|t| match t {
            workflows::Trigger::Schedule { cron } => sensors::next_fire(cron),
            _ => None,
        })
        .collect();
    let proposal: Option<Value> = std::fs::read_to_string(workflows::proposal_path(&app.engine.workflows_dir, &id)).ok().and_then(|s| serde_json::from_str(&s).ok());
    let history: Vec<Value> = workflows::history(&app.engine.workflows_dir, &id)
        .into_iter()
        .take(20)
        .map(|(v, at, reason)| json!({ "version": v, "at": at, "reason": reason }))
        .collect();
    Ok(Json(json!({ "workflow": w, "errors": errors, "runs": runs, "webhook": webhook, "next": next, "proposal": proposal, "history": history })))
}

/// Saves a workflow (create or replace). Invalid workflows are rejected with
/// the problems listed, so the chat tool can fix them and try again.
async fn save_workflow(State(app): State<Arc<AppState>>, Json(body): Json<Value>) -> AppResult<Json<Value>> {
    let mut wf: workflows::Workflow = match serde_json::from_value(body) {
        Ok(w) => w,
        Err(e) => return Ok(Json(json!({ "ok": false, "errors": [format!("invalid workflow JSON: {e}")] }))),
    };
    if let Some(rest) = wf.project.strip_prefix("~/") {
        wf.project = app.home.join(rest).to_string_lossy().to_string();
    }
    if let Ok(p) = std::fs::canonicalize(&wf.project) {
        wf.project = p.to_string_lossy().to_string();
    }
    let errors = workflows::validate(&wf);
    if !errors.is_empty() {
        return Ok(Json(json!({ "ok": false, "errors": errors })));
    }
    workflows::save_versioned(&app.engine.workflows_dir, &wf, "edited").map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let _ = app.engine.tx.send(Arc::from(json!({"type": "workflows_changed"}).to_string().as_str()));
    Ok(Json(json!({ "ok": true, "workflow": wf })))
}

#[derive(Deserialize)]
struct RunReq {
    #[serde(default)]
    inputs: HashMap<String, String>,
    #[serde(default)]
    trigger: Option<String>,
    /// Run even if an identical run already exists (manual "run again").
    #[serde(default)]
    force: bool,
}

async fn run_workflow(State(app): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<RunReq>) -> AppResult<Json<Value>> {
    let w = workflows::load(&app.engine.workflows_dir, &id).ok_or_else(|| err(StatusCode::NOT_FOUND, "workflow not found"))?;
    let trigger = req.trigger.unwrap_or_else(|| "manual".into());
    // pi starting a workflow on its own needs an enabled workflow that opted in.
    if trigger == "agent" {
        if !w.enabled || !w.triggers.iter().any(|t| matches!(t, workflows::Trigger::Agent { .. })) {
            return Err(err(StatusCode::FORBIDDEN, "this workflow can't be started by pi on its own (it needs to be enabled with an agent trigger); ask the user to start it"));
        }
        if app.engine.list_active().contains(&id) {
            return Err(err(StatusCode::CONFLICT, "this workflow is already running; don't start another"));
        }
    }
    let mut inputs = req.inputs;
    // A PR run is about a specific commit: record the PR's current head so
    // duplicates can be recognised whichever way the run was started.
    if let Some(pr) = inputs.get("pr").filter(|p| p.chars().all(|c| c.is_ascii_digit()) && !p.is_empty()).cloned() {
        if !inputs.contains_key("commit") {
            let out = Command::new("gh")
                .args(["pr", "view", &pr, "--json", "headRefOid", "-q", ".headRefOid"])
                .current_dir(&w.project)
                .stdin(std::process::Stdio::null())
                .output();
            if let Ok(Ok(o)) = tokio::time::timeout(Duration::from_secs(15), out).await {
                let sha = String::from_utf8_lossy(&o.stdout).trim().to_string();
                if o.status.success() && sha.len() >= 7 {
                    inputs.insert("commit".into(), sha);
                }
            }
        }
    }
    if !req.force {
        if let Some(dup) = app.engine.duplicate(&id, &inputs) {
            let what = if inputs.contains_key("pr") { format!("PR #{} at this commit", inputs["pr"]) } else { "these inputs".into() };
            return Err(err(
                StatusCode::CONFLICT,
                json!({ "duplicate": true, "run_id": dup.id, "status": dup.status, "created": dup.created,
                        "message": format!("{} already ran for {what} (run {}, {:?}); not starting a duplicate", w.name, dup.id, dup.status) })
                .to_string(),
            ));
        }
    }
    let run_id = app.engine.start(app.clone(), w, &trigger, inputs).map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    Ok(Json(json!({ "run_id": run_id })))
}

#[derive(Deserialize)]
struct EnableReq {
    enabled: bool,
}

async fn enable_workflow(State(app): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<EnableReq>) -> AppResult<Json<Value>> {
    let mut w = workflows::load(&app.engine.workflows_dir, &id).ok_or_else(|| err(StatusCode::NOT_FOUND, "workflow not found"))?;
    w.enabled = req.enabled;
    workflows::save(&app.engine.workflows_dir, &w).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let _ = app.engine.tx.send(Arc::from(json!({"type": "workflows_changed"}).to_string().as_str()));
    Ok(Json(json!({ "ok": true })))
}

async fn delete_workflow(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    workflows::delete(&app.engine.workflows_dir, &id).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let _ = app.engine.tx.send(Arc::from(json!({"type": "workflows_changed"}).to_string().as_str()));
    Ok(Json(json!({ "ok": true })))
}

#[derive(Deserialize)]
struct RunsQuery {
    workflow: Option<String>,
}

async fn list_runs(State(app): State<Arc<AppState>>, axum::extract::Query(q): axum::extract::Query<RunsQuery>) -> Json<Value> {
    let runs: Vec<engine::Run> = app.engine.list_runs(q.workflow.as_deref()).into_iter().take(50).collect();
    Json(json!({ "runs": runs }))
}

async fn get_run(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    let r = app.engine.get_run(&id).ok_or_else(|| err(StatusCode::NOT_FOUND, "run not found"))?;
    Ok(Json(json!({ "run": r })))
}

#[derive(Deserialize)]
struct ApproveReq {
    stage: String,
    approve: bool,
    #[serde(default)]
    note: String,
}

async fn approve_run(State(app): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<ApproveReq>) -> AppResult<Json<Value>> {
    if !app.engine.approve(&id, &req.stage, req.approve, req.note) {
        return Err(err(StatusCode::CONFLICT, "that stage is not waiting for approval"));
    }
    Ok(Json(json!({ "ok": true })))
}

async fn cancel_run(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    if !app.engine.cancel(&id) {
        return Err(err(StatusCode::CONFLICT, "run is not active"));
    }
    Ok(Json(json!({ "ok": true })))
}

async fn cleanup_run(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    app.engine.cleanup(&id).await.map_err(|e| err(StatusCode::CONFLICT, e))?;
    Ok(Json(json!({ "ok": true })))
}

async fn run_events(State(app): State<Arc<AppState>>) -> impl IntoResponse {
    let rx = app.engine.tx.subscribe();
    let first = tokio_stream::once(Ok::<_, Infallible>(Event::default().data(r#"{"type":"hello"}"#)));
    let rest = BroadcastStream::new(rx).map(|r| {
        Ok::<_, Infallible>(match r {
            Ok(line) => Event::default().data(&*line),
            Err(_) => Event::default().data(r#"{"type":"resync"}"#),
        })
    });
    let mut res = Sse::new(first.chain(rest)).keep_alive(KeepAlive::new().interval(Duration::from_secs(15))).into_response();
    res.headers_mut().insert("x-accel-buffering", HeaderValue::from_static("no"));
    res
}

async fn rotate_webhook(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> Json<Value> {
    Json(json!({ "webhook": format!("/hook/{}/{}", id, app.sensors.rotate(&id)) }))
}

/// POST /hook/{workflow}/{token}: starts a run. A JSON object body becomes the
/// run's inputs (strings kept, other values JSON-encoded); the raw body is
/// also passed as the `payload` input.
async fn webhook(State(app): State<Arc<AppState>>, Path((id, token)): Path<(String, String)>, body: axum::body::Bytes) -> AppResult<Json<Value>> {
    if !app.sensors.check_token(&id, &token) {
        return Err(err(StatusCode::NOT_FOUND, "not found"));
    }
    let w = workflows::load(&app.engine.workflows_dir, &id).ok_or_else(|| err(StatusCode::NOT_FOUND, "not found"))?;
    if !w.enabled {
        return Err(err(StatusCode::CONFLICT, "workflow is a draft; enable its sensors first"));
    }
    if !w.triggers.iter().any(|t| matches!(t, workflows::Trigger::Webhook)) {
        return Err(err(StatusCode::NOT_FOUND, "not found"));
    }
    if app.engine.list_active().contains(&id) {
        return Err(err(StatusCode::CONFLICT, "a run is already in progress"));
    }
    let mut inputs = HashMap::new();
    let text = String::from_utf8_lossy(&body).to_string();
    if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&text) {
        for (k, v) in map {
            inputs.insert(k, v.as_str().map(String::from).unwrap_or_else(|| v.to_string()));
        }
    }
    inputs.insert("payload".into(), text.chars().take(20_000).collect());
    if let Some(dup) = app.engine.duplicate(&id, &inputs) {
        return Err(err(StatusCode::CONFLICT, format!("already ran for these inputs (run {})", dup.id)));
    }
    let run_id = app.engine.start(app.clone(), w, "webhook", inputs).map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    Ok(Json(json!({ "run_id": run_id })))
}

// ---------------------------------------------------------------- web push

pub(crate) fn urlencode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[derive(Deserialize)]
struct PushQuery {
    endpoint: Option<String>,
}

async fn push_info(State(app): State<Arc<AppState>>, axum::extract::Query(q): axum::extract::Query<PushQuery>) -> Json<Value> {
    let subscribed = q.endpoint.as_deref().is_some_and(|e| app.push.has(e));
    let apns = app.push.apns.as_ref().map(|a| json!({ "devices": a.count() }));
    Json(json!({ "key": app.push.public_key, "devices": app.push.count(), "subscribed": subscribed, "apns": apns }))
}

#[derive(Deserialize)]
struct ApnsReq {
    token: String,
    #[serde(default)]
    environment: apns::Env,
    #[serde(default)]
    label: String,
}

/// The iOS app's device token, sent each launch after notification permission.
async fn apns_register(State(app): State<Arc<AppState>>, Json(req): Json<ApnsReq>) -> AppResult<Json<Value>> {
    let a = app.push.apns.as_ref().ok_or_else(|| {
        err(StatusCode::SERVICE_UNAVAILABLE, "no APNs key on the server (~/.config/pocketpi/apns/AuthKey_<KEYID>.p8)")
    })?;
    if !apns::valid_token(&req.token) {
        return Err(err(StatusCode::BAD_REQUEST, "not an APNs device token"));
    }
    let label: String = req.label.chars().take(60).collect();
    a.register(&req.token, req.environment, &label);
    Ok(Json(json!({ "ok": true, "devices": a.count() })))
}

#[derive(Deserialize)]
struct ApnsUnreq {
    token: String,
}

async fn apns_unregister(State(app): State<Arc<AppState>>, Json(req): Json<ApnsUnreq>) -> Json<Value> {
    if let Some(a) = &app.push.apns {
        a.unregister(&req.token);
    }
    Json(json!({ "ok": true }))
}

#[derive(Deserialize)]
struct SubReq {
    subscription: Value,
    #[serde(default)]
    label: String,
}

async fn push_subscribe(State(app): State<Arc<AppState>>, Json(req): Json<SubReq>) -> AppResult<Json<Value>> {
    let sub = push::sub_from_json(&req.subscription, &req.label).ok_or_else(|| err(StatusCode::BAD_REQUEST, "invalid subscription"))?;
    let host = sub.endpoint.split('/').nth(2).unwrap_or("").to_string();
    // Only real push services, so this can't be pointed at arbitrary URLs.
    let known = ["push.apple.com", "fcm.googleapis.com", "push.services.mozilla.com", "notify.windows.com", "web.push.apple.com"];
    if !sub.endpoint.starts_with("https://") || !known.iter().any(|k| host == *k || host.ends_with(&format!(".{k}"))) {
        return Err(err(StatusCode::BAD_REQUEST, format!("unexpected push service {host}")));
    }
    app.push.subscribe(sub);
    Ok(Json(json!({ "ok": true, "devices": app.push.count() })))
}

#[derive(Deserialize)]
struct UnsubReq {
    endpoint: String,
}

async fn push_unsubscribe(State(app): State<Arc<AppState>>, Json(req): Json<UnsubReq>) -> Json<Value> {
    app.push.unsubscribe(&req.endpoint);
    Json(json!({ "ok": true }))
}

async fn push_test(State(app): State<Arc<AppState>>) -> Json<Value> {
    let n = app.push.send("pocketpi", "Notifications are working.", "/", "test").await;
    Json(json!({ "delivered": n }))
}

// ---------------------------------------------------------------- self-improvement

fn changed(app: &AppState) {
    let _ = app.engine.tx.send(Arc::from(json!({"type": "workflows_changed"}).to_string().as_str()));
}

#[derive(Deserialize)]
struct ImproveReq {
    mode: workflows::Improve,
}

async fn set_improve(State(app): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<ImproveReq>) -> AppResult<Json<Value>> {
    let mut w = workflows::load(&app.engine.workflows_dir, &id).ok_or_else(|| err(StatusCode::NOT_FOUND, "workflow not found"))?;
    w.improve = req.mode;
    workflows::save(&app.engine.workflows_dir, &w).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    changed(&app);
    Ok(Json(json!({ "ok": true })))
}

/// "Improve now": reflect on the latest finished run regardless of mode.
async fn reflect_now(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    let run = app
        .engine
        .list_runs(Some(&id))
        .into_iter()
        .find(|r| r.ended.is_some())
        .ok_or_else(|| err(StatusCode::CONFLICT, "run it at least once first"))?;
    let app2 = app.clone();
    tokio::spawn(async move {
        let r = improve::after_run(app2.clone(), run, true).await;
        let msg = match &r {
            Ok(m) => m.clone(),
            Err(e) => format!("failed: {e}"),
        };
        eprintln!("improve (manual): {msg}");
        let _ = app2.engine.tx.send(Arc::from(json!({"type": "improve_done", "workflow_id": id, "result": msg}).to_string().as_str()));
    });
    Ok(Json(json!({ "ok": true })))
}

async fn apply_proposal(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    let dir = &app.engine.workflows_dir;
    let p = workflows::proposal_path(dir, &id);
    let v: Value = serde_json::from_str(&std::fs::read_to_string(&p).map_err(|_| err(StatusCode::NOT_FOUND, "no proposal"))?).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let wf: workflows::Workflow = serde_json::from_value(v["workflow"].clone()).map_err(|e| err(StatusCode::BAD_REQUEST, e.to_string()))?;
    let errors = workflows::validate(&wf);
    if !errors.is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, errors.join("; ")));
    }
    let summary = v["changes"].as_array().map(|a| a.iter().filter_map(|c| c["summary"].as_str()).collect::<Vec<_>>().join("; ")).unwrap_or_default();
    workflows::save_versioned(dir, &wf, &format!("applied suggestion: {summary}")).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    let _ = std::fs::remove_file(p);
    changed(&app);
    Ok(Json(json!({ "ok": true })))
}

async fn dismiss_proposal(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> Json<Value> {
    let _ = std::fs::remove_file(workflows::proposal_path(&app.engine.workflows_dir, &id));
    changed(&app);
    Json(json!({ "ok": true }))
}

#[derive(Deserialize)]
struct RevertReq {
    version: String,
}

async fn revert_workflow(State(app): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<RevertReq>) -> AppResult<Json<Value>> {
    let dir = &app.engine.workflows_dir;
    let mut old = workflows::load_version(dir, &id, &req.version).ok_or_else(|| err(StatusCode::NOT_FOUND, "version not found"))?;
    // Reverting restores the definition, not the on/off switch.
    if let Some(cur) = workflows::load(dir, &id) {
        old.enabled = cur.enabled;
    }
    workflows::save_versioned(dir, &old, &format!("reverted to the version from {}", req.version)).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    changed(&app);
    Ok(Json(json!({ "ok": true })))
}
