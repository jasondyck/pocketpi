//! Server-side state per chat, for what the server itself tracks about a chat
//! (changed-file snapshots, the title pin, a chat's worktree): one JSON object
//! per session file in `~/.local/share/pocketpi/chats/<session stem>.json`.
//!
//! State the model or the chat's pi needs belongs in the session file
//! instead (an extension's `pocketpi-*` custom entries), so it follows forks
//! and branches. This is for the rest.
//!
//! Each feature owns one top-level key (`"files"`, `"title"`, `"worktree"`)
//! and reads or replaces only that, so features never clobber each other.

use serde_json::{Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Serializes read-modify-write cycles: features update their key from
/// different tasks.
static LOCK: Mutex<()> = Mutex::new(());

pub struct ChatState {
    dir: PathBuf,
}

impl ChatState {
    pub fn new(data_dir: &Path) -> Self {
        Self { dir: data_dir.join("chats") }
    }

    /// The state file for a session file: its file stem (pi names sessions
    /// `<timestamp>_<uuid>.jsonl`, unique across folders). None for a path
    /// with no usable stem.
    fn file(&self, session: &str) -> Option<PathBuf> {
        let stem = Path::new(session).file_stem()?.to_str()?;
        if stem.is_empty() || stem.starts_with('.') || !stem.chars().all(|c| c.is_ascii_alphanumeric() || "-_.:".contains(c)) {
            return None;
        }
        Some(self.dir.join(format!("{stem}.json")))
    }

    fn read_all(&self, session: &str) -> Map<String, Value> {
        self.file(session)
            .and_then(|f| std::fs::read(f).ok())
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .and_then(|v| match v {
                Value::Object(m) => Some(m),
                _ => None,
            })
            .unwrap_or_default()
    }

    /// One feature's state for a chat, or Null.
    pub fn get(&self, session: &str, key: &str) -> Value {
        let _g = LOCK.lock().unwrap();
        self.read_all(session).remove(key).unwrap_or(Value::Null)
    }

    /// Replaces one feature's state (Null removes it). Written atomically.
    pub fn set(&self, session: &str, key: &str, value: Value) -> std::io::Result<()> {
        let Some(file) = self.file(session) else {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "not a session file"));
        };
        let _g = LOCK.lock().unwrap();
        let mut all = self.read_all(session);
        if value.is_null() {
            all.remove(key);
        } else {
            all.insert(key.to_string(), value);
        }
        if all.is_empty() {
            return match std::fs::remove_file(&file) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
        }
        std::fs::create_dir_all(&self.dir)?;
        let tmp = file.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(&Value::Object(all))?)?;
        std::fs::rename(&tmp, &file)
    }

    /// Changes one feature's state in place: `f` gets the current value
    /// (Null when unset) and returns the new one. Holds the lock throughout,
    /// so concurrent updates of the same key don't lose writes.
    pub fn update(&self, session: &str, key: &str, f: impl FnOnce(Value) -> Value) -> std::io::Result<Value> {
        let Some(file) = self.file(session) else {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "not a session file"));
        };
        let _g = LOCK.lock().unwrap();
        let mut all = self.read_all(session);
        let new = f(all.remove(key).unwrap_or(Value::Null));
        if !new.is_null() {
            all.insert(key.to_string(), new.clone());
        }
        if all.is_empty() {
            let _ = std::fs::remove_file(&file);
            return Ok(new);
        }
        std::fs::create_dir_all(&self.dir)?;
        let tmp = file.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(&Value::Object(all))?)?;
        std::fs::rename(&tmp, &file)?;
        Ok(new)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("pp-chat-state-{}-{}", std::process::id(), rand_suffix()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }
    fn rand_suffix() -> u128 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    }

    #[test]
    fn keys_are_independent_and_null_removes() {
        let d = tmp();
        let st = ChatState::new(&d);
        let s = "/home/x/.pi/agent/sessions/--p--/2026-11-09T01-02-03-000Z_abc-123.jsonl";
        assert_eq!(st.get(s, "files"), Value::Null);
        st.set(s, "files", json!({"turns": [1]})).unwrap();
        st.set(s, "title", json!({"pinned": true})).unwrap();
        assert_eq!(st.get(s, "files"), json!({"turns": [1]}));
        assert_eq!(st.get(s, "title"), json!({"pinned": true}));
        st.set(s, "files", Value::Null).unwrap();
        assert_eq!(st.get(s, "files"), Value::Null);
        assert_eq!(st.get(s, "title"), json!({"pinned": true}));
        st.set(s, "title", Value::Null).unwrap();
        assert!(!d.join("chats/2026-11-09T01-02-03-000Z_abc-123.json").exists());
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn update_sees_the_current_value() {
        let d = tmp();
        let st = ChatState::new(&d);
        let s = "/x/a_b.jsonl";
        for _ in 0..3 {
            st.update(s, "n", |v| json!(v.as_u64().unwrap_or(0) + 1)).unwrap();
        }
        assert_eq!(st.get(s, "n"), json!(3));
        let _ = std::fs::remove_dir_all(d);
    }

    #[test]
    fn refuses_odd_paths() {
        let d = tmp();
        let st = ChatState::new(&d);
        assert!(st.set("/x/.hidden.jsonl", "k", json!(1)).is_err());
        assert!(st.set("/", "k", json!(1)).is_err());
        assert!(st.set("/x/a b.jsonl", "k", json!(1)).is_err());
        let _ = std::fs::remove_dir_all(d);
    }
}
