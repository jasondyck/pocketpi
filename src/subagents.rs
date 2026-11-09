//! Live subagent runs, read from pi-subagents' lifecycle artifacts.
//!
//! pi-subagents (npm `pi-subagents`) writes machine-readable run state under
//! `<tmpdir>/pi-subagents-<scope>/async-subagent-runs/<runId>/`: `status.json`
//! (what its own widget and `subagent({action:"status"})` read),
//! `events.jsonl`, and `output-<n>.log` tails. Those files are authoritative
//! and documented as the consumer API, so pocketpi never scrapes the model's
//! tool output for progress: it reads the same files the TUI reads.
//!
//! | Route | Answer |
//! |---|---|
//! | `GET /api/subagents[?session=<session file>][&all=1]` | `{at, runs: [...], total}`: every recent run, newest live first. Without `session` (or with `all=1`) runs of every chat are included. |
//! | `GET /api/subagents/{runId}` | `{at, run, outputs: [{name, text}]}`: one run plus the bounded tail of its `output-<n>.log` files |
//!
//! A run has `runId`/`id`, `toolCallId` (pi's tool call that launched it, so a
//! chat's tool card can find its run), `mode` (`single`/`chain`/`parallel`/
//! `workflow`), `state`, `sessionId` (the launching chat's session file),
//! `cwd`, timestamps, `tokens`/`cost`, and `steps`. A step has `agent`,
//! `label`, `status`, tokens, model, the child's `sessionFile` (open it as a
//! chat while it runs), `recentTools` (`read src/main.rs`) and `recentOutput`
//! (its last lines). Workflow roots list their children as steps; a step's
//! live detail is merged from the child run's own `status.json` when that file
//! exists, because a workflow root's step only records completion.
//!
//! Runs whose parent workflow is present are left out of the top-level list
//! (they are already a step of it). Child runs that outlive their parent are
//! still listed. Files are capped ([`MAX_STATUS_BYTES`]) and old runs ignored
//! ([`MAX_AGE_SECS`]); paths never come from a client, and a run id is only
//! accepted if it looks like one ([`safe_id`]). pi-subagents cleans these
//! directories itself after 24 hours, so this is a view, not a ledger.
//!
//! Not covered: project-scoped workflow artifacts under `.pi/subagents/` and
//! nested runs under a nested async root; both are out of scope for now.

use crate::AppState;
use axum::{
    Json, Router,
    extract::{Path, Query},
    http::StatusCode,
    response::IntoResponse,
    routing::get,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    env, fs,
    io::{Read, Seek, SeekFrom},
    path::{Path as FsPath, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::task;

/// Runs whose artifacts were touched longer ago than this are ignored.
const MAX_AGE_SECS: u64 = 48 * 3600;
/// Most runs returned at once.
const MAX_RUNS: usize = 80;
/// A `status.json` larger than this is not ours to parse.
const MAX_STATUS_BYTES: u64 = 2_000_000;
/// Characters kept from an output log tail.
const MAX_TAIL_CHARS: usize = 16_000;
/// Bytes read from the end of a log (enough for [`MAX_TAIL_CHARS`] UTF-8).
const MAX_TAIL_BYTES: u64 = 128 * 1024;
/// Lines kept from an output log tail.
const MAX_TAIL_LINES: usize = 240;
/// Recent output lines passed through per step.
const RECENT_OUTPUT_LINES: usize = 3;
/// Recent tool calls passed through per step.
const RECENT_TOOLS: usize = 3;
/// Longest one recent output line or tool argument.
const LINE_CHARS: usize = 240;
/// Output logs read for one run's detail view.
const MAX_OUTPUT_FILES: usize = 8;

pub fn router() -> Router<Arc<AppState>> {
    Router::new().route("/api/subagents", get(list)).route("/api/subagents/{id}", get(detail))
}

#[derive(Deserialize, Default)]
struct ListQuery {
    /// Exact session file of the launching chat.
    session: Option<String>,
    /// Any value: include every chat's runs.
    all: Option<String>,
}

async fn list(Query(q): Query<ListQuery>) -> Json<Value> {
    // Scanning and parsing status files is filesystem work: keep it off the
    // async runtime's threads.
    let (now, mut runs) = task::spawn_blocking(|| {
        let now = now_ms();
        let raw = scan(now);
        (now, build_runs(&raw))
    })
    .await
    .unwrap_or_else(|_| (now_ms(), Vec::new()));
    if q.all.is_none() && q.session.is_some() {
        let session = q.session.as_deref();
        runs.retain(|r| r.get("sessionId").and_then(Value::as_str) == session);
    }
    let total = runs.len();
    Json(json!({ "at": now, "runs": runs, "total": total }))
}

async fn detail(Path(id): Path<String>) -> impl IntoResponse {
    if !safe_id(&id) {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "bad run id" })));
    }
    match task::spawn_blocking(move || detail_payload(&id)).await.ok().flatten() {
        Some(payload) => (StatusCode::OK, Json(payload)),
        None => (StatusCode::NOT_FOUND, Json(json!({ "error": "run not found or expired" }))),
    }
}

fn detail_payload(id: &str) -> Option<Value> {
    let now = now_ms();
    let raw = scan(now);
    let run = raw.iter().find(|r| r.id == id)?;
    let children: HashMap<&str, &Value> = raw.iter().map(|r| (r.id.as_str(), &r.value)).collect();
    let projected = project(&run.id, &run.value, &children).unwrap_or(Value::Null);
    let outputs = output_files(&run.dir)
        .into_iter()
        .map(|(name, path)| json!({ "name": name, "text": tail_file(&path) }))
        .collect::<Vec<_>>();
    Some(json!({ "at": now, "run": projected, "outputs": outputs }))
}

/// One `status.json` found on disk.
struct Raw {
    dir: PathBuf,
    id: String,
    mtime: u64,
    value: Value,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// pi-subagents' user-scoped temp roots. `POCKETPI_SUBAGENTS_DIR` points at
/// one root directly (tests, unusual tmpdirs).
fn roots() -> Vec<PathBuf> {
    if let Some(p) = env::var_os("POCKETPI_SUBAGENTS_DIR") {
        let p = PathBuf::from(p);
        return if p.is_dir() { vec![p] } else { Vec::new() };
    }
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir(env::temp_dir()) else { return out };
    for e in rd.flatten() {
        let name = e.file_name();
        let name = name.to_string_lossy();
        let p = e.path();
        if name.starts_with("pi-subagents-") && p.is_dir() {
            out.push(p);
        }
    }
    out
}

fn scan(now: u64) -> Vec<Raw> {
    let cutoff = now.saturating_sub(MAX_AGE_SECS * 1000);
    let mut out: Vec<Raw> = Vec::new();
    for root in roots() {
        let Ok(rd) = fs::read_dir(root.join("async-subagent-runs")) else { continue };
        for e in rd.flatten() {
            let dir = e.path();
            if !dir.is_dir() {
                continue;
            }
            let path = dir.join("status.json");
            let Ok(meta) = fs::metadata(&path) else { continue };
            if meta.len() > MAX_STATUS_BYTES {
                continue;
            }
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            if mtime < cutoff {
                continue;
            }
            let Ok(bytes) = fs::read(&path) else { continue };
            let Ok(value) = serde_json::from_slice::<Value>(&bytes) else { continue };
            let id = value
                .get("runId")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or_else(|| dir.file_name().and_then(|n| n.to_str()).map(str::to_string));
            let Some(id) = id else { continue };
            out.push(Raw { dir, id, mtime, value });
        }
    }
    // One row per run: the newest artifact wins.
    out.sort_by(|a, b| b.mtime.cmp(&a.mtime));
    let mut seen = HashSet::new();
    out.retain(|r| seen.insert(r.id.clone()));
    out
}

fn build_runs(raw: &[Raw]) -> Vec<Value> {
    let children: HashMap<&str, &Value> = raw.iter().map(|r| (r.id.as_str(), &r.value)).collect();
    let ids: HashSet<&str> = raw.iter().map(|r| r.id.as_str()).collect();
    let mut runs: Vec<Value> = raw
        .iter()
        .filter_map(|r| project(&r.id, &r.value, &children))
        .filter(|r| {
            // Shown as a step of its parent workflow instead of twice.
            match r.get("parentWorkflowRunId").and_then(Value::as_str) {
                Some(parent) => !ids.contains(parent),
                None => true,
            }
        })
        .collect();
    runs.sort_by(|a, b| {
        let live = |r: &Value| !r.get("active").and_then(Value::as_bool).unwrap_or(false);
        live(a)
            .cmp(&live(b))
            .then_with(|| num(b, "lastUpdate").cmp(&num(a, "lastUpdate")))
    });
    runs.truncate(MAX_RUNS);
    runs
}

fn project(id: &str, v: &Value, children: &HashMap<&str, &Value>) -> Option<Value> {
    if v.is_null() {
        return None;
    }
    let state = strv(v, "state").unwrap_or("unknown");
    let started = num(v, "startedAt");
    let ended = num(v, "endedAt");
    let last = num(v, "lastUpdate").or(num(v, "lastActivityAt")).or(started);
    let steps = v
        .get("steps")
        .and_then(Value::as_array)
        .map(|steps| {
            steps
                .iter()
                .enumerate()
                .map(|(i, s)| project_step(i, s, s.get("runId").and_then(Value::as_str).and_then(|id| children.get(id).copied())))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    // Status files record usage as objects (`{total}`, `{costUsd}`); single
    // runs often carry it only per step, so sum that for the header.
    let tokens = v.get("totalTokens").and_then(tokens_of).or_else(|| sum_steps(&steps, "tokens"));
    let cost = v.get("totalCost").and_then(cost_of).or_else(|| sum_costs(&steps));
    Some(json!({
        "id": id,
        "runId": id,
        "toolCallId": strv(v, "toolCallId"),
        "mode": strv(v, "mode").unwrap_or("single"),
        "state": state,
        "active": active(state),
        "sessionId": strv(v, "sessionId"),
        "cwd": strv(v, "cwd"),
        "startedAt": started,
        "endedAt": ended,
        "lastUpdate": last,
        // A live run has no duration yet: clients tick from `startedAt`, so
        // an unchanged status file doesn't look different on every poll.
        "durationMs": match (started, ended) {
            (Some(s), Some(e)) => Some(e.saturating_sub(s)),
            _ => None,
        },
        "tokens": tokens,
        "cost": cost,
        "turnCount": num(v, "turnCount"),
        "parentWorkflowRunId": strv(v, "parentWorkflowRunId"),
        "workflowKey": strv(v, "workflowKey"),
        "steps": steps,
    }))
}

fn project_step(index: usize, own: &Value, child: Option<&Value>) -> Value {
    let child_step = child.and_then(|c| c.get("steps").and_then(Value::as_array).and_then(|s| s.first()));
    let pick = |key: &str| field(own, child_step, key).cloned();
    let pick_str = |key: &str| field(own, child_step, key).and_then(Value::as_str).map(str::to_string);
    let status = pick_str("status").unwrap_or_else(|| "pending".into());
    let resolved = pick("resolvedModel");
    let model = resolved
        .as_ref()
        .and_then(|r| r.get("model"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| pick_str("model"));
    let provider = resolved.as_ref().and_then(|r| r.get("provider")).and_then(Value::as_str);
    let agent = pick_str("agent").or_else(|| pick_str("sessionName").map(|n| n.split(':').next().unwrap_or(&n).trim().to_string()));
    json!({
        "index": index,
        "agent": agent,
        "label": pick_str("label").or_else(|| pick_str("workflowKey")),
        "status": status,
        "active": active(&status),
        "activity": pick_str("activityState"),
        "startedAt": pick("startedAt"),
        "endedAt": pick("endedAt"),
        "durationMs": pick("durationMs"),
        "tokens": pick("tokens"),
        "cost": pick("totalCost").or_else(|| pick("cost")).as_ref().and_then(cost_of),
        "model": model,
        "provider": provider,
        "sessionFile": pick_str("sessionFile"),
        "runId": pick_str("runId"),
        "recentTools": recent_tools(pick("recentTools")),
        "recentOutput": recent_output(pick("recentOutput")),
        "turnCount": pick("turnCount").or_else(|| pick("turns")),
        "toolCount": pick("toolCount"),
    })
}

/// A field from the step itself, else from the child run's first step (a
/// workflow root's step only records completion).
fn field<'a>(own: &'a Value, child: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    own.get(key)
        .filter(|v| !v.is_null())
        .or_else(|| child.and_then(|c| c.get(key)).filter(|v| !v.is_null()))
}

fn recent_output(v: Option<Value>) -> Value {
    let lines = v
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|l| l.as_str().map(str::to_string))
        .map(|l| clip(l.trim_end(), LINE_CHARS))
        .filter(|l| !l.trim().is_empty())
        .collect::<Vec<_>>();
    let start = lines.len().saturating_sub(RECENT_OUTPUT_LINES);
    Value::Array(lines[start..].iter().map(|l| Value::String(l.clone())).collect())
}

fn recent_tools(v: Option<Value>) -> Value {
    let mut lines = v
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .into_iter()
        .map(|t| {
            // The files record `{tool, args, endMs}`; a plain string is
            // accepted too, so a hand-written status file still reads.
            if let Some(s) = t.as_str() {
                return clip(s.trim(), LINE_CHARS);
            }
            let tool = t.get("tool").and_then(Value::as_str).unwrap_or("tool");
            let args = t.get("args").and_then(Value::as_str).unwrap_or("");
            clip(format!("{tool} {args}").trim(), LINE_CHARS)
        })
        .collect::<Vec<_>>();
    let start = lines.len().saturating_sub(RECENT_TOOLS);
    lines.drain(..start);
    Value::Array(lines.into_iter().map(Value::String).collect())
}

fn tokens_of(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.get("total").and_then(Value::as_u64))
        .or_else(|| {
            let n = v.get("input").and_then(Value::as_u64).unwrap_or(0) + v.get("output").and_then(Value::as_u64).unwrap_or(0);
            (n > 0).then_some(n)
        })
}

fn cost_of(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.get("costUsd").and_then(Value::as_f64)).or_else(|| v.get("total").and_then(Value::as_f64))
}

fn sum_steps(steps: &[Value], key: &str) -> Option<u64> {
    let total: u64 = steps.iter().filter_map(|s| s.get(key)).filter_map(tokens_of).sum();
    (total > 0).then_some(total)
}

fn sum_costs(steps: &[Value]) -> Option<f64> {
    let total: f64 = steps.iter().filter_map(|s| s.get("cost")).filter_map(cost_of).sum();
    (total > 0.0).then_some(total)
}

fn active(state: &str) -> bool {
    !matches!(
        state.to_ascii_lowercase().as_str(),
        "complete" | "completed" | "succeeded" | "failed" | "error" | "stopped" | "cancelled" | "canceled" | "aborted" | "timed-out" | "timeout"
    )
}

fn strv<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn num(v: &Value, key: &str) -> Option<u64> {
    v.get(key).and_then(Value::as_u64)
}

fn clip(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

fn safe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `output-<n>.log` files of a run dir, in index order (plus any `.log`
/// fallback at most [`MAX_OUTPUT_FILES`]).
fn output_files(dir: &FsPath) -> Vec<(String, PathBuf)> {
    let Ok(rd) = fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<(u64, String, PathBuf)> = rd
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            let index = name.strip_prefix("output-")?.strip_suffix(".log")?.parse::<u64>().ok()?;
            let path = e.path();
            path.is_file().then_some((index, name, path))
        })
        .collect();
    files.sort_by_key(|(i, _, _)| *i);
    files.truncate(MAX_OUTPUT_FILES);
    files.into_iter().map(|(_, name, path)| (name, path)).collect()
}

/// The end of a log, without reading the whole file: agent output can be
/// large, and this runs in the detail handler.
fn tail_file(path: &FsPath) -> String {
    let Ok(mut file) = fs::File::open(path) else { return String::new() };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);
    if len > MAX_TAIL_BYTES && file.seek(SeekFrom::Start(len - MAX_TAIL_BYTES)).is_err() {
        return String::new();
    }
    let mut bytes = Vec::with_capacity(MAX_TAIL_BYTES as usize);
    if file.take(MAX_TAIL_BYTES).read_to_end(&mut bytes).is_err() {
        return String::new();
    }
    tail(&String::from_utf8_lossy(&bytes))
}

fn tail(text: &str) -> String {
    let text = if text.chars().count() > MAX_TAIL_CHARS {
        // The `MAX_TAIL_CHARS`-th character from the end, on a char boundary.
        let start = text.char_indices().rev().nth(MAX_TAIL_CHARS - 1).map(|(i, _)| i).unwrap_or(0);
        &text[start..]
    } else {
        text
    };
    let lines = text.lines().collect::<Vec<_>>();
    let start = lines.len().saturating_sub(MAX_TAIL_LINES);
    lines[start..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(id: &str, value: Value) -> Raw {
        Raw { dir: PathBuf::from(format!("/nonexistent/{id}")), id: id.to_string(), mtime: 1, value }
    }

    fn single(id: &str, state: &str, output: Value) -> Value {
        json!({
            "runId": id,
            "mode": "single",
            "state": state,
            "sessionId": "/s/chat.jsonl",
            "startedAt": 1_000,
            "lastUpdate": 2_000,
            "steps": [{
                "agent": "reviewer",
                "status": if state == "running" { "running" } else { "completed" },
                "startedAt": 1_000,
                "recentOutput": output,
                "recentTools": [{"tool": "read", "args": "src/main.rs"}],
                "tokens": {"input": 10, "output": 5}
            }]
        })
    }

    #[test]
    fn reads_the_usage_object_shapes() {
        let v = json!({
            "runId": "r",
            "state": "running",
            "startedAt": 1,
            "totalTokens": {"input": 1, "output": 2, "total": 3, "window": 3},
            "totalCost": {"inputTokens": 1, "outputTokens": 2, "costUsd": 0.5},
            "steps": []
        });
        let runs = build_runs(&[raw("r", v)]);
        assert_eq!(runs[0]["tokens"], 3);
        assert_eq!(runs[0]["cost"], 0.5);
    }

    #[test]
    fn reads_a_single_run() {
        let raw = vec![raw("r1", single("r1", "running", json!(["one", "two"])))];
        let runs = build_runs(&raw);
        assert_eq!(runs.len(), 1);
        let run = &runs[0];
        assert_eq!(run["id"], "r1");
        assert_eq!(run["state"], "running");
        assert_eq!(run["active"], true);
        // A live run has no duration yet; the client ticks from startedAt.
        assert_eq!(run["durationMs"], Value::Null);
        assert_eq!(run["tokens"], 15);
        assert_eq!(run["steps"][0]["agent"], "reviewer");
        assert_eq!(run["steps"][0]["recentOutput"], json!(["one", "two"]));
        assert_eq!(run["steps"][0]["recentTools"], json!(["read src/main.rs"]));
    }

    #[test]
    fn merges_a_workflow_childs_live_progress_into_its_step() {
        let parent = json!({
            "runId": "wf",
            "mode": "workflow",
            "state": "running",
            "sessionId": "/s/chat.jsonl",
            "startedAt": 1_000,
            "currentStep": 0,
            "steps": [{"agent": "worker", "status": "running", "runId": "child", "startedAt": 1_000}]
        });
        let child = json!({
            "runId": "child",
            "mode": "single",
            "state": "running",
            "sessionId": "/s/chat.jsonl",
            "parentWorkflowRunId": "wf",
            "workflowKey": "task-1",
            "startedAt": 1_000,
            "steps": [{
                "agent": "worker",
                "status": "running",
                "sessionFile": "/s/child.jsonl",
                "activityState": "active_long_running",
                "recentOutput": ["editing src/subagents.rs"],
                "recentTools": [{"tool": "edit", "args": "src/subagents.rs"}],
                "resolvedModel": {"provider": "opencode-go", "model": "deepseek"},
                "tokens": {"input": 7, "output": 3}
            }]
        });
        let raw = vec![raw("wf", parent), raw("child", child)];
        let runs = build_runs(&raw);
        // The child is a step of the workflow, not a second top-level run.
        assert_eq!(runs.len(), 1);
        let step = &runs[0]["steps"][0];
        assert_eq!(step["sessionFile"], "/s/child.jsonl");
        assert_eq!(step["recentOutput"], json!(["editing src/subagents.rs"]));
        assert_eq!(step["recentTools"], json!(["edit src/subagents.rs"]));
        assert_eq!(step["model"], "deepseek");
        assert_eq!(step["provider"], "opencode-go");
        assert_eq!(runs[0]["tokens"], 10);
    }

    #[test]
    fn keeps_a_child_whose_parent_is_gone() {
        let child = json!({
            "runId": "child",
            "mode": "single",
            "state": "running",
            "parentWorkflowRunId": "gone",
            "startedAt": 1_000,
            "steps": []
        });
        let runs = build_runs(&[raw("child", child)]);
        assert_eq!(runs.len(), 1);
    }

    #[test]
    fn live_runs_come_first_then_the_newest() {
        let mut old_done = single("done", "complete", json!([]));
        old_done["lastUpdate"] = json!(9_000);
        let mut live = single("live", "running", json!([]));
        live["lastUpdate"] = json!(1_500);
        let mut newer_live = single("live2", "running", json!([]));
        newer_live["lastUpdate"] = json!(2_500);
        let runs = build_runs(&[raw("done", old_done), raw("live", live), raw("live2", newer_live)]);
        let ids = runs.iter().map(|r| r["id"].as_str().unwrap()).collect::<Vec<_>>();
        assert_eq!(ids, vec!["live2", "live", "done"]);
    }

    #[test]
    fn recent_output_is_capped_and_clipped() {
        let long = "x".repeat(1_000);
        let lines = (0..10).map(|_| Value::String(long.clone())).collect::<Vec<_>>();
        let out = recent_output(Some(Value::Array(lines)));
        let out = out.as_array().unwrap();
        assert_eq!(out.len(), RECENT_OUTPUT_LINES);
        assert_eq!(out[0].as_str().unwrap().chars().count(), LINE_CHARS);
    }

    #[test]
    fn tails_are_bounded() {
        let text = (0..1_000).map(|i| format!("line {i}\n")).collect::<String>();
        let t = tail(&text);
        assert!(t.lines().count() <= MAX_TAIL_LINES);
        assert!(t.chars().count() <= MAX_TAIL_CHARS);
        assert!(t.ends_with("line 999"));
        // Never splits a multi-byte character.
        let unicode = "é".repeat(MAX_TAIL_CHARS + 100);
        assert!(tail(&unicode).chars().count() <= MAX_TAIL_CHARS);
    }

    #[test]
    fn reads_only_the_end_of_a_large_log() {
        let path = std::env::temp_dir().join(format!(
            "pocketpi-subagents-tail-{}-{}.log",
            std::process::id(),
            now_ms()
        ));
        let body = format!("{}\nTHE END", "x".repeat(MAX_TAIL_CHARS * 4));
        fs::write(&path, body).unwrap();
        let t = tail_file(&path);
        let _ = fs::remove_file(&path);
        assert!(t.ends_with("THE END"));
        assert!(t.chars().count() <= MAX_TAIL_CHARS);
    }

    #[test]
    fn run_ids_are_validated() {
        assert!(safe_id("434e4c93-5109-471b-b93e-194330d9ccac"));
        assert!(safe_id("run_1"));
        assert!(!safe_id(""));
        assert!(!safe_id("../etc/passwd"));
        assert!(!safe_id("a/b"));
        assert!(!safe_id(&"a".repeat(129)));
    }

    #[test]
    fn ignores_junk_artifacts() {
        let raw = vec![raw("null", Value::Null), raw("ok", json!({"runId": "ok", "state": "running"}))];
        let runs = build_runs(&raw);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0]["id"], "ok");
        assert_eq!(runs[0]["steps"], json!([]));
    }
}
