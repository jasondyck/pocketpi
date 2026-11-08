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
mod pi_admin;
mod pi_cli;
mod pi_providers;
mod ext_ui;
mod pi_resources;
mod dialogs;
mod safety;
mod json_schema;
mod pi_context;
mod pi_settings_raw;
use ext_ui::ExtUi;

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
    // Sessions: forking and cloning change the pi's session file, which the
    // server follows (see `follow_session_file`).
    "fork",
    "get_fork_messages",
    "clone",
    "get_tree",
    "get_entries",
    "export_html",
    "get_last_assistant_text",
    // `!cmd` / `!!cmd` from the composer.
    "bash",
    "abort_bash",
    // These four change pi's global settings.json, not just this chat.
    "set_auto_compaction",
    "set_auto_retry",
    "set_steering_mode",
    "set_follow_up_mode",
    // Never: cycle_model (changes the default model), new_session and
    // switch_session (a pi that moves to another file breaks the
    // live key <-> session file mapping pocketpi's identity rests on).
];

/// RPC setters that write pi's global settings.json: after one, every other
/// pi is running with old settings (see `config_epoch`).
const GLOBAL_SETTERS: &[&str] = &["set_auto_compaction", "set_auto_retry", "set_steering_mode", "set_follow_up_mode"];

/// `pocketpi-control` commands a client may run through `/api/s/{key}/control`
/// (each is the extension's `/pp-<name>`).
const CONTROL_COMMANDS: &[&str] = &["tools"];

/// The `customType` of pocketpi-control's reply entries.
const CONTROL_REPLY: &str = "pocketpi-control";

/// The companion extension, written to pocketpi's data folder at startup and
/// loaded into normal chat pis with `-e`.
const CONTROL_EXTENSION: &str = include_str!("../extensions/pocketpi-control.ts");

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
    /// pi's config files; its epoch says which pis run with old settings.
    pub(crate) admin: pi_admin::Admin,
    pub(crate) jobs: Arc<pi_cli::Jobs>,
    /// `pocketpi-control.ts` on disk, or None when turned off
    /// (`POCKETPI_CONTROL=0`) or it couldn't be written.
    pub(crate) control_ext: Option<PathBuf>,
    /// Where `export_html` writes (never a path a client picks).
    pub(crate) exports_dir: PathBuf,
}

/// What a live pi is for; restarts, reloads and the control extension only
/// apply to chats.
#[derive(Clone, Copy, PartialEq, Eq, Debug, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// A normal chat (Work tab, the web UI).
    Chat,
    /// The app's Chat tab: pi without tools.
    ChatTab,
    /// A workflow stage, driven by the engine.
    Stage,
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
    pub(crate) kind: Kind,
    /// The config epoch this pi started with (or caught up to by changing a
    /// global setting itself). Below the current one: "Restart to apply".
    pub(crate) epoch: AtomicU64,
    /// Being replaced by `/restart`: its exit is expected, and requests for
    /// its key wait for the new process instead of failing.
    pub(crate) restarting: AtomicBool,
    pub(crate) exited: AtomicBool,
    /// Started with `-e pocketpi-control.ts`.
    pub(crate) control: bool,
    /// Whether pi actually registered the /pp-* commands: 0 not checked yet,
    /// 1 yes, 2 no. Checked once before the first control call, so a failed
    /// extension load can't turn "/pp-tools ..." into a prompt for the model.
    pub(crate) control_ok: std::sync::atomic::AtomicU8,
    /// The extensions' setStatus / setWidget / setTitle requests still in
    /// effect, replayed in `pocketpi_hello`: extensions often set them at
    /// startup, before any client is listening.
    pub(crate) ext_ui: StdMutex<ExtUi>,
    /// A title was looked at for this chat (asked for once per pi process).
    pub(crate) titled: AtomicBool,
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
    // Resolved once (macOS /var is /private/var): archive and delete store
    // canonical paths, and the session list must name files the same way.
    let sessions_dir = std::fs::canonicalize(&sessions_dir).unwrap_or(sessions_dir);
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
    let data_dir = std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".local/share")).join("pocketpi");
    let control_ext = install_control_extension(&data_dir);
    let app = Arc::new(AppState {
        admin: pi_admin::Admin::new(agent_dir.clone()),
        jobs: Arc::new(pi_cli::Jobs::default()),
        control_ext,
        exports_dir: data_dir.join("exports"),
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
        .route("/manage.js", get(|| async { static_file("manage.js") }))
        .route("/chat-tools.js", get(|| async { static_file("chat-tools.js") }))
        .route("/manage/{file}", get(manage_page_file))
        .route("/api/manage/pages", get(|| async { Json(json!({ "pages": MANAGE_PAGES.iter().map(|p| p.0).collect::<Vec<_>>() })) }))
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
        .route("/api/s/{key}/restart", post(restart_session))
        .route("/api/s/{key}/control", post(control))
        .route("/api/pi/status", get(pi_status))
        .route("/api/pi/reload", post(reload_pis))
        .route("/api/pi/config/{file}", get(read_config).post(patch_config))
        .route("/api/pi/jobs", get(list_jobs).post(start_job))
        .route("/api/pi/jobs/{id}", get(get_job))
        .route("/api/pi/version", get(pi_version))
        .route("/api/pi/auth/{provider}", get(auth_check))
        .route("/api/pi/mcp", get(mcp_list))
        .route("/api/pi/packages", get(package_list))
        .route("/api/pi/providers", get(pi_providers::list))
        .route("/api/pi/providers/{id}/key", post(pi_providers::set_key))
        .route("/api/pi/providers/{id}/remove", post(pi_providers::remove_key))
        .merge(pi_resources::router())
        .merge(pi_context::router())
        .merge(pi_settings_raw::router())
        .route("/api/safety", get(safety::info))
        .route("/api/safety/recommended", post(safety::use_recommended))
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

/// One Settings page: `manage_page!("x")` embeds `web/manage-x.js`, served
/// at `/manage/x.js` and listed by `/api/manage/pages` (docs/pi-parity-plan.md §7).
macro_rules! manage_page {
    ($id:literal) => {
        ($id, include_bytes!(concat!("../web/manage-", $id, ".js")) as &[u8])
    };
}

/// The Settings hub's pages, one line each. The hub sorts them by their own
/// `order`, so the order here doesn't matter: add new lines at the end.
const MANAGE_PAGES: &[(&str, &[u8])] = &[
    manage_page!("about"),
    manage_page!("providers"),
    manage_page!("settings"),
    manage_page!("trust"),
    manage_page!("resources"),
    manage_page!("safety"),
    manage_page!("context"),
];

async fn manage_page_file(Path(file): Path<String>) -> Response {
    let Some((_, body)) = MANAGE_PAGES.iter().find(|(id, _)| file.strip_suffix(".js") == Some(id)) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mut res = body.into_response();
    let hs = res.headers_mut();
    hs.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/javascript; charset=utf-8"));
    hs.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"));
    res
}

fn static_file(name: &str) -> Response {
    let (body, ctype): (&'static [u8], &str) = match name {
        "index.html" => (include_bytes!("../web/index.html"), "text/html; charset=utf-8"),
        "app.js" => (include_bytes!("../web/app.js"), "text/javascript; charset=utf-8"),
        "app.css" => (include_bytes!("../web/app.css"), "text/css; charset=utf-8"),
        "manage.js" => (include_bytes!("../web/manage.js"), "text/javascript; charset=utf-8"),
        "chat-tools.js" => (include_bytes!("../web/chat-tools.js"), "text/javascript; charset=utf-8"),
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

/// Drops `live` from the registry, unless its key already belongs to the pi
/// that replaced it.
fn unregister(app: &AppState, live: &Arc<Live>) {
    let mut map = app.live.lock().unwrap();
    if map.get(&live.key).is_some_and(|l| Arc::ptr_eq(l, live)) {
        map.remove(&live.key);
    }
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

/// Writes the embedded `pocketpi-control.ts` where chat pis load it from,
/// only when it changed (pi reads it fresh at each start).
fn install_control_extension(data_dir: &std::path::Path) -> Option<PathBuf> {
    if std::env::var("POCKETPI_CONTROL").is_ok_and(|v| v == "0") {
        return None;
    }
    let path = data_dir.join("pocketpi-control.ts");
    if std::fs::read_to_string(&path).ok().as_deref() != Some(CONTROL_EXTENSION) {
        let tmp = path.with_extension("ts.tmp");
        let ok = std::fs::create_dir_all(data_dir).is_ok()
            && std::fs::write(&tmp, CONTROL_EXTENSION).is_ok()
            && std::fs::rename(&tmp, &path).is_ok();
        if !ok {
            eprintln!("couldn't write {}; chats run without pocketpi-control", path.display());
            return None;
        }
    }
    Some(path)
}

/// A chat's pi (new or reopened): the Chat tab's without tools, every other
/// one with the pocketpi-control extension.
async fn spawn_pi(app: &Arc<AppState>, cwd: &str, session: Option<&str>) -> AppResult<Arc<Live>> {
    let kind = if is_chat_dir(app, cwd) { Kind::ChatTab } else { Kind::Chat };
    spawn_live(app, cwd, session, &[], kind, None).await
}

/// A workflow stage's pi (the engine adds its own flags).
pub async fn spawn_pi_with(app: &Arc<AppState>, cwd: &str, session: Option<&str>, extra: &[String]) -> AppResult<Arc<Live>> {
    spawn_live(app, cwd, session, extra, Kind::Stage, None).await
}

/// Starts a pi and registers it. `key` reuses a live key (restart), so the
/// clients that had the chat open reconnect to the same URL.
async fn spawn_live(
    app: &Arc<AppState>,
    cwd: &str,
    session: Option<&str>,
    extra: &[String],
    kind: Kind,
    key: Option<String>,
) -> AppResult<Arc<Live>> {
    let mut cmd = Command::new(&app.pi_bin);
    cmd.arg("--mode").arg("rpc");
    if let Some(s) = session {
        cmd.arg("--session").arg(s);
    }
    // The Chat tab: a conversation, not a coding agent (also on reopen).
    if kind == Kind::ChatTab {
        cmd.arg("--no-tools").arg("--system-prompt").arg(CHAT_SYSTEM_PROMPT);
    }
    let control = kind == Kind::Chat && app.control_ext.is_some();
    if control {
        cmd.arg("-e").arg(app.control_ext.as_ref().unwrap());
    }
    cmd.args(extra);
    if kind == Kind::Stage {
        safety::stage_command(app, cwd, &mut cmd);
    }
    cmd.current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd
        .spawn()
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, format!("failed to start pi: {e}")))?;

    let key = key.unwrap_or_else(|| {
        format!(
            "{:x}{:x}",
            app.next_key.fetch_add(1, Ordering::Relaxed),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        )
    });
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
        kind,
        epoch: AtomicU64::new(app.admin.epoch()),
        restarting: AtomicBool::new(false),
        exited: AtomicBool::new(false),
        control,
        control_ok: std::sync::atomic::AtomicU8::new(0),
        ext_ui: StdMutex::new(ExtUi::default()),
        titled: AtomicBool::new(false),
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
            let dialog = (ty == "extension_ui_request" && live2.kind != Kind::Stage).then(|| v.clone());
            handle_record(&live2, line, v);
            if let Some(d) = dialog {
                dialogs::opened(&app2, &live2, d);
            }
            match ty.as_str() {
                "agent_start" => {
                    let mut t = live2.turn_started.lock().unwrap();
                    if t.is_none() {
                        *t = Some(Instant::now());
                    }
                }
                "agent_settled" => {
                    live2.ext_ui.lock().unwrap().dialogs.clear();
                    // The first reply in an unnamed chat: give it a title.
                    if !live2.titled.swap(true, Ordering::Relaxed) {
                        let (app3, live3) = (app2.clone(), live2.clone());
                        tokio::spawn(async move { auto_title(&app3, &live3).await });
                    }
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
        live2.exited.store(true, Ordering::Relaxed);
        // A restart already told the clients (`restarting: true`) and keeps
        // the key registered until the new pi takes it over.
        if live2.restarting.load(Ordering::Relaxed) {
            return;
        }
        let tail: Vec<String> = live2.stderr_tail.lock().unwrap().iter().cloned().collect();
        let exit = json!({"type": "pocketpi_exit", "stderr": tail}).to_string();
        let _ = live2.tx.send(Arc::from(exit.as_str()));
        unregister(&app2, &live2);
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
    // pocketpi-control's answers go to the waiting /control call, not to
    // the clients' event stream.
    if ty == "entry_appended" && v.pointer("/entry/customType").and_then(Value::as_str) == Some(CONTROL_REPLY) {
        let data = v.pointer("/entry/data").cloned().unwrap_or(Value::Null);
        if let Some(req) = data.get("reqId").and_then(Value::as_str) {
            if let Some(tx) = live.pending.lock().unwrap().remove(req) {
                let _ = tx.send(data);
            }
        }
        return;
    }
    if ty == "extension_ui_request" {
        live.ext_ui.lock().unwrap().record(&v);
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
    Json(mut cmd): Json<Value>,
) -> AppResult<Json<Value>> {
    let live = get_live_ready(&app, &key).await?;
    let ty = cmd.get("type").and_then(Value::as_str).unwrap_or("").to_string();
    // /pp-* is pocketpi's channel to its extension (POST .../control).
    if ty == "prompt" && cmd.get("message").and_then(Value::as_str).is_some_and(|m| m.trim_start().starts_with("/pp-")) {
        return Err(err(StatusCode::BAD_REQUEST, "/pp-* commands are pocketpi's own; use /control"));
    }
    // pi writes the export wherever it's told: only ever into our folder.
    if ty == "export_html" {
        let _ = std::fs::create_dir_all(&app.exports_dir);
        let ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis();
        let name = format!("{}-{ms}.html", live.key);
        cmd["outputPath"] = json!(app.exports_dir.join(name));
    }
    if ty == "extension_ui_response" {
        if let Some(id) = cmd.get("id").and_then(Value::as_str) {
            live.ext_ui.lock().unwrap().dialogs.answered(id);
        }
    }
    let epoch_before = app.admin.epoch();
    let mut resp = rpc(&live, cmd).await?;
    let ok = resp.get("success") != Some(&Value::Bool(false));
    match ty.as_str() {
        "get_commands" => {
            if let Some(list) = resp.pointer_mut("/data/commands").and_then(Value::as_array_mut) {
                list.retain(|c| !c.get("name").and_then(Value::as_str).is_some_and(|n| n.starts_with("pp-")));
            }
        }
        "get_entries" => {
            if let Some(list) = resp.pointer_mut("/data/entries").and_then(Value::as_array_mut) {
                list.retain(|e| e.get("customType").and_then(Value::as_str) != Some(CONTROL_REPLY));
            }
        }
        "fork" | "clone" if ok && resp.pointer("/data/cancelled") != Some(&Value::Bool(true)) => {
            follow_session_file(&live).await;
        }
        t if ok && GLOBAL_SETTERS.contains(&t) => {
            // pi rewrote settings.json: every other pi is now behind; this
            // one has the change already.
            let now = app.admin.bump();
            let _ = live.epoch.compare_exchange(epoch_before, now, Ordering::Relaxed, Ordering::Relaxed);
        }
        _ => {}
    }
    Ok(Json(resp))
}

/// After `fork` or `clone` pi writes to a new session file. Ask it which,
/// remember it (it is this chat's identity now) and tell the clients, which
/// re-key their view of the chat to the new file.
async fn follow_session_file(live: &Live) {
    let _ = rpc_internal(live, json!({"type": "get_state"})).await;
    if let Some(file) = live.session_file() {
        let msg = json!({"type": "pocketpi_session", "file": file}).to_string();
        let _ = live.tx.send(Arc::from(msg.as_str()));
    }
}

/// Like `get_live`, but a chat in the middle of `/restart` is waited for, so
/// a client that reconnects at once gets the new pi rather than a 404.
async fn get_live_ready(app: &AppState, key: &str) -> AppResult<Arc<Live>> {
    for _ in 0..150 {
        let live = get_live(app, key)?;
        if !live.restarting.load(Ordering::Relaxed) {
            return Ok(live);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(err(StatusCode::SERVICE_UNAVAILABLE, "pi is restarting"))
}

async fn events(State(app): State<Arc<AppState>>, Path(key): Path<String>) -> AppResult<impl IntoResponse> {
    let live = get_live_ready(&app, &key).await?;
    let rx = live.tx.subscribe();
    let epoch = live.epoch.load(Ordering::Relaxed);
    let config_epoch = app.admin.epoch();
    let hello = json!({
        "type": "pocketpi_hello",
        "streaming": live.streaming.load(Ordering::Relaxed),
        // Below config_epoch: settings changed since this pi started.
        "epoch": epoch,
        "config_epoch": config_epoch,
        "stale": epoch < config_epoch,
        "kind": live.kind,
        "ui": live.ext_ui.lock().unwrap().replay(),
        // Dialogs still waiting for an answer (a notification opened the chat).
        "dialogs": live.ext_ui.lock().unwrap().dialogs.pending(Instant::now()),
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

// ---------------------------------------------------------------- restart, reload, control

/// Replaces a chat's pi with a fresh one on the same session file and the
/// same key, so it picks up changed settings, credentials, packages, MCP
/// servers or models. Clients get `pocketpi_exit` with `restarting: true`
/// and reconnect to the same key; requests in between wait for the new pi.
async fn restart_live(app: &Arc<AppState>, live: Arc<Live>) -> AppResult<Arc<Live>> {
    if live.kind == Kind::Stage {
        return Err(err(StatusCode::CONFLICT, "workflow stages can't be restarted"));
    }
    if live.streaming.load(Ordering::Relaxed) {
        return Err(err(StatusCode::CONFLICT, "pi is replying in this chat; stop it first"));
    }
    if live.restarting.swap(true, Ordering::Relaxed) {
        return Err(err(StatusCode::CONFLICT, "already restarting"));
    }
    let file = live.session_file();
    let msg = json!({"type": "pocketpi_exit", "restarting": true, "stderr": []}).to_string();
    let _ = live.tx.send(Arc::from(msg.as_str()));
    live.stdin.lock().await.take();
    for _ in 0..100 {
        if live.exited.load(Ordering::Relaxed) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let fail = |e: (StatusCode, String)| {
        // Nothing will take the key over: let it go like a normal exit.
        unregister(app, &live);
        e
    };
    if !live.exited.load(Ordering::Relaxed) {
        return Err(fail(err(StatusCode::GATEWAY_TIMEOUT, "pi didn't stop")));
    }
    spawn_live(app, &live.cwd, file.as_deref(), &[], live.kind, Some(live.key.clone())).await.map_err(fail)
}

async fn restart_session(State(app): State<Arc<AppState>>, Path(key): Path<String>) -> AppResult<Json<Value>> {
    let live = get_live_ready(&app, &key).await?;
    let new = restart_live(&app, live).await?;
    Ok(Json(json!({ "key": new.key, "file": new.session_file(), "epoch": new.epoch.load(Ordering::Relaxed) })))
}

#[derive(Deserialize, Default)]
struct ReloadReq {
    /// Restart every idle chat, not only the ones behind the config epoch.
    #[serde(default)]
    all: bool,
}

/// "Apply": restarts the idle chat pis that started before the last config
/// change (or all idle ones with `all`). Busy ones are listed so the clients
/// can keep showing "Restart to apply" on them. Workflow stages are left be.
async fn reload_pis(State(app): State<Arc<AppState>>, body: Option<Json<ReloadReq>>) -> Json<Value> {
    let all = body.map(|b| b.0.all).unwrap_or(false);
    let current = app.admin.epoch();
    let lives: Vec<Arc<Live>> = app.live.lock().unwrap().values().filter(|l| l.kind != Kind::Stage).cloned().collect();
    let (mut busy, mut tasks) = (Vec::new(), Vec::new());
    for l in lives {
        if l.restarting.load(Ordering::Relaxed) || !(all || l.epoch.load(Ordering::Relaxed) < current) {
            continue;
        }
        if l.streaming.load(Ordering::Relaxed) {
            busy.push(l.key.clone());
            continue;
        }
        let app = app.clone();
        tasks.push(tokio::spawn(async move { (l.key.clone(), restart_live(&app, l).await.map(|_| ())) }));
    }
    let (mut restarted, mut failed) = (Vec::new(), Vec::new());
    for t in tasks {
        if let Ok((key, r)) = t.await {
            match r {
                Ok(()) => restarted.push(json!(key)),
                Err((StatusCode::CONFLICT, _)) => busy.push(key),
                Err((_, e)) => failed.push(json!({ "key": key, "error": e })),
            }
        }
    }
    Json(json!({ "restarted": restarted, "busy": busy, "failed": failed, "config_epoch": app.admin.epoch() }))
}

/// Which pis are running and whether each has the latest config.
async fn pi_status(State(app): State<Arc<AppState>>) -> Json<Value> {
    let current = app.admin.epoch();
    let live: Vec<Value> = app
        .live
        .lock()
        .unwrap()
        .values()
        .map(|l| {
            let epoch = l.epoch.load(Ordering::Relaxed);
            json!({
                "key": l.key, "file": l.session_file(), "cwd": l.cwd, "kind": l.kind,
                "streaming": l.streaming.load(Ordering::Relaxed), "epoch": epoch, "stale": epoch < current,
            })
        })
        .collect();
    Json(json!({ "config_epoch": current, "live": live, "control": app.control_ext.is_some() }))
}

#[derive(Deserialize)]
struct ControlReq {
    command: String,
    #[serde(default)]
    args: Option<Value>,
}

/// Runs a pocketpi-control command (`/pp-<command> <reqId> [args]`) in the
/// chat's pi and waits for its reply entry. Answers like `/cmd`:
/// `{success, data}` or `{success: false, error}`.
async fn control(State(app): State<Arc<AppState>>, Path(key): Path<String>, Json(req): Json<ControlReq>) -> AppResult<Json<Value>> {
    let live = get_live_ready(&app, &key).await?;
    if !CONTROL_COMMANDS.contains(&req.command.as_str()) {
        return Err(err(StatusCode::BAD_REQUEST, format!("unknown control command: {}", req.command)));
    }
    if !live.control {
        return Err(err(StatusCode::CONFLICT, "this pi runs without pocketpi-control (Chat tab, workflow stage, or turned off)"));
    }
    let name = format!("pp-{}", req.command);
    if live.control_ok.load(Ordering::Relaxed) == 0 {
        let r = rpc_internal(&live, json!({"type": "get_commands"})).await?;
        let has = r
            .pointer("/data/commands")
            .and_then(Value::as_array)
            .is_some_and(|l| l.iter().any(|c| c.get("name").and_then(Value::as_str) == Some(name.as_str())));
        live.control_ok.store(if has { 1 } else { 2 }, Ordering::Relaxed);
    }
    if live.control_ok.load(Ordering::Relaxed) != 1 {
        return Err(err(StatusCode::CONFLICT, "pocketpi-control didn't load in this pi (see the server log)"));
    }
    let req_id = format!("ctl-{}", live.seq.fetch_add(1, Ordering::Relaxed));
    let (tx, rx) = oneshot::channel();
    live.pending.lock().unwrap().insert(req_id.clone(), tx);
    let mut message = format!("/{name} {req_id}");
    if let Some(args) = req.args.filter(|a| !a.is_null()) {
        message.push(' ');
        message.push_str(&args.to_string());
    }
    let sent = rpc_internal(&live, json!({"type": "prompt", "message": message})).await;
    let drop_waiter = || live.pending.lock().unwrap().remove(&req_id);
    match sent {
        Err(e) => {
            drop_waiter();
            return Err(e);
        }
        Ok(r) if r.get("success") == Some(&Value::Bool(false)) => {
            drop_waiter();
            return Ok(Json(json!({ "success": false, "error": r.get("error").cloned().unwrap_or(json!("pi refused the command")) })));
        }
        Ok(_) => {}
    }
    let reply = match tokio::time::timeout(Duration::from_secs(30), rx).await {
        Ok(Ok(v)) => v,
        Ok(Err(_)) => return Err(err(StatusCode::GONE, "pi exited")),
        Err(_) => {
            drop_waiter();
            return Err(err(StatusCode::GATEWAY_TIMEOUT, "pocketpi-control did not answer"));
        }
    };
    // The reply entry's {reqId, ok, data|error}, or the {success:false}
    // every waiter gets when pi exits.
    let ok = reply.get("ok").or(reply.get("success")).and_then(Value::as_bool).unwrap_or(false);
    Ok(Json(if ok {
        json!({ "success": true, "data": reply.get("data").cloned().unwrap_or(Value::Null) })
    } else {
        json!({ "success": false, "error": reply.get("error").cloned().unwrap_or(json!("failed")) })
    }))
}

// ---------------------------------------------------------------- pi's config files and CLI

#[derive(Deserialize)]
struct ConfigQuery {
    /// A project folder: its `.pi/settings.json` / `.pi/mcp.json`.
    #[serde(default)]
    cwd: Option<String>,
}

fn admin_err(e: pi_admin::AdminError) -> (StatusCode, String) {
    match e {
        pi_admin::AdminError::Bad(m) => err(StatusCode::BAD_REQUEST, m),
        pi_admin::AdminError::Unreadable(m) => err(StatusCode::UNPROCESSABLE_ENTITY, m),
        pi_admin::AdminError::Io(m) => err(StatusCode::INTERNAL_SERVER_ERROR, m),
    }
}

fn config_file(name: &str) -> AppResult<pi_admin::File> {
    pi_admin::File::parse(name).ok_or_else(|| err(StatusCode::NOT_FOUND, format!("unknown config file: {name}")))
}

async fn read_config(
    State(app): State<Arc<AppState>>,
    Path(file): Path<String>,
    axum::extract::Query(q): axum::extract::Query<ConfigQuery>,
) -> AppResult<Json<Value>> {
    let file = config_file(&file)?;
    Ok(Json(app.admin.read(file, q.cwd.as_deref()).map_err(admin_err)?))
}

async fn patch_config(
    State(app): State<Arc<AppState>>,
    Path(file): Path<String>,
    axum::extract::Query(q): axum::extract::Query<ConfigQuery>,
    Json(patch): Json<pi_admin::Patch>,
) -> AppResult<Json<Value>> {
    let file = config_file(&file)?;
    let before = app.admin.epoch();
    let v = app.admin.patch(file, q.cwd.as_deref(), &patch).map_err(admin_err)?;
    if app.admin.epoch() != before {
        config_changed(&app);
    }
    Ok(Json(v))
}

/// Tells the runs stream (every client listens) that pi's config changed, so
/// chats can show "Restart to apply".
fn config_changed(app: &AppState) {
    let msg = json!({"type": "config_changed", "config_epoch": app.admin.epoch()}).to_string();
    let _ = app.engine.tx.send(Arc::from(msg.as_str()));
}

async fn start_job(State(app): State<Arc<AppState>>, Json(action): Json<pi_cli::Action>) -> AppResult<Json<Value>> {
    let cwd = pi_cli::resolve_cwd(&action, &app.home).map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    let app2 = app.clone();
    let id = pi_cli::start(app.jobs.clone(), app.pi_bin.clone(), action, cwd, app.engine.tx.clone(), move |changed| {
        if changed {
            app2.admin.bump();
            config_changed(&app2);
        }
    })
    .map_err(|e| err(if e.contains("another pi job") { StatusCode::CONFLICT } else { StatusCode::BAD_REQUEST }, e))?;
    Ok(Json(json!({ "id": id })))
}

async fn list_jobs(State(app): State<Arc<AppState>>) -> Json<Value> {
    Json(json!({ "jobs": app.jobs.recent() }))
}

async fn get_job(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    let job = app.jobs.get(&id).ok_or_else(|| err(StatusCode::NOT_FOUND, "job not found"))?;
    Ok(Json(json!({ "job": job })))
}

async fn quick(app: &AppState, action: pi_cli::Action) -> AppResult<Json<Value>> {
    let cwd = pi_cli::resolve_cwd(&action, &app.home).map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    let v = pi_cli::run_quick(&app.pi_bin, &action, &cwd).await.map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    Ok(Json(v))
}

/// `pi --version`: `{code, stdout, ...}`, plus `version` trimmed.
async fn pi_version(State(app): State<Arc<AppState>>) -> AppResult<Json<Value>> {
    let Json(mut v) = quick(&app, pi_cli::Action::Version).await?;
    v["version"] = json!(v["stdout"].as_str().unwrap_or("").trim());
    Ok(Json(v))
}

/// `pi auth check --provider X --json`: `json` is pi's `{status, provider, reason?}`.
async fn auth_check(State(app): State<Arc<AppState>>, Path(provider): Path<String>) -> AppResult<Json<Value>> {
    quick(&app, pi_cli::Action::AuthCheck { provider }).await
}

/// `pi mcp list --json` (connects to every enabled server; can take a while).
async fn mcp_list(State(app): State<Arc<AppState>>, axum::extract::Query(q): axum::extract::Query<ConfigQuery>) -> AppResult<Json<Value>> {
    quick(&app, pi_cli::Action::McpList { cwd: q.cwd }).await
}

/// `pi list` (text; pi has no JSON form of it).
async fn package_list(State(app): State<Arc<AppState>>, axum::extract::Query(q): axum::extract::Query<ConfigQuery>) -> AppResult<Json<Value>> {
    quick(&app, pi_cli::Action::List { cwd: q.cwd }).await
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
            s.epoch = Some(l.epoch.load(Ordering::Relaxed));
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
    Json(json!({ "sessions": list, "chat_dir": app.chat_dir, "config_epoch": app.admin.epoch() }))
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

/// One `pi -p` call: no tools, context files, skills, extensions (except for
/// a local model) or session, so only the prompt reaches the model and the
/// API key never leaves pi.
async fn one_shot(app: &AppState, model: &str, system: &str, prompt: &str) -> AppResult<String> {
    // llama.cpp models come from pi's built-in llama extension, so a local
    // model needs extensions on; it also skips thinking (a local reasoning
    // model would think for a long time about a title).
    let local = model.starts_with("llama.cpp/");
    let mut cmd = Command::new(&app.pi_bin);
    cmd.args(["--no-session", "-p", "--model", model, "--thinking", if local { "off" } else { "low" }])
        .args(["--no-tools", "--no-context-files", "--no-skills", "--no-prompt-templates"]);
    if !local {
        cmd.arg("--no-extensions");
    }
    let run = cmd
        .arg("--system-prompt")
        .arg(system)
        .arg(prompt)
        .current_dir(std::env::temp_dir())
        .env("PI_OFFLINE", "1")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(45), run)
        .await
        .map_err(|_| err(StatusCode::GATEWAY_TIMEOUT, "pi timed out"))?
        .map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, format!("pi: {e}")))?;
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

const TITLE_PROMPT: &str = "You name chats. Given the user's first message and the assistant's first reply, \
write a title of 3 to 6 words that says what the chat is about, like an email subject. \
Use the user's language. Plain text only: no quotes, no emoji, no trailing punctuation, no 'Chat about'. \
Output ONLY the title.";

/// The text of a pi message (its text blocks joined).
fn message_text(m: &Value) -> String {
    match &m["content"] {
        Value::String(s) => s.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter(|p| p["type"] == "text")
            .filter_map(|p| p["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// A model's title, tidied: first line, no quotes or trailing dot, at most
/// 60 characters. None when nothing usable came back.
fn clean_title(raw: &str) -> Option<String> {
    let line = raw.lines().map(str::trim).find(|l| !l.is_empty())?;
    let line = line.strip_prefix("Title:").unwrap_or(line).trim();
    let t: String = line
        .trim_matches(|c: char| matches!(c, '"' | '\'' | '“' | '”' | '‘' | '’' | '*' | '#' | '`'))
        .trim_end_matches(['.', '!', ':', ';'])
        .trim()
        .chars()
        .take(60)
        .collect();
    (t.chars().count() >= 2).then_some(t)
}

/// Name an unnamed chat after its first exchange. A name set meanwhile (by
/// the person, pi or a workflow) always wins. A chat on a local llama.cpp
/// model is titled by that model, so its words stay on the machine.
async fn auto_title(app: &Arc<AppState>, live: &Arc<Live>) {
    let name_of = |st: &Value| st.pointer("/data/sessionName").and_then(Value::as_str).unwrap_or("").trim().to_string();
    let Ok(st) = rpc_internal(live, json!({"type": "get_state"})).await else { return };
    if !name_of(&st).is_empty() {
        return;
    }
    let model = match (st.pointer("/data/model/provider").and_then(Value::as_str), st.pointer("/data/model/id").and_then(Value::as_str)) {
        (Some("llama.cpp"), Some(id)) => format!("llama.cpp/{id}"),
        _ => app.suggest_model.clone(),
    };
    let Ok(msgs) = rpc_internal(live, json!({"type": "get_messages"})).await else { return };
    let list = msgs.pointer("/data/messages").and_then(Value::as_array).cloned().unwrap_or_default();
    let first = |role: &str| list.iter().find(|m| m["role"] == role && !message_text(m).trim().is_empty()).map(message_text);
    let (Some(user), Some(reply)) = (first("user"), first("assistant")) else { return };
    let prompt = format!(
        "USER'S FIRST MESSAGE:\n{}\n\nASSISTANT'S FIRST REPLY:\n{}",
        user.trim().chars().take(1500).collect::<String>(),
        reply.trim().chars().take(2000).collect::<String>()
    );
    let Ok(_slot) = app.suggest_slots.acquire().await else { return };
    let Some(title) = one_shot(app, &model, TITLE_PROMPT, &prompt).await.ok().as_deref().and_then(clean_title) else { return };
    // Named meanwhile? Keep that name.
    let Ok(st) = rpc_internal(live, json!({"type": "get_state"})).await else { return };
    if name_of(&st).is_empty() {
        let _ = rpc_internal(live, json!({"type": "set_session_name", "name": title})).await;
    }
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
    let text = one_shot(&app, &app.suggest_model, SUGGEST_PROMPT, &prompt).await?;
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

#[cfg(test)]
mod manage_tests {
    use super::MANAGE_PAGES;

    /// Every Settings page has a plain id, is listed once, and registers
    /// itself under that id (docs/pi-parity-plan.md §7).
    #[test]
    fn manage_pages_follow_the_contract() {
        let mut seen = std::collections::HashSet::new();
        for (id, body) in MANAGE_PAGES {
            assert!(!id.is_empty() && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'), "bad id {id}");
            assert!(seen.insert(*id), "{id} listed twice");
            let src = std::str::from_utf8(body).unwrap();
            assert!(src.contains("ppManage.register("), "manage-{id}.js doesn't call ppManage.register");
            assert!(src.contains(&format!("id: \"{id}\"")), "manage-{id}.js doesn't register id \"{id}\"");
        }
    }
}

#[cfg(test)]
mod title_tests {
    use super::*;

    #[test]
    fn tidies_titles() {
        assert_eq!(clean_title("\"Sourdough starter on long trips.\"\n").as_deref(), Some("Sourdough starter on long trips"));
        assert_eq!(clean_title("\n\nTitle: **Fix macOS mic picker**").as_deref(), Some("Fix macOS mic picker"));
        assert_eq!(clean_title("   \n").as_deref(), None);
        assert_eq!(clean_title(&"x".repeat(100)).map(|t| t.chars().count()), Some(60));
    }

    #[test]
    fn message_text_joins_text_blocks() {
        let m = json!({"role": "assistant", "content": [{"type": "thinking", "thinking": "hmm"}, {"type": "text", "text": "a"}, {"type": "text", "text": "b"}]});
        assert_eq!(message_text(&m), "a\nb");
        assert_eq!(message_text(&json!({"content": "plain"})), "plain");
    }
}
