//! Run notifications. Milestone 1 broadcasts in-app notices on the runs
//! stream; web push (milestone 3) hooks in here.

use crate::AppState;
use crate::engine::{Run, Status};
use serde_json::json;
use std::sync::Arc;

fn notice(app: &Arc<AppState>, title: &str, body: &str, run: &Run, level: &str) {
    let msg = json!({
        "type": "notice", "title": title, "body": body, "level": level,
        "run_id": run.id, "workflow_id": run.workflow_id,
    })
    .to_string();
    let _ = app.engine.tx.send(Arc::from(msg.as_str()));
}

pub async fn approval_needed(app: &Arc<AppState>, run: &Run, stage: &str, message: &str) {
    notice(app, &format!("{} · {stage}", run.workflow_name), message, run, "approval");
}

pub async fn run_finished(app: &Arc<AppState>, run: &Run) {
    let (title, level) = match run.status {
        Status::Succeeded => (format!("{} finished", run.workflow_name), "ok"),
        Status::Cancelled => (format!("{} cancelled", run.workflow_name), "info"),
        _ => (format!("{} failed", run.workflow_name), "error"),
    };
    let body = run.error.clone().unwrap_or_else(|| format!("${:.3} · {} stages", run.cost, run.stages.len()));
    notice(app, &title, &body, run, level);
}
