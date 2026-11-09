//! The turn outline (docs/dsh-features-plan.md §3.7): one line per prompt of
//! the person on a chat's active branch, read from pi's session file.
//!
//! `GET /api/sessions/outline?path=<session file>` answers
//! `[{entryId, prompt, response}]`, oldest first: `entryId` is the user
//! message's session entry, `prompt` its text (at most 50 characters) and
//! `response` the last assistant text of that turn (at most 120). Tool
//! results, injected messages (`custom_message`), summaries and the rest are
//! left out. The active branch is the file's last entry and its `parentId`
//! chain, so turns compacted away still count; abandoned branches don't.
//!
//! Parsed outlines are cached by path, mtime and size, like
//! `sessions::read_meta`. The re-titling in main.rs reads the full texts
//! through `turns`.

use crate::{AppResult, AppState, err, exports};
use axum::{
    Json,
    extract::{Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    sync::{Arc, LazyLock, Mutex},
    time::UNIX_EPOCH,
};

/// The most characters of a prompt and of a reply the outline shows.
const PROMPT_CHARS: usize = 50;
const RESPONSE_CHARS: usize = 120;
/// Outlines kept in memory; the cache starts over past this.
const CACHE_MAX: usize = 256;

/// One prompt of the person and what came of it, in full.
#[derive(Clone, Debug, PartialEq)]
pub struct Turn {
    pub entry_id: String,
    /// The user message's text blocks, joined with newlines.
    pub prompt: String,
    /// The last assistant text of the turn ("" when there was none).
    pub response: String,
}

/// An outline line, as the clients get it.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub entry_id: String,
    pub prompt: String,
    pub response: String,
}

/// What an entry on the branch is, for the outline.
enum Kind {
    User(String),
    Assistant(String),
    Other,
}

struct Node {
    parent: Option<String>,
    kind: Kind,
}

fn text_of(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn node(v: &Value) -> Node {
    let parent = v.get("parentId").and_then(Value::as_str).map(String::from);
    let kind = if v.get("type").and_then(Value::as_str) == Some("message") {
        let msg = v.get("message");
        match msg.and_then(|m| m.get("role")).and_then(Value::as_str) {
            Some("user") => Kind::User(text_of(msg.and_then(|m| m.get("content")))),
            Some("assistant") => Kind::Assistant(text_of(msg.and_then(|m| m.get("content")))),
            _ => Kind::Other,
        }
    } else {
        Kind::Other
    };
    Node { parent, kind }
}

/// The turns on the active branch of a session file's text, oldest first.
pub fn turns_of(text: impl BufRead) -> Vec<Turn> {
    let mut nodes: HashMap<String, Node> = HashMap::new();
    let mut leaf: Option<String> = None;
    for line in text.lines() {
        let Ok(line) = line else { break };
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        // The header (type "session") has no id and isn't part of the tree.
        let Some(id) = v.get("id").and_then(Value::as_str).filter(|_| v.get("type").and_then(Value::as_str) != Some("session")) else {
            continue;
        };
        nodes.insert(id.to_string(), node(&v));
        leaf = Some(id.to_string());
    }
    // Leaf to root; the step limit guards against a parentId loop.
    let mut branch = Vec::new();
    let mut cur = leaf;
    while let Some(id) = cur {
        if branch.len() > nodes.len() {
            break;
        }
        let Some(n) = nodes.get(&id) else { break };
        cur = n.parent.clone();
        branch.push((id, n));
    }
    let mut out: Vec<Turn> = Vec::new();
    for (id, n) in branch.into_iter().rev() {
        match &n.kind {
            Kind::User(text) => out.push(Turn { entry_id: id, prompt: text.clone(), response: String::new() }),
            Kind::Assistant(text) if !text.trim().is_empty() => {
                if let Some(t) = out.last_mut() {
                    t.response = text.clone();
                }
            }
            _ => {}
        }
    }
    out
}

/// The turns of a session file (uncached, full texts).
pub fn turns(path: &Path) -> Option<Vec<Turn>> {
    let f = std::fs::File::open(path).ok()?;
    Some(turns_of(BufReader::new(f)))
}

/// Whitespace folded to single spaces and cut to `max` characters, the
/// last of them an ellipsis when something was cut.
fn short(s: &str, max: usize) -> String {
    let one = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if one.chars().count() <= max {
        return one;
    }
    let mut t: String = one.chars().take(max - 1).collect();
    t.truncate(t.trim_end().len());
    t.push('…');
    t
}

pub fn outline_of(turns: &[Turn]) -> Vec<Item> {
    turns
        .iter()
        .map(|t| Item {
            entry_id: t.entry_id.clone(),
            prompt: if t.prompt.trim().is_empty() { "(image)".into() } else { short(&t.prompt, PROMPT_CHARS) },
            response: short(&t.response, RESPONSE_CHARS),
        })
        .collect()
}

type Cache = Mutex<HashMap<PathBuf, (u128, u64, Arc<Vec<Item>>)>>;
static CACHE: LazyLock<Cache> = LazyLock::new(Default::default);

/// A session file's outline, from the cache while the file is unchanged.
pub fn outline(path: &Path) -> Option<Arc<Vec<Item>>> {
    let md = std::fs::metadata(path).ok()?;
    let mtime = md.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0);
    let size = md.len();
    if let Some((m, s, o)) = CACHE.lock().unwrap().get(path) {
        if *m == mtime && *s == size {
            return Some(o.clone());
        }
    }
    let o = Arc::new(outline_of(&turns(path)?));
    let mut c = CACHE.lock().unwrap();
    if c.len() >= CACHE_MAX {
        c.clear();
    }
    c.insert(path.to_path_buf(), (mtime, size, o.clone()));
    Some(o)
}

#[derive(Deserialize)]
pub struct OutlineQuery {
    path: String,
}

/// `GET /api/sessions/outline?path=`: only `.jsonl` files inside pi's
/// sessions folder or the Chat tab's folder.
pub async fn get_outline(State(app): State<Arc<AppState>>, Query(q): Query<OutlineQuery>) -> AppResult<Json<Vec<Item>>> {
    let roots = [app.sessions_dir.clone(), app.chat_dir.clone()];
    let path = exports::session_file_in(&roots, &q.path).ok_or_else(|| err(StatusCode::NOT_FOUND, "no such session file"))?;
    let o = tokio::task::spawn_blocking(move || outline(&path))
        .await
        .ok()
        .flatten()
        .ok_or_else(|| err(StatusCode::NOT_FOUND, "no such session file"))?;
    Ok(Json(o.as_ref().clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn jsonl(entries: &[Value]) -> String {
        let mut s = json!({"type": "session", "version": 3, "id": "sess", "timestamp": "2026-11-09T00:00:00.000Z", "cwd": "/p"}).to_string();
        s.push('\n');
        for e in entries {
            s.push_str(&e.to_string());
            s.push('\n');
        }
        s
    }
    fn user(id: &str, parent: Option<&str>, text: &str) -> Value {
        json!({"type": "message", "id": id, "parentId": parent, "message": {"role": "user", "content": text}})
    }
    fn asst(id: &str, parent: &str, text: &str) -> Value {
        json!({"type": "message", "id": id, "parentId": parent, "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "hm"}, {"type": "text", "text": text}]}})
    }
    fn tool_call(id: &str, parent: &str) -> Value {
        json!({"type": "message", "id": id, "parentId": parent, "message": {"role": "assistant", "content": [{"type": "toolCall", "id": "c1", "name": "bash", "arguments": {}}]}})
    }
    fn tool_result(id: &str, parent: &str) -> Value {
        json!({"type": "message", "id": id, "parentId": parent, "message": {"role": "toolResult", "toolCallId": "c1", "toolName": "bash", "content": [{"type": "text", "text": "output"}]}})
    }
    fn parse(entries: &[Value]) -> Vec<Turn> {
        turns_of(jsonl(entries).as_bytes())
    }
    fn ids(t: &[Turn]) -> Vec<&str> {
        t.iter().map(|t| t.entry_id.as_str()).collect()
    }

    #[test]
    fn one_line_per_prompt_with_the_last_reply() {
        let t = parse(&[
            user("u1", None, "Fix the build"),
            tool_call("a1", "u1"),
            tool_result("r1", "a1"),
            asst("a2", "r1", "Looking at it"),
            tool_call("a3", "a2"),
            tool_result("r2", "a3"),
            asst("a4", "r2", "Fixed: a missing import"),
            user("u2", Some("a4"), "Thanks"),
            asst("a5", "u2", "You're welcome"),
        ]);
        assert_eq!(ids(&t), ["u1", "u2"]);
        assert_eq!(t[0].prompt, "Fix the build");
        assert_eq!(t[0].response, "Fixed: a missing import");
        assert_eq!(t[1].response, "You're welcome");
    }

    #[test]
    fn follows_the_active_branch_only() {
        // u2 was edited: the branch from a1 to u3 is the one in use.
        let t = parse(&[
            user("u1", None, "one"),
            asst("a1", "u1", "reply one"),
            user("u2", Some("a1"), "abandoned"),
            asst("a2", "u2", "abandoned reply"),
            json!({"type": "branch_summary", "id": "b1", "parentId": "a1", "fromId": "a2", "summary": "tried something"}),
            user("u3", Some("b1"), "two"),
            asst("a3", "u3", "reply two"),
        ]);
        assert_eq!(ids(&t), ["u1", "u3"]);
        assert_eq!(t[1].response, "reply two");
    }

    #[test]
    fn keeps_compacted_turns_and_skips_custom_entries() {
        let t = parse(&[
            user("u1", None, "first"),
            asst("a1", "u1", "first reply"),
            json!({"type": "compaction", "id": "c1", "parentId": "a1", "summary": "S", "firstKeptEntryId": "c1", "tokensBefore": 1}),
            json!({"type": "custom", "id": "x1", "parentId": "c1", "customType": "pocketpi-goal", "data": {"phase": "active"}}),
            json!({"type": "custom_message", "id": "m1", "parentId": "x1", "customType": "goal", "content": "Keep going", "display": true}),
            json!({"type": "session_info", "id": "n1", "parentId": "m1", "name": "A title"}),
            user("u2", Some("n1"), "second"),
            asst("a2", "u2", "second reply"),
            json!({"type": "label", "id": "l1", "parentId": "a2", "targetId": "u1", "label": "x"}),
        ]);
        assert_eq!(ids(&t), ["u1", "u2"]);
        assert_eq!(t[0].response, "first reply");
        assert_eq!(t[1].prompt, "second");
    }

    #[test]
    fn a_turn_without_text_has_no_response() {
        let t = parse(&[user("u1", None, "run it"), tool_call("a1", "u1"), tool_result("r1", "a1")]);
        assert_eq!(t[0].response, "");
        assert!(parse(&[]).is_empty());
    }

    #[test]
    fn shortens_for_the_outline() {
        let long = "word ".repeat(40);
        let t = vec![
            Turn { entry_id: "u1".into(), prompt: long.clone(), response: long.clone() },
            Turn { entry_id: "u2".into(), prompt: " \n ".into(), response: "line one\n\nline   two".into() },
        ];
        let o = outline_of(&t);
        assert!(o[0].prompt.ends_with('…') && o[0].prompt.chars().count() <= PROMPT_CHARS);
        assert!(o[0].response.ends_with('…') && o[0].response.chars().count() <= RESPONSE_CHARS);
        assert_eq!(o[1].prompt, "(image)");
        assert_eq!(o[1].response, "line one line two");
        assert_eq!(short("héllo wörld", 50), "héllo wörld");
        assert_eq!(serde_json::to_value(&o[1]).unwrap(), json!({"entryId": "u2", "prompt": "(image)", "response": "line one line two"}));
    }

    #[test]
    fn caches_until_the_file_changes() {
        let dir = std::env::temp_dir().join(format!("pp-outline-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("s.jsonl");
        std::fs::write(&f, jsonl(&[user("u1", None, "one")])).unwrap();
        assert_eq!(outline(&f).unwrap().len(), 1);
        std::fs::write(&f, jsonl(&[user("u1", None, "one"), asst("a1", "u1", "ok"), user("u2", Some("a1"), "two")])).unwrap();
        let o = outline(&f).unwrap();
        assert_eq!(o.len(), 2);
        assert!(Arc::ptr_eq(&o, &outline(&f).unwrap()));
        assert!(outline(&dir.join("missing.jsonl")).is_none());
        let _ = std::fs::remove_dir_all(dir);
    }
}
