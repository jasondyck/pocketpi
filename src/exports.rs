//! Getting a chat out of pocketpi: pi's HTML export and the session file
//! itself.
//!
//! `export_html` writes wherever its `outputPath` says, so the server always
//! picks the path: a fresh file in `$XDG_DATA_HOME/pocketpi/exports/`, served
//! back at `GET /api/exports/{name}` (a name this module made, nothing else).
//! Old exports are pruned whenever a new one is made. The JSONL download only
//! serves `.jsonl` files that resolve to a place inside pi's sessions folder or
//! the Chat tab's folder.

use crate::{AppResult, AppState, err, get_live_ready, rpc};
use axum::{
    Json,
    body::Body,
    extract::{Path as UrlPath, Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime},
};
use tokio::io::AsyncReadExt;

/// Exports older than this go at the next export.
const KEEP_FOR: Duration = Duration::from_secs(24 * 3600);
/// And never more than this many.
const KEEP_MAX: usize = 30;

/// A new export file's path for the chat with live key `key`. Only the key's
/// letters and digits make it into the name.
pub fn new_export_path(dir: &Path, key: &str) -> PathBuf {
    let key: String = key.chars().filter(|c| c.is_ascii_alphanumeric()).take(32).collect();
    let ms = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_millis();
    dir.join(format!("{}-{ms}.html", if key.is_empty() { "chat" } else { &key }))
}

/// A name `new_export_path` could have made: `[A-Za-z0-9-]+.html`, so no
/// separators, dots or `..` reach the filesystem.
pub fn valid_export_name(name: &str) -> bool {
    name.strip_suffix(".html")
        .is_some_and(|stem| !stem.is_empty() && stem.len() <= 80 && stem.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'))
}

/// Deletes exports older than `KEEP_FOR`, then the oldest beyond `KEEP_MAX`.
pub fn prune(dir: &Path, keep_for: Duration, keep_max: usize) {
    let now = SystemTime::now();
    let mut files: Vec<(SystemTime, PathBuf)> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_str().is_some_and(valid_export_name))
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    for (i, (modified, path)) in files.iter().enumerate() {
        let old = now.duration_since(*modified).unwrap_or_default() > keep_for;
        if old || i >= keep_max {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// The session file `path` names, if it is a `.jsonl` inside one of `roots`
/// once symlinks and `..` are resolved.
pub fn session_file_in(roots: &[PathBuf], path: &str) -> Option<PathBuf> {
    let p = std::fs::canonicalize(path).ok()?;
    if p.extension().and_then(|e| e.to_str()) != Some("jsonl") || !p.is_file() {
        return None;
    }
    roots
        .iter()
        .filter_map(|r| std::fs::canonicalize(r).ok())
        .any(|r| p.starts_with(&r))
        .then_some(p)
}

/// Makes room in the exports folder and picks the next export's path.
pub fn prepare(dir: &Path, key: &str) -> PathBuf {
    let _ = std::fs::create_dir_all(dir);
    prune(dir, KEEP_FOR, KEEP_MAX);
    new_export_path(dir, key)
}

/// `POST /api/s/{key}/export`: pi writes the chat as HTML into the exports
/// folder; answers `{name, url}` to fetch it from.
pub async fn export(State(app): State<Arc<AppState>>, UrlPath(key): UrlPath<String>) -> AppResult<Json<Value>> {
    let live = get_live_ready(&app, &key).await?;
    let path = prepare(&app.exports_dir, &live.key);
    let resp = rpc(&live, json!({"type": "export_html", "outputPath": path})).await?;
    if resp.get("success") == Some(&Value::Bool(false)) {
        let msg = resp.get("error").and_then(Value::as_str).unwrap_or("export failed");
        return Err(err(StatusCode::BAD_GATEWAY, msg));
    }
    if !path.is_file() {
        return Err(err(StatusCode::BAD_GATEWAY, "pi didn't write the export"));
    }
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
    Ok(Json(json!({ "name": name, "url": format!("/api/exports/{name}") })))
}

#[derive(Deserialize)]
pub struct DownloadQuery {
    download: Option<String>,
    /// For the downloaded file's name.
    title: Option<String>,
}

/// A file name people can read: the chat's title, letters, digits, spaces
/// and dashes only.
fn download_name(title: Option<&str>, fallback: &str, ext: &str) -> String {
    let t: String = title
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' || c == '_' { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
        .chars()
        .take(60)
        .collect();
    let stem = if t.is_empty() { fallback.to_string() } else { t };
    format!("{stem}.{ext}")
}

fn attachment(name: &str) -> HeaderValue {
    // ASCII fallback plus RFC 5987 for the real name.
    let ascii: String = name.chars().map(|c| if c.is_ascii_alphanumeric() || ".-_".contains(c) { c } else { '_' }).collect();
    let mut enc = String::new();
    for b in name.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.".contains(&b) {
            enc.push(b as char);
        } else {
            enc.push_str(&format!("%{b:02X}"));
        }
    }
    HeaderValue::from_str(&format!("attachment; filename=\"{ascii}\"; filename*=UTF-8''{enc}")).unwrap_or(HeaderValue::from_static("attachment"))
}

fn wants_download(q: &DownloadQuery) -> bool {
    q.download.as_deref().is_some_and(|v| v == "1" || v == "true")
}

/// `GET /api/exports/{name}[?download=1&title=]`: an export as a page (or a
/// download). It runs in a sandbox (an opaque origin), so its scripts can't
/// call this server's API.
pub async fn serve_export(State(app): State<Arc<AppState>>, UrlPath(name): UrlPath<String>, Query(q): Query<DownloadQuery>) -> Response {
    if !valid_export_name(&name) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(body) = tokio::fs::read(app.exports_dir.join(&name)).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let mut res = body.into_response();
    let hs = res.headers_mut();
    hs.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/html; charset=utf-8"));
    hs.insert(header::CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    hs.insert(header::CONTENT_SECURITY_POLICY, HeaderValue::from_static("sandbox allow-scripts allow-popups allow-downloads"));
    hs.insert("x-content-type-options", HeaderValue::from_static("nosniff"));
    if wants_download(&q) {
        hs.insert(header::CONTENT_DISPOSITION, attachment(&download_name(q.title.as_deref(), "pi-session", "html")));
    }
    res
}

#[derive(Deserialize)]
pub struct FileQuery {
    path: String,
    title: Option<String>,
}

/// `GET /api/sessions/file?path=<session file>[&title=]`: the session's
/// JSONL as a download, streamed.
pub async fn download_session(State(app): State<Arc<AppState>>, Query(q): Query<FileQuery>) -> AppResult<Response> {
    let roots = [app.sessions_dir.clone(), app.chat_dir.clone()];
    let path = session_file_in(&roots, &q.path).ok_or_else(|| err(StatusCode::NOT_FOUND, "no such session file"))?;
    let mut file = tokio::fs::File::open(&path).await.map_err(|_| err(StatusCode::NOT_FOUND, "no such session file"))?;
    let len = file.metadata().await.map(|m| m.len()).ok();
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Vec<u8>, std::io::Error>>(4);
    tokio::spawn(async move {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match file.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => {
                    if tx.send(Ok(buf[..n].to_vec())).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    let _ = tx.send(Err(e)).await;
                    break;
                }
            }
        }
    });
    let mut res = Body::from_stream(tokio_stream::wrappers::ReceiverStream::new(rx)).into_response();
    let hs = res.headers_mut();
    hs.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/x-ndjson"));
    hs.insert(header::CACHE_CONTROL, HeaderValue::from_static("private, no-store"));
    if let Some(len) = len {
        hs.insert(header::CONTENT_LENGTH, HeaderValue::from(len));
    }
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("session").to_string();
    hs.insert(header::CONTENT_DISPOSITION, attachment(&download_name(q.title.as_deref(), &stem, "jsonl")));
    Ok(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pocketpi-exports-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn export_names_stay_in_the_folder() {
        let dir = Path::new("/x/exports");
        let p = new_export_path(dir, "../../etc/passwd");
        assert_eq!(p.parent(), Some(dir));
        let name = p.file_name().unwrap().to_str().unwrap();
        assert!(name.starts_with("etcpasswd-"), "{name}");
        assert!(valid_export_name(name));
        assert!(valid_export_name(new_export_path(dir, "").file_name().unwrap().to_str().unwrap()));
        for bad in ["", ".html", "../x.html", "a/b.html", "a.b.html", "x.htm", "x.html/", "..html", "x .html", "%2e%2e.html"] {
            assert!(!valid_export_name(bad), "{bad}");
        }
        assert!(valid_export_name("1a2b-1700000000000.html"));
    }

    #[test]
    fn prune_keeps_the_newest_and_drops_old_ones() {
        let dir = scratch("prune");
        for i in 0..5 {
            std::fs::write(dir.join(format!("k-{i}.html")), "x").unwrap();
            std::thread::sleep(Duration::from_millis(15));
        }
        std::fs::write(dir.join("notes.txt"), "keep me").unwrap();
        prune(&dir, Duration::from_secs(3600), 3);
        let mut left: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name().into_string().unwrap()).collect();
        left.sort();
        assert_eq!(left, ["k-2.html", "k-3.html", "k-4.html", "notes.txt"]);
        std::thread::sleep(Duration::from_millis(20));
        prune(&dir, Duration::from_millis(1), 10);
        let left: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten().map(|e| e.file_name().into_string().unwrap()).collect();
        assert_eq!(left, ["notes.txt"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn session_files_only_from_the_sessions_folders() {
        let base = scratch("files");
        let sessions = base.join("sessions");
        let chat = base.join("chat");
        std::fs::create_dir_all(sessions.join("--proj--")).unwrap();
        std::fs::create_dir_all(&chat).unwrap();
        let ok = sessions.join("--proj--/a.jsonl");
        std::fs::write(&ok, "{}\n").unwrap();
        std::fs::write(chat.join("c.jsonl"), "{}\n").unwrap();
        std::fs::write(base.join("outside.jsonl"), "{}\n").unwrap();
        std::fs::write(sessions.join("notes.txt"), "x").unwrap();
        std::os::unix::fs::symlink(base.join("outside.jsonl"), sessions.join("link.jsonl")).unwrap();
        let roots = [sessions.clone(), chat.clone()];
        let s = |p: PathBuf| p.to_string_lossy().to_string();
        assert_eq!(session_file_in(&roots, &s(ok.clone())), Some(std::fs::canonicalize(&ok).unwrap()));
        assert!(session_file_in(&roots, &s(chat.join("c.jsonl"))).is_some());
        assert!(session_file_in(&roots, &s(sessions.join("--proj--/../--proj--/a.jsonl"))).is_some());
        assert!(session_file_in(&roots, &s(sessions.join("../outside.jsonl"))).is_none());
        assert!(session_file_in(&roots, &s(sessions.join("link.jsonl"))).is_none(), "a symlink out of the folder");
        assert!(session_file_in(&roots, &s(sessions.join("notes.txt"))).is_none());
        assert!(session_file_in(&roots, &s(sessions.join("--proj--"))).is_none());
        assert!(session_file_in(&roots, "/etc/passwd").is_none());
        assert!(session_file_in(&roots, "").is_none());
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn download_names_are_tidy() {
        assert_eq!(download_name(Some("Fix the build: now!"), "x", "html"), "Fix-the-build-now.html");
        assert_eq!(download_name(Some("  "), "2026_abc", "jsonl"), "2026_abc.jsonl");
        assert_eq!(download_name(Some("../../etc"), "x", "html"), "etc.html");
        let h = attachment("Café-chat.html");
        let v = h.to_str().unwrap();
        assert!(v.contains("filename=\"Caf_-chat.html\"") && v.contains("UTF-8''Caf%C3%A9-chat.html"), "{v}");
    }
}
