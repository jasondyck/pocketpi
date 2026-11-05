//! Self-improving workflows. After a notable run (failure, loop-back retry,
//! timeout, cost cap, or every 5th run) a reviewer model reads the workflow,
//! the run and recent history, and proposes a revised workflow. Changes that
//! pass the guardrails are applied right away in `auto` mode; everything else
//! becomes a proposal the user applies or dismisses. Every applied change is
//! versioned and can be reverted.
//!
//! Guardrails (enforced here, not trusted to the model):
//! - id, project, base, worktree, enabled and triggers never change
//! - approval and review stages can't be removed or retyped
//! - shell commands can't be added or changed (they can push, deploy, delete)
//! - max_cost can't rise by more than 50% (or be removed)

use crate::AppState;
use crate::engine::{Run, Status};
use crate::workflows::{self, Improve, StageKind, Workflow};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::{Arc, Mutex as StdMutex};
use std::sync::LazyLock;

static BUSY: LazyLock<StdMutex<HashSet<String>>> = LazyLock::new(|| StdMutex::new(HashSet::new()));

fn models() -> Vec<String> {
    std::env::var("POCKETPI_IMPROVE_MODELS")
        .unwrap_or_else(|_| "openai-codex/gpt-6.1-sol,opencode-go/deepseek-v4-pro".into())
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

const PROMPT: &str = "You improve automated coding workflows. You get a workflow definition (JSON), the record of its latest run, and stats from recent runs. \
Find GENERIC improvements that would make future runs more reliable, faster or cheaper, based on evidence in the runs: clearer or more specific prompts \
(e.g. tell a stage about a mistake it keeps making), a better-suited model or thinking level, a sensible timeout_minutes, on_fail loop-backs or retry counts, \
or splitting/merging agent stages. Don't change things that are working; don't invent problems; one-off flukes (network errors, a single model outage) are not \
reasons to change anything. If nothing clearly helps, return no changes.\n\
RULES (changes breaking them are rejected): keep id, project, base, worktree, enabled and triggers exactly as they are; never remove or change the type of \
approval or review stages; never add shell stages or change any shell stage's `run` command; never remove max_cost or raise it by more than 50%; keep stage ids \
stable for stages you keep; prefer the user's subscription models (xai/grok-4.7, openai-codex/gpt-6.1-sol) and only opencode-go/deepseek-v4.1-flash or \
opencode-go/deepseek-v4-pro on OpenCode Go.\n\
Output ONLY JSON: {\"changes\":[{\"summary\":\"short what\",\"why\":\"evidence from the runs\"}],\"workflow\":{...the complete revised workflow...}} \
or {\"changes\":[]} when nothing should change.";

fn cap(s: &str, n: usize) -> String {
    if s.len() <= n {
        return s.to_string();
    }
    let mut i = s.len() - n;
    while !s.is_char_boundary(i) {
        i += 1;
    }
    format!("…{}", &s[i..])
}

/// Problems that stop a revision from being applied automatically.
pub fn guard(cur: &Workflow, new: &Workflow) -> Vec<String> {
    let mut v = workflows::validate(new);
    for s in &cur.stages {
        if matches!(s.kind, StageKind::Approval | StageKind::Review) && !new.stages.iter().any(|n| n.id == s.id && n.kind == s.kind) {
            v.push(format!("removes or retypes the {} stage '{}'", if s.kind == StageKind::Approval { "approval" } else { "review" }, s.id));
        }
    }
    for n in new.stages.iter().filter(|n| n.kind == StageKind::Shell) {
        match cur.stages.iter().find(|s| s.id == n.id && s.kind == StageKind::Shell) {
            None => v.push(format!("adds a shell stage '{}'", n.id)),
            Some(s) if s.run != n.run => v.push(format!("changes the shell command of '{}'", n.id)),
            _ => {}
        }
    }
    if let Some(c) = cur.max_cost {
        match new.max_cost {
            None => v.push("removes the cost cap".into()),
            Some(n) if n > c * 1.5 + 1e-9 => v.push(format!("raises the cost cap from ${c:.2} to ${n:.2}")),
            _ => {}
        }
    }
    v
}

/// Forces the fields the reviewer may never change back to their current values.
fn pin(cur: &Workflow, mut new: Workflow) -> Workflow {
    new.id = cur.id.clone();
    new.project = cur.project.clone();
    new.base = cur.base.clone();
    new.worktree = cur.worktree;
    new.enabled = cur.enabled;
    new.triggers = cur.triggers.clone();
    new.improve = cur.improve;
    new
}

fn notable(run: &Run, recent: &[Run]) -> bool {
    run.status == Status::Failed
        || run.stages.iter().any(|s| s.attempts > 1)
        || run.error.as_deref().is_some_and(|e| e.contains("timed out") || e.contains("cost cap"))
        || recent.iter().filter(|r| r.workflow_id == run.workflow_id).count() % 5 == 0
}

fn run_digest(run: &Run) -> Value {
    json!({
        "id": run.id, "status": run.status, "trigger": run.trigger, "cost": run.cost, "error": run.error,
        "duration_s": run.ended.map(|e| (e.saturating_sub(run.created)) / 1000),
        "stages": run.stages.iter().map(|s| json!({
            "id": s.id, "status": s.status, "attempts": s.attempts, "cost": s.cost,
            "duration_s": match (s.started, s.ended) { (Some(a), Some(b)) => Some(b.saturating_sub(a) / 1000), _ => None },
            "summary": s.summary,
            "output_tail": cap(&s.output, if s.status == Status::Failed || s.attempts > 1 { 3000 } else { 600 }),
        })).collect::<Vec<_>>(),
    })
}

/// Called after every run; reflects only on notable ones.
pub async fn after_run(app: Arc<AppState>, run: Run, force: bool) -> Result<String, String> {
    if run.status == Status::Cancelled && !force {
        return Ok("skipped".into());
    }
    let dir = app.engine.workflows_dir.clone();
    let Some(cur) = workflows::load(&dir, &run.workflow_id) else { return Ok("workflow gone".into()) };
    if cur.improve == Improve::Off && !force {
        return Ok("off".into());
    }
    let recent = app.engine.list_runs(Some(&cur.id));
    if !force && !notable(&run, &recent) {
        return Ok("nothing notable".into());
    }
    if !BUSY.lock().unwrap().insert(cur.id.clone()) {
        return Ok("already reflecting".into());
    }
    let result = reflect(&app, &cur, &run, &recent).await;
    BUSY.lock().unwrap().remove(&cur.id);
    result
}

async fn reflect(app: &Arc<AppState>, cur: &Workflow, run: &Run, recent: &[Run]) -> Result<String, String> {
    let dir = app.engine.workflows_dir.clone();
    let stats: Vec<Value> = recent
        .iter()
        .take(8)
        .map(|r| json!({"status": r.status, "cost": r.cost, "retries": r.stages.iter().map(|s| s.attempts.saturating_sub(1)).sum::<u32>(), "error": r.error.as_deref().map(|e| cap(e, 200))}))
        .collect();
    let input = json!({ "workflow": cur, "latest_run": run_digest(run), "recent_runs": stats });
    let tmp = std::env::temp_dir().join(format!("pocketpi-improve-{}.json", run.id));
    std::fs::write(&tmp, serde_json::to_vec_pretty(&input).unwrap()).map_err(|e| e.to_string())?;
    let mut text = String::new();
    let mut used = String::new();
    for model in models() {
        let out = tokio::process::Command::new(&app.pi_bin)
            .args(["--no-session", "-p", "--model", &model, "--thinking", "high"])
            .args(["--no-tools", "--no-context-files", "--no-skills", "--no-extensions", "--no-prompt-templates"])
            .arg("--system-prompt")
            .arg(PROMPT)
            .arg(format!("@{}", tmp.display()))
            .arg("Propose improvements for this workflow.")
            .current_dir(std::env::temp_dir())
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .output();
        if let Ok(Ok(o)) = tokio::time::timeout(std::time::Duration::from_secs(400), out).await {
            let t = String::from_utf8_lossy(&o.stdout).to_string();
            if t.contains('{') {
                text = t;
                used = model;
                break;
            }
        }
    }
    let _ = std::fs::remove_file(&tmp);
    let v: Value = match (text.find('{'), text.rfind('}')) {
        (Some(a), Some(b)) if b > a => serde_json::from_str(&text[a..=b]).map_err(|e| format!("unparseable reply: {e}"))?,
        _ => return Err("no reviewer produced a reply".into()),
    };
    let changes: Vec<Value> = v["changes"].as_array().cloned().unwrap_or_default();
    if changes.is_empty() || v.get("workflow").is_none_or(Value::is_null) {
        return Ok("no changes".into());
    }
    let new: Workflow = serde_json::from_value(v["workflow"].clone()).map_err(|e| format!("invalid revised workflow: {e}"))?;
    let new = pin(cur, new);
    if serde_json::to_value(&new).ok() == serde_json::to_value(cur).ok() {
        return Ok("no effective changes".into());
    }
    let summary = changes.iter().filter_map(|c| c["summary"].as_str()).collect::<Vec<_>>().join("; ");
    let violations = guard(cur, &new);
    let url = format!("/?w={}", cur.id);
    if cur.improve == Improve::Auto && violations.is_empty() {
        workflows::save_versioned(&dir, &new, &format!("auto-improved after run {} ({used}): {summary}", run.id)).map_err(|e| e.to_string())?;
        let _ = std::fs::remove_file(workflows::proposal_path(&dir, &cur.id));
        let _ = app.engine.tx.send(Arc::from(json!({"type": "workflows_changed"}).to_string().as_str()));
        app.push.send(&format!("{} improved itself", cur.name), &summary, &url, &format!("improve-{}", cur.id)).await;
        return Ok(format!("applied: {summary}"));
    }
    let prop = json!({
        "created": std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64,
        "run_id": run.id, "model": used, "changes": changes, "violations": violations, "workflow": new,
    });
    let p = workflows::proposal_path(&dir, &cur.id);
    std::fs::create_dir_all(p.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(&p, serde_json::to_vec_pretty(&prop).unwrap()).map_err(|e| e.to_string())?;
    let _ = app.engine.tx.send(Arc::from(json!({"type": "workflows_changed"}).to_string().as_str()));
    app.push.send(&format!("Suggested improvement · {}", cur.name), &summary, &url, &format!("improve-{}", cur.id)).await;
    Ok(format!("proposed: {summary}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wf(v: Value) -> Workflow {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn guardrails() {
        let cur = wf(json!({"id":"t","name":"T","project":"/tmp","worktree":false,"max_cost":1.0,"stages":[
            {"id":"a","type":"agent","prompt":"do it"},
            {"id":"t","type":"shell","run":"cargo test","needs":["a"]},
            {"id":"r","type":"review","needs":["t"]},
            {"id":"ok","type":"approval","needs":["r"]}]}));
        // prompt and model tweaks are fine
        let mut good = cur.clone();
        good.stages[0].prompt = Some("do it, and run cargo fmt first".into());
        good.stages[0].model = Some("xai/grok-4.7".into());
        good.max_cost = Some(1.4);
        assert!(guard(&cur, &good).is_empty(), "{:?}", guard(&cur, &good));
        // dropping the approval, changing a shell command, adding a shell stage, big cost raise
        let mut bad = cur.clone();
        bad.stages.retain(|s| s.id != "ok");
        bad.stages[1].run = Some("cargo test && git push".into());
        bad.max_cost = Some(5.0);
        let v = guard(&cur, &bad);
        assert!(v.iter().any(|e| e.contains("approval")));
        assert!(v.iter().any(|e| e.contains("shell command")));
        assert!(v.iter().any(|e| e.contains("cost cap")));
        // pinned fields can't change
        let mut sneaky = cur.clone();
        sneaky.project = "/etc".into();
        sneaky.enabled = true;
        let p = pin(&cur, sneaky);
        assert_eq!(p.project, "/tmp");
        assert!(!p.enabled);
    }
}
