//! Run notifications: in-app notices on the runs stream plus web push.

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
    let title = format!("{} · {stage}", run.workflow_name);
    notice(app, &title, message, run, "approval");
    let url = format!("/?r={}", run.id);
    app.push.send(&format!("Approval needed · {}", run.workflow_name), message, &url, &format!("run-{}", run.id)).await;
}

pub async fn run_finished(app: &Arc<AppState>, run: &Run) {
    let (title, level) = match run.status {
        Status::Succeeded => (format!("{} finished", run.workflow_name), "ok"),
        Status::Cancelled => (format!("{} cancelled", run.workflow_name), "info"),
        _ => (format!("{} failed", run.workflow_name), "error"),
    };
    let body = run.error.clone().unwrap_or_else(|| format!("${:.3} · {} stages", run.cost, run.stages.len()));
    notice(app, &title, &body, run, level);
    let url = format!("/?r={}", run.id);
    app.push.send(&title, &body, &url, &format!("run-{}", run.id)).await;
}
