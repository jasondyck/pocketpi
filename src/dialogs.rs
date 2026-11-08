//! Pending extension dialogs (`extension_ui_request` confirm / select /
//! input / editor) in chats, and the notification that tells the phone one
//! is waiting (docs/pi-parity-plan.md §6, S2).
//!
//! A permission prompt from @gotgenes/pi-permission-system stops the agent
//! until someone answers it (or its `promptTimeoutMs` denies it), so a
//! dialog nobody sees is a stalled chat. When a chat's pi opens one and no
//! client has the chat's event stream open, pocketpi notifies right away;
//! when a client is connected but the dialog is still open after
//! [`UNANSWERED`], it notifies then. Each dialog is notified at most once.
//! A dialog stops being pending when a client answers it, when its own
//! `timeout` runs out, when the turn ends (`agent_settled`) or when the pi
//! exits. Workflow stages never get here: the engine declines their dialogs.
//!
//! Pending dialogs are also replayed to clients that connect later
//! (`dialogs` in `pocketpi_hello`), so the chat a notification opens shows
//! the question.

use crate::{AppState, Live};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long a dialog may sit unanswered in a chat someone has open.
pub const UNANSWERED: Duration = Duration::from_secs(20);
/// Don't notify about a dialog that closes itself sooner than this.
const MIN_LEFT: Duration = Duration::from_secs(10);
const DIALOGS: [&str; 4] = ["confirm", "select", "input", "editor"];

struct Open {
    id: String,
    req: Value,
    deadline: Option<Instant>,
    notified: bool,
}

/// One pi's open dialogs, oldest first.
#[derive(Default)]
pub struct Dialogs {
    open: Vec<Open>,
}

impl Dialogs {
    /// Remember a dialog request; returns its id when it is one (and new).
    pub fn opened(&mut self, req: &Value, now: Instant) -> Option<String> {
        if !DIALOGS.contains(&req.get("method").and_then(Value::as_str)?) {
            return None;
        }
        let id = req.get("id").and_then(Value::as_str)?.to_string();
        if self.open.iter().any(|o| o.id == id) {
            return None;
        }
        let deadline = req.get("timeout").and_then(Value::as_u64).map(|ms| now + Duration::from_millis(ms));
        // Closed dialogs that nobody reported (a timeout ran out) go now.
        self.open.retain(|o| o.deadline.is_none_or(|d| d > now));
        self.open.push(Open { id: id.clone(), req: req.clone(), deadline, notified: false });
        Some(id)
    }

    pub fn answered(&mut self, id: &str) {
        self.open.retain(|o| o.id != id);
    }

    /// The turn ended: whatever it asked has been resolved one way or another.
    pub fn clear(&mut self) {
        self.open.clear();
    }

    /// The requests still waiting for an answer, for a client that connects.
    pub fn pending(&self, now: Instant) -> Vec<Value> {
        self.open.iter().filter(|o| o.deadline.is_none_or(|d| d > now)).map(|o| o.req.clone()).collect()
    }

    /// The request to notify about, once: None when it was answered, has
    /// already been notified, or closes itself too soon to be worth it.
    pub fn claim(&mut self, id: &str, now: Instant) -> Option<Value> {
        let o = self.open.iter_mut().find(|o| o.id == id)?;
        if o.notified || o.deadline.is_some_and(|d| d < now + MIN_LEFT) {
            return None;
        }
        o.notified = true;
        Some(o.req.clone())
    }
}

/// Terminal colours extensions put in their text.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\x1b' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('[') => {
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\x07' || (c == '\x1b' && chars.next_if_eq(&'\\').is_some()) {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// The `key : value` lines of a gotgenes prompt ("tool    : bash",
/// "command : rm -rf junk"). A line without a key continues the value above.
pub fn fields(text: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        let split = line.find(" : ").or_else(|| line.strip_suffix(" :").map(|l| l.len()));
        let key = split.map(|i| line[..i].trim()).filter(|k| {
            !k.is_empty() && k.len() <= 24 && k.chars().all(|c| c.is_ascii_alphabetic() || c == ' ' || c == '_')
        });
        match (key, split) {
            (Some(k), Some(i)) => {
                let v = line.get(i + 3..).unwrap_or("").trim().to_string();
                out.push((k.to_ascii_lowercase(), v));
            }
            _ => {
                if let Some(last) = out.last_mut() {
                    let l = line.trim();
                    if !l.is_empty() {
                        last.1.push(' ');
                        last.1.push_str(l);
                    }
                }
            }
        }
    }
    out
}

fn clip(s: &str, n: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= n {
        return s;
    }
    let mut t: String = s.chars().take(n - 1).collect();
    t.push('…');
    t
}

/// What a permission prompt asks, in a few words: "pi wants to run: rm -rf
/// junk". None when the text isn't one.
fn permission_line(f: &[(String, String)]) -> Option<String> {
    let get = |k: &str| f.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str()).filter(|v| !v.is_empty());
    let tool = get("tool");
    let surface = get("surface").unwrap_or("");
    let outside = surface.starts_with("external_directory");
    if let Some(cmd) = get("command") {
        return Some(format!("pi wants to run: {cmd}{}", if outside { " (outside the project)" } else { "" }));
    }
    if let Some(path) = get("external path").or_else(|| get("path")) {
        let verb = match (tool.unwrap_or(""), surface) {
            (_, s) if s.ends_with("_write") => "write",
            (_, s) if s.ends_with("_read") => "read",
            ("write", _) => "write",
            ("edit", _) => "edit",
            ("read" | "grep" | "find" | "ls", _) => "read",
            _ => "use",
        };
        let place = if outside { " (outside the project)" } else { "" };
        return Some(match (verb, tool) {
            ("use", Some(t)) => format!("pi wants to use {t} on: {path}{place}"),
            (v, _) => format!("pi wants to {v}: {path}{place}"),
        });
    }
    let tool = tool?;
    let target = f.iter().find(|(k, _)| k != "tool" && k != "rule" && k != "surface" && k != "agent").map(|(_, v)| v.as_str());
    Some(match target {
        Some(t) if !t.is_empty() => format!("pi wants to use {tool}: {t}"),
        _ => format!("pi wants to use {tool}"),
    })
}

/// The notification for a dialog: (title, body). The title is the dialog's
/// own first line and the project; the body says what is being asked.
pub fn summary(req: &Value, project: &str) -> (String, String) {
    let s = |k: &str| req.get(k).and_then(Value::as_str).map(strip_ansi).unwrap_or_default();
    let title = s("title");
    let mut lines = title.lines();
    let head = lines.next().unwrap_or("").trim().to_string();
    let rest: Vec<&str> = lines.collect();
    let f = fields(&rest.join("\n"));
    let body = permission_line(&f)
        .or_else(|| Some(s("message")).filter(|m| !m.trim().is_empty()))
        .or_else(|| Some(rest.join(" ")).filter(|r| !r.trim().is_empty()))
        .or_else(|| {
            let opts: Vec<String> = req.get("options")?.as_array()?.iter().filter_map(Value::as_str).map(strip_ansi).collect();
            (!opts.is_empty()).then(|| opts.join(" / "))
        })
        .or_else(|| Some(s("placeholder")).filter(|p| !p.trim().is_empty()))
        .unwrap_or_else(|| "pi is waiting for your answer.".into());
    let head = if head.is_empty() { "pi is asking".to_string() } else { head };
    let title = if project.is_empty() { head } else { format!("{head} · {project}") };
    (clip(&title, 80), clip(&body, 180))
}

/// A chat's pi opened a dialog (called for every `extension_ui_request` of
/// a chat): remember it, and notify now if nobody watches the chat, or in
/// [`UNANSWERED`] if it's still open then.
pub fn opened(app: &Arc<AppState>, live: &Arc<Live>, req: Value) {
    let Some(id) = live.ext_ui.lock().unwrap().dialogs.opened(&req, Instant::now()) else { return };
    let watched = live.tx.receiver_count() > 0;
    let (app, live) = (app.clone(), live.clone());
    tokio::spawn(async move {
        if watched {
            tokio::time::sleep(UNANSWERED).await;
        }
        if live.exited.load(std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        let Some(req) = live.ext_ui.lock().unwrap().dialogs.claim(&id, Instant::now()) else { return };
        let project = live.cwd.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string();
        let (title, body) = summary(&req, &project);
        if live.session_file().is_none() {
            // A new chat: the server learns its file from get_state.
            let _ = crate::rpc_internal(&live, json!({"type": "get_state"})).await;
        }
        let url = match live.session_file() {
            Some(f) => format!("/?s={}", crate::urlencode(&f)),
            None => "/".to_string(),
        };
        // Also on the runs stream, for clients in the foreground.
        let msg = json!({"type": "dialog_pending", "key": live.key, "id": id, "title": title, "body": body, "url": url}).to_string();
        let _ = app.engine.tx.send(Arc::from(msg.as_str()));
        app.push.send(&title, &body, &url, &format!("dialog-{}", live.key)).await;
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gotgenes(title: &str) -> Value {
        json!({"type": "extension_ui_request", "id": "a1", "method": "select", "title": title,
               "options": ["Yes", "Yes, allow bash \"rm *\" for this session", "No", "No, provide reason"]})
    }

    #[test]
    fn permission_prompts_read_as_one_line() {
        let (t, b) = summary(&gotgenes("Permission Required\ntool    : bash\nrule    : rm *\ncommand : rm -rf junk1"), "pocketpi");
        assert_eq!(t, "Permission Required · pocketpi");
        assert_eq!(b, "pi wants to run: rm -rf junk1");

        let (_, b) = summary(&gotgenes("Permission Required\ntool    : bash\nsurface : path_read\nrule    : *.env\npath    : .env\nwhy     : read (pure-reader command)"), "p");
        assert_eq!(b, "pi wants to read: .env");

        let (_, b) = summary(&gotgenes("Permission Required\ntool    : write\nsurface : path_write\nrule    : *.env\npath    : /home/me/p/.env"), "p");
        assert_eq!(b, "pi wants to write: /home/me/p/.env");

        let ext = "Permission Required\ntool              : bash\nsurface           : external_directory\nrule              : *\n\
                   command           : touch ~/outside.txt\nwhy               : /home/me/outside.txt: unproven,\n\
                   consults both directions; declare the command in commandEffects to classify it\n\
                   working directory : /home/me/project\nexternal path     : /home/me/outside.txt";
        let f = fields(ext);
        assert_eq!(f.iter().find(|(k, _)| k == "why").unwrap().1, "/home/me/outside.txt: unproven, consults both directions; declare the command in commandEffects to classify it");
        assert_eq!(f.iter().find(|(k, _)| k == "external path").unwrap().1, "/home/me/outside.txt");
        assert_eq!(summary(&gotgenes(ext), "p").1, "pi wants to run: touch ~/outside.txt (outside the project)");

        let (_, b) = summary(&gotgenes("Permission Required\ntool    : read\nsurface : external_directory_read\npath    : /etc/hosts"), "p");
        assert_eq!(b, "pi wants to read: /etc/hosts (outside the project)");
        let (_, b) = summary(&gotgenes("Permission Required\ntool   : mcp\nrule   : github:*\ntarget : github_search"), "p");
        assert_eq!(b, "pi wants to use mcp: github_search");
    }

    #[test]
    fn other_dialogs_use_their_message_or_options() {
        let (t, b) = summary(&json!({"method": "confirm", "id": "x", "title": "Allow it?", "message": "The fake asks."}), "proj");
        assert_eq!((t.as_str(), b.as_str()), ("Allow it? · proj", "The fake asks."));
        let (t, b) = summary(&json!({"method": "select", "id": "x", "title": "\x1b[1mPick\x1b[0m", "options": ["a", "b"]}), "");
        assert_eq!((t.as_str(), b.as_str()), ("Pick", "a / b"));
        let (t, b) = summary(&json!({"method": "input", "id": "x"}), "p");
        assert_eq!((t.as_str(), b.as_str()), ("pi is asking · p", "pi is waiting for your answer."));
        let long = "x".repeat(400);
        let (_, b) = summary(&json!({"method": "confirm", "id": "x", "title": "t", "message": long}), "p");
        assert_eq!(b.chars().count(), 180);
        assert!(b.ends_with('…'));
    }

    #[test]
    fn notifies_each_dialog_once_and_forgets_answered_ones() {
        let t0 = Instant::now();
        let mut d = Dialogs::default();
        let req = gotgenes("Permission Required\ntool : bash\ncommand : ls");
        assert_eq!(d.opened(&req, t0).as_deref(), Some("a1"));
        assert_eq!(d.opened(&req, t0), None, "the same id twice is one dialog");
        assert_eq!(d.opened(&json!({"method": "setStatus", "id": "s"}), t0), None);
        assert_eq!(d.opened(&json!({"method": "notify", "id": "n"}), t0), None);
        assert_eq!(d.pending(t0).len(), 1);
        assert!(d.claim("a1", t0).is_some());
        assert!(d.claim("a1", t0).is_none(), "never twice");
        d.answered("a1");
        assert!(d.pending(t0).is_empty());
        assert!(d.claim("a1", t0).is_none());

        // A dialog that closes itself soon isn't worth a notification, and
        // drops out of the replay once its time is up.
        let quick = json!({"method": "confirm", "id": "q", "title": "?", "timeout": 1500});
        d.opened(&quick, t0);
        assert!(d.claim("q", t0).is_none());
        assert_eq!(d.pending(t0).len(), 1);
        assert!(d.pending(t0 + Duration::from_secs(2)).is_empty());
        let slow = json!({"method": "confirm", "id": "s", "title": "?", "timeout": 60000});
        d.opened(&slow, t0 + Duration::from_secs(2));
        assert_eq!(d.pending(t0 + Duration::from_secs(2)).len(), 1, "the expired one is gone");
        assert!(d.claim("s", t0 + Duration::from_secs(25)).is_some());
        d.opened(&req, t0);
        d.clear();
        assert!(d.pending(t0).is_empty());
    }
}
