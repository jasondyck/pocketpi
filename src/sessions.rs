//! Reads pi's session JSONL files for the chat list.

use serde::Serialize;
use serde_json::Value;
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    sync::Mutex,
    time::UNIX_EPOCH,
};

#[derive(Clone, Serialize, Default)]
pub struct SessionInfo {
    pub path: String,
    pub id: String,
    pub cwd: String,
    pub name: Option<String>,
    pub title: String,
    pub modified: u64,
    pub messages: u32,
    pub live: bool,
    pub streaming: bool,
    /// For a live chat: the config epoch its pi started with (compare with
    /// the list's `config_epoch` for "Restart to apply").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u64>,
    /// The session this one was forked or cloned from (pi's
    /// `parentSession` header field), when pi recorded one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
}

#[derive(Clone)]
pub struct Meta {
    pub id: String,
    pub cwd: String,
    pub name: Option<String>,
    pub title: String,
    pub messages: u32,
    pub parent: Option<String>,
}

/// Parsed metadata keyed by path, invalidated by (mtime, size).
#[derive(Default)]
pub struct Cache(Mutex<HashMap<PathBuf, (u64, u64, Meta)>>);

pub fn read_meta(path: &Path) -> Option<Meta> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut meta: Option<Meta> = None;
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let l = line.trim_end();
        if meta.is_none() {
            let v: Value = serde_json::from_str(l).ok()?;
            if v.get("type")?.as_str()? != "session" {
                return None;
            }
            meta = Some(Meta {
                id: v.get("id").and_then(Value::as_str).unwrap_or("").to_string(),
                cwd: v.get("cwd").and_then(Value::as_str).unwrap_or("").to_string(),
                name: None,
                title: String::new(),
                messages: 0,
                parent: v.get("parentSession").and_then(Value::as_str).filter(|s| !s.is_empty()).map(String::from),
            });
            continue;
        }
        let m = meta.as_mut().unwrap();
        // Cheap substring checks first; most lines are large message entries.
        if l.starts_with(r#"{"type":"session_info""#) {
            if let Ok(v) = serde_json::from_str::<Value>(l) {
                m.name = v.get("name").and_then(Value::as_str).map(String::from).filter(|s| !s.is_empty());
            }
        } else if l.starts_with(r#"{"type":"message""#) {
            let is_user = l.contains(r#""role":"user""#);
            let is_assistant = l.contains(r#""role":"assistant""#);
            if is_user || is_assistant {
                m.messages += 1;
            }
            if is_user && m.title.is_empty() {
                if let Ok(v) = serde_json::from_str::<Value>(l) {
                    if let Some(msg) = v.get("message") {
                        if msg.get("role").and_then(Value::as_str) == Some("user") {
                            m.title = first_text(msg.get("content"));
                        }
                    }
                }
            }
        }
    }
    meta
}

fn first_text(content: Option<&Value>) -> String {
    let text = match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    };
    let one_line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    one_line.chars().take(120).collect()
}

pub fn scan(root: &Path, cache: &Cache) -> Vec<SessionInfo> {
    let mut out = Vec::new();
    let mut seen = Vec::new();
    // pi groups sessions into one subfolder per working directory, but writes
    // them flat when a custom session dir is configured; accept both.
    let mut files = Vec::new();
    for entry in std::fs::read_dir(root).into_iter().flatten().flatten() {
        match entry.file_type() {
            Ok(t) if t.is_dir() => files.extend(std::fs::read_dir(entry.path()).into_iter().flatten().flatten()),
            Ok(t) if t.is_file() => files.push(entry),
            _ => {}
        }
    }
    {
        for f in files {
            let path = f.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                continue;
            }
            let Ok(md) = f.metadata() else { continue };
            let mtime = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let size = md.len();
            let cached = cache
                .0
                .lock()
                .unwrap()
                .get(&path)
                .filter(|(m, s, _)| *m == mtime && *s == size)
                .map(|(_, _, meta)| meta.clone());
            let meta = match cached {
                Some(m) => m,
                None => {
                    let Some(m) = read_meta(&path) else { continue };
                    cache.0.lock().unwrap().insert(path.clone(), (mtime, size, m.clone()));
                    m
                }
            };
            seen.push(path.clone());
            out.push(SessionInfo {
                path: path.to_string_lossy().to_string(),
                id: meta.id,
                cwd: meta.cwd,
                name: meta.name,
                title: meta.title,
                modified: mtime,
                messages: meta.messages,
                live: false,
                streaming: false,
                epoch: None,
                parent: meta.parent,
            });
        }
    }
    cache.0.lock().unwrap().retain(|p, _| seen.contains(p));
    out.sort_by(|a, b| b.modified.cmp(&a.modified));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn meta_reads_parent_session() {
        let dir = std::env::temp_dir().join(format!("pocketpi-sessions-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let fork = dir.join("fork.jsonl");
        std::fs::write(
            &fork,
            concat!(
                r#"{"type":"session","id":"b","cwd":"/p","version":3,"parentSession":"/s/a.jsonl"}"#,
                "\n",
                r#"{"type":"message","id":"1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
                "\n",
            ),
        )
        .unwrap();
        let plain = dir.join("plain.jsonl");
        std::fs::write(&plain, concat!(r#"{"type":"session","id":"a","cwd":"/p","version":3}"#, "\n")).unwrap();
        let m = read_meta(&fork).unwrap();
        assert_eq!(m.parent.as_deref(), Some("/s/a.jsonl"));
        assert_eq!((m.title.as_str(), m.messages), ("hi", 1));
        assert_eq!(read_meta(&plain).unwrap().parent, None);
        let json = serde_json::to_value(scan(&dir, &Cache::default())).unwrap();
        let by_id = |id: &str| json.as_array().unwrap().iter().find(|s| s["id"] == id).unwrap().clone();
        assert_eq!(by_id("b")["parent"], "/s/a.jsonl");
        assert!(by_id("a").get("parent").is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
