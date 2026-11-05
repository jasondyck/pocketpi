//! Workflow run executor.
//!
//! A run gets its own git worktree + branch (unless the workflow opts out),
//! then executes ready stages in dependency order. Agent and review stages are
//! ordinary pi RPC processes managed by the same table as chats, so the UI can
//! open any stage and watch it live. Changes are committed after each agent or
//! shell stage so reviews see a real diff. Run state is persisted as JSON and
//! every change is broadcast for the UI's live run view.

use crate::workflows::{self, Stage, StageKind, Workflow};
use crate::{AppState, Live, rpc_internal, spawn_pi_with};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
use tokio::sync::{broadcast, oneshot};

const OUTPUT_CAP: usize = 24_000;
const DEFAULT_REVIEW_MODEL: &str = "opencode-go/deepseek-v4-pro";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pending,
    Running,
    Waiting,
    Succeeded,
    Failed,
    Skipped,
    Cancelled,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct StageRun {
    pub id: String,
    pub name: String,
    pub kind: StageKind,
    pub status: Status,
    pub attempts: u32,
    pub started: Option<u64>,
    pub ended: Option<u64>,
    pub output: String,
    pub summary: String,
    pub cost: f64,
    pub session_file: Option<String>,
    pub live_key: Option<String>,
    pub prompt: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Run {
    pub id: String,
    pub workflow_id: String,
    pub workflow_name: String,
    pub project: String,
    pub status: Status,
    pub trigger: String,
    pub inputs: HashMap<String, String>,
    pub created: u64,
    pub ended: Option<u64>,
    pub cwd: Option<String>,
    pub branch: Option<String>,
    pub base: Option<String>,
    pub base_commit: Option<String>,
    pub worktree: bool,
    pub cost: f64,
    pub error: Option<String>,
    pub stages: Vec<StageRun>,
}

struct Handle {
    run: StdMutex<Run>,
    approvals: StdMutex<HashMap<String, oneshot::Sender<(bool, String)>>>,
    cancelled: std::sync::atomic::AtomicBool,
    cancel_notify: tokio::sync::Notify,
}

pub struct Engine {
    runs_dir: PathBuf,
    pub worktrees_dir: PathBuf,
    pub workflows_dir: PathBuf,
    active: StdMutex<HashMap<String, Arc<Handle>>>,
    pub tx: broadcast::Sender<Arc<str>>,
    slots: tokio::sync::Semaphore,
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

fn cap(s: &str, n: usize) -> String {
    if s.len() <= n {
        return s.to_string();
    }
    let mut start = s.len() - n;
    while !s.is_char_boundary(start) {
        start += 1;
    }
    format!("…{}", &s[start..])
}

fn first_line(s: &str, n: usize) -> String {
    let t = s.trim().lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    t.chars().take(n).collect()
}

impl Engine {
    pub fn new(home: &Path) -> Engine {
        let data = std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".local/share"));
        let runs_dir = data.join("pocketpi/runs");
        let worktrees_dir = data.join("pocketpi/worktrees");
        let _ = std::fs::create_dir_all(&runs_dir);
        let _ = std::fs::create_dir_all(&worktrees_dir);
        let (tx, _) = broadcast::channel(1024);
        let e = Engine {
            runs_dir,
            worktrees_dir,
            workflows_dir: workflows::dir(home),
            active: StdMutex::new(HashMap::new()),
            tx,
            slots: tokio::sync::Semaphore::new(2),
        };
        // Runs that were in flight when pocketpi stopped cannot resume.
        for mut r in e.list_runs(None) {
            if matches!(r.status, Status::Running | Status::Waiting | Status::Pending) {
                r.status = Status::Failed;
                r.error = Some("pocketpi restarted while this run was in progress".into());
                r.ended = Some(now());
                for s in r.stages.iter_mut() {
                    if matches!(s.status, Status::Running | Status::Waiting) {
                        s.status = Status::Cancelled;
                    }
                }
                let _ = e.persist(&r);
            }
        }
        e
    }

    fn persist(&self, run: &Run) -> std::io::Result<()> {
        let path = self.runs_dir.join(format!("{}.json", run.id));
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(run)?)?;
        std::fs::rename(tmp, path)
    }

    fn publish(&self, run: &Run) {
        let _ = self.persist(run);
        let msg = json!({"type": "run", "run": run}).to_string();
        let _ = self.tx.send(Arc::from(msg.as_str()));
    }

    pub fn list_runs(&self, workflow: Option<&str>) -> Vec<Run> {
        let mut out: Vec<Run> = std::fs::read_dir(&self.runs_dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("json"))
            .filter_map(|e| std::fs::read_to_string(e.path()).ok())
            .filter_map(|s| serde_json::from_str::<Run>(&s).ok())
            .filter(|r| workflow.is_none_or(|w| r.workflow_id == w))
            .collect();
        out.sort_by(|a, b| b.created.cmp(&a.created));
        out
    }

    pub fn get_run(&self, id: &str) -> Option<Run> {
        if let Some(h) = self.active.lock().unwrap().get(id) {
            return Some(h.run.lock().unwrap().clone());
        }
        if !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return None;
        }
        serde_json::from_str(&std::fs::read_to_string(self.runs_dir.join(format!("{id}.json"))).ok()?).ok()
    }

    /// Workflow ids that have a run in progress.
    pub fn list_active(&self) -> Vec<String> {
        self.active.lock().unwrap().values().map(|h| h.run.lock().unwrap().workflow_id.clone()).collect()
    }

    pub fn busy(&self) -> bool {
        !self.active.lock().unwrap().is_empty()
    }

    pub fn approve(&self, run_id: &str, stage: &str, ok: bool, note: String) -> bool {
        let h = self.active.lock().unwrap().get(run_id).cloned();
        let Some(h) = h else { return false };
        let tx = h.approvals.lock().unwrap().remove(stage);
        tx.map(|t| t.send((ok, note)).is_ok()).unwrap_or(false)
    }

    pub fn cancel(&self, run_id: &str) -> bool {
        let h = self.active.lock().unwrap().get(run_id).cloned();
        let Some(h) = h else { return false };
        h.cancelled.store(true, std::sync::atomic::Ordering::Relaxed);
        h.cancel_notify.notify_waiters();
        for (_, tx) in h.approvals.lock().unwrap().drain() {
            let _ = tx.send((false, "run cancelled".into()));
        }
        true
    }

    /// Removes a finished run's worktree (the branch is kept).
    pub async fn cleanup(&self, run_id: &str) -> Result<(), String> {
        let run = self.get_run(run_id).ok_or("run not found")?;
        if self.active.lock().unwrap().contains_key(run_id) {
            return Err("run is still active".into());
        }
        if !run.worktree {
            return Ok(());
        }
        if let Some(cwd) = &run.cwd {
            if Path::new(cwd).starts_with(&self.worktrees_dir) && Path::new(cwd).exists() {
                git(&run.project, &["worktree", "remove", "--force", cwd]).await?;
            }
        }
        let _ = git(&run.project, &["worktree", "prune"]).await;
        Ok(())
    }

    /// Starts a run in the background and returns its id.
    pub fn start(self: &Arc<Self>, app: Arc<AppState>, wf: Workflow, trigger: &str, inputs: HashMap<String, String>) -> Result<String, String> {
        let errs = workflows::validate(&wf);
        if !errs.is_empty() {
            return Err(errs.join("; "));
        }
        let mut inputs = inputs;
        for i in &wf.inputs {
            if !inputs.get(&i.name).is_some_and(|v| !v.trim().is_empty()) {
                if let Some(d) = &i.default {
                    inputs.insert(i.name.clone(), d.clone());
                } else if i.required {
                    return Err(format!("input {:?} is required", i.name));
                }
            }
        }
        let id = format!("{}-{:x}", chrono::Local::now().format("%Y%m%d-%H%M%S"), now() % 0xfff);
        let order = workflows::topo_order(&wf).unwrap_or_default();
        let stages = order
            .iter()
            .filter_map(|sid| wf.stages.iter().find(|s| &s.id == sid))
            .map(|s| StageRun {
                id: s.id.clone(),
                name: s.label(),
                kind: s.kind,
                status: Status::Pending,
                attempts: 0,
                started: None,
                ended: None,
                output: String::new(),
                summary: String::new(),
                cost: 0.0,
                session_file: None,
                live_key: None,
                prompt: None,
            })
            .collect();
        let run = Run {
            id: id.clone(),
            workflow_id: wf.id.clone(),
            workflow_name: wf.name.clone(),
            project: wf.project.clone(),
            status: Status::Pending,
            trigger: trigger.to_string(),
            inputs,
            created: now(),
            ended: None,
            cwd: None,
            branch: None,
            base: None,
            base_commit: None,
            worktree: wf.worktree,
            cost: 0.0,
            error: None,
            stages,
        };
        let h = Arc::new(Handle {
            run: StdMutex::new(run.clone()),
            approvals: StdMutex::new(HashMap::new()),
            cancelled: std::sync::atomic::AtomicBool::new(false),
            cancel_notify: tokio::sync::Notify::new(),
        });
        self.active.lock().unwrap().insert(id.clone(), h.clone());
        self.publish(&run);
        let me = self.clone();
        tokio::spawn(async move {
            let _slot = me.slots.acquire().await;
            let result = me.execute(&app, &wf, &h).await;
            let final_run = {
                let mut r = h.run.lock().unwrap();
                r.ended = Some(now());
                if h.cancelled.load(std::sync::atomic::Ordering::Relaxed) {
                    r.status = Status::Cancelled;
                } else {
                    match &result {
                        Ok(()) => r.status = Status::Succeeded,
                        Err(e) => {
                            r.status = Status::Failed;
                            r.error = Some(e.clone());
                        }
                    }
                }
                for s in r.stages.iter_mut() {
                    if s.status == Status::Pending {
                        s.status = Status::Skipped;
                    }
                    s.live_key = None;
                }
                r.clone()
            };
            me.active.lock().unwrap().remove(&final_run.id);
            me.publish(&final_run);
            crate::notify::run_finished(&app, &final_run).await;
        });
        Ok(id)
    }

    fn update(&self, h: &Handle, f: impl FnOnce(&mut Run)) {
        let snapshot = {
            let mut r = h.run.lock().unwrap();
            f(&mut r);
            r.clone()
        };
        self.publish(&snapshot);
    }

    async fn execute(&self, app: &Arc<AppState>, wf: &Workflow, h: &Arc<Handle>) -> Result<(), String> {
        self.update(h, |r| r.status = Status::Running);
        // --- workspace
        let (cwd, branch, base, base_commit) = if wf.worktree {
            let base = match &wf.base {
                Some(b) => b.clone(),
                None => git(&wf.project, &["rev-parse", "--abbrev-ref", "HEAD"]).await?,
            };
            let run_id = h.run.lock().unwrap().id.clone();
            let branch = format!("pocketpi/{}/{}", wf.id, run_id);
            let path = self.worktrees_dir.join(&run_id);
            let path_s = path.to_string_lossy().to_string();
            git(&wf.project, &["worktree", "add", "-b", &branch, &path_s, &base]).await?;
            let commit = git(&path_s, &["rev-parse", "HEAD"]).await?;
            (path_s, Some(branch), Some(base), Some(commit))
        } else {
            let commit = git(&wf.project, &["rev-parse", "HEAD"]).await.ok();
            (wf.project.clone(), None, None, commit)
        };
        self.update(h, |r| {
            r.cwd = Some(cwd.clone());
            r.branch = branch.clone();
            r.base = base.clone();
            r.base_commit = base_commit.clone();
        });

        let mut feedback: HashMap<String, String> = HashMap::new();
        let mut loops: HashMap<String, u32> = HashMap::new();
        loop {
            if h.cancelled.load(std::sync::atomic::Ordering::Relaxed) {
                return Err("cancelled".into());
            }
            // next ready stage in topological order
            let next = {
                let r = h.run.lock().unwrap();
                r.stages
                    .iter()
                    .find(|s| {
                        s.status == Status::Pending
                            && wf.stages.iter().find(|d| d.id == s.id).is_some_and(|d| {
                                d.needs.iter().all(|n| r.stages.iter().any(|x| &x.id == n && x.status == Status::Succeeded))
                            })
                    })
                    .map(|s| s.id.clone())
            };
            let Some(sid) = next else {
                let r = h.run.lock().unwrap();
                if r.stages.iter().all(|s| s.status == Status::Succeeded) {
                    return Ok(());
                }
                return Err("no stage can run (blocked by a failed dependency)".into());
            };
            let stage = wf.stages.iter().find(|s| s.id == sid).unwrap().clone();
            let vars = self.vars(h, &stage, feedback.get(&sid).cloned().unwrap_or_default());
            self.update(h, |r| {
                let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
                s.status = if stage.kind == StageKind::Approval { Status::Waiting } else { Status::Running };
                s.attempts += 1;
                s.started = Some(now());
                s.ended = None;
                s.output.clear();
                s.summary.clear();
            });
            let result = match stage.kind {
                StageKind::Agent => self.run_agent(app, wf, h, &stage, &cwd, &vars, false).await,
                StageKind::Review => self.run_agent(app, wf, h, &stage, &cwd, &vars, true).await,
                StageKind::Shell => self.run_shell(h, &stage, &cwd, &vars).await,
                StageKind::Approval => self.run_approval(app, h, &stage, &vars).await,
            };
            if matches!(stage.kind, StageKind::Agent | StageKind::Shell) && wf.worktree {
                let _ = commit_all(&cwd, &format!("pocketpi: {} ({})", stage.label(), wf.name)).await;
            }
            match result {
                Ok((output, summary)) => {
                    feedback.remove(&sid);
                    self.update(h, |r| {
                        let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
                        s.status = Status::Succeeded;
                        s.ended = Some(now());
                        s.summary = summary;
                        s.output = cap(&output, OUTPUT_CAP);
                    });
                }
                Err(fail) if stage.allow_fail && stage.kind == StageKind::Shell => {
                    self.update(h, |r| {
                        let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
                        s.status = Status::Succeeded;
                        s.ended = Some(now());
                        s.summary = format!("failed (allowed): {}", first_line(&fail, 140));
                        s.output = cap(&fail, OUTPUT_CAP);
                    });
                }
                Err(fail) => {
                    let cancelled = h.cancelled.load(std::sync::atomic::Ordering::Relaxed);
                    self.update(h, |r| {
                        let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
                        s.status = if cancelled { Status::Cancelled } else { Status::Failed };
                        s.ended = Some(now());
                        s.summary = first_line(&fail, 200);
                        s.output = cap(&fail, OUTPUT_CAP);
                    });
                    if cancelled {
                        return Err("cancelled".into());
                    }
                    let Some(of) = &stage.on_fail else {
                        return Err(format!("stage {} failed: {}", stage.label(), first_line(&fail, 200)));
                    };
                    let n = loops.entry(sid.clone()).or_insert(0);
                    if *n >= of.max {
                        return Err(format!("stage {} still failing after {} retries: {}", stage.label(), of.max, first_line(&fail, 200)));
                    }
                    *n += 1;
                    feedback.insert(
                        of.goto.clone(),
                        format!("The {} stage failed (attempt {} of {}). Fix this:\n{}", stage.label(), *n, of.max, cap(&fail, 8000)),
                    );
                    let reset = workflows::downstream_of(wf, &of.goto);
                    self.update(h, |r| {
                        for s in r.stages.iter_mut().filter(|s| reset.contains(s.id.as_str())) {
                            if s.id != sid {
                                s.status = Status::Pending;
                            }
                        }
                        let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
                        s.status = Status::Pending;
                    });
                }
            }
            if let Some(max) = wf.max_cost {
                let cost = h.run.lock().unwrap().cost;
                if cost > max {
                    return Err(format!("cost cap reached: ${cost:.2} > ${max:.2}"));
                }
            }
        }
    }

    fn vars(&self, h: &Handle, stage: &Stage, feedback: String) -> HashMap<String, String> {
        let r = h.run.lock().unwrap();
        let mut v = HashMap::new();
        for (k, val) in &r.inputs {
            v.insert(format!("input.{k}"), val.clone());
        }
        for s in &r.stages {
            v.insert(format!("stages.{}.output", s.id), s.output.clone());
            v.insert(format!("stages.{}.summary", s.id), s.summary.clone());
        }
        v.insert("run.id".into(), r.id.clone());
        v.insert("run.branch".into(), r.branch.clone().unwrap_or_default());
        v.insert("run.base".into(), r.base.clone().unwrap_or_default());
        v.insert("stage.id".into(), stage.id.clone());
        v.insert("feedback".into(), feedback);
        v
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_agent(
        &self,
        app: &Arc<AppState>,
        wf: &Workflow,
        h: &Arc<Handle>,
        stage: &Stage,
        cwd: &str,
        vars: &HashMap<String, String>,
        review: bool,
    ) -> Result<(String, String), String> {
        let mut extra: Vec<String> = Vec::new();
        let model = stage.model.clone().or_else(|| review.then(|| DEFAULT_REVIEW_MODEL.to_string()));
        if let Some(m) = &model {
            extra.extend(["--model".into(), m.clone()]);
        }
        if let Some(t) = &stage.thinking {
            extra.extend(["--thinking".into(), t.clone()]);
        }
        let tools = if review { Some(vec!["read".to_string(), "grep".into(), "find".into(), "ls".into()]) } else { stage.tools.clone() };
        if let Some(t) = tools {
            extra.extend(["--tools".into(), t.join(",")]);
        }
        extra.extend(["--name".into(), format!("{} · {}", wf.name, stage.label())]);

        let feedback = vars.get("feedback").cloned().unwrap_or_default();
        let mut prompt = workflows::render(stage.prompt.as_deref().unwrap_or(""), vars);
        let mut diff_file: Option<PathBuf> = None;
        if review {
            let base = h.run.lock().unwrap().base_commit.clone().unwrap_or_else(|| "HEAD~1".into());
            let diff = git(cwd, &["diff", "--no-color", "-U4", &base, "HEAD", "--", ".", ":(exclude)*.lock", ":(exclude)package-lock.json"]).await.unwrap_or_default();
            if diff.trim().is_empty() {
                return Ok(("Nothing changed in this run, so there is nothing to review.".into(), "pass: no changes".into()));
            }
            let f = self.runs_dir.join(format!("{}-{}.diff", h.run.lock().unwrap().id, stage.id));
            std::fs::write(&f, cap(&diff, 400_000)).map_err(|e| e.to_string())?;
            prompt = format!(
                "{REVIEW_PROMPT}\n\nThe full diff of this run is in {} (read it with the read tool). You may read other files in the repository for context.{}",
                f.display(),
                if prompt.trim().is_empty() { String::new() } else { format!("\n\nExtra focus from the workflow:\n{prompt}") }
            );
            diff_file = Some(f);
        }
        if !feedback.is_empty() && !stage.prompt.as_deref().unwrap_or("").contains("{{feedback}}") {
            prompt.push_str(&format!("\n\n{feedback}"));
        }

        let live = spawn_pi_with(app, cwd, None, &extra).await.map_err(|(_, e)| e)?;
        let mut rx = live.tx.subscribe();
        let _ = rpc_internal(&live, json!({"type": "get_state"})).await;
        let sid = stage.id.clone();
        self.update(h, |r| {
            let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
            s.live_key = Some(live.key.clone());
            s.session_file = live.session_file();
            s.prompt = Some(cap(&prompt, 6000));
        });
        let resp = rpc_internal(&live, json!({"type": "prompt", "message": prompt})).await.map_err(|(_, e)| e)?;
        if resp.get("success") == Some(&Value::Bool(false)) {
            close(&live).await;
            return Err(resp.get("error").and_then(Value::as_str).unwrap_or("prompt rejected").to_string());
        }
        let limit = Duration::from_secs(60 * stage.timeout_minutes.unwrap_or(60) as u64);
        let mut last_error: Option<String> = None;
        let outcome = tokio::time::timeout(limit, async {
            loop {
                tokio::select! {
                    _ = h.cancel_notify.notified() => {
                        let _ = rpc_internal(&live, json!({"type": "abort"})).await;
                        return Err("cancelled".to_string());
                    }
                    msg = rx.recv() => {
                        let line = match msg {
                            Ok(l) => l,
                            Err(broadcast::error::RecvError::Lagged(_)) => continue,
                            Err(_) => return Err("pi exited".to_string()),
                        };
                        let Ok(ev) = serde_json::from_str::<Value>(&line) else { continue };
                        match ev.get("type").and_then(Value::as_str).unwrap_or("") {
                            "agent_settled" => return Ok(ev.get("aborted") == Some(&Value::Bool(true))),
                            "pocketpi_exit" => return Err(format!("pi exited: {}", ev["stderr"].as_array().map(|a| a.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" ")).unwrap_or_default())),
                            "message_end" => {
                                let m = &ev["message"];
                                if m["role"] == "assistant" {
                                    last_error = (m["stopReason"] == "error").then(|| m["errorMessage"].as_str().unwrap_or("model error").to_string());
                                }
                            }
                            // Nobody is at the keyboard during a run: decline dialogs.
                            "extension_ui_request" => {
                                if let (Some(id), Some(method)) = (ev["id"].as_str(), ev["method"].as_str()) {
                                    if ["confirm", "select", "input", "editor"].contains(&method) {
                                        let _ = rpc_internal(&live, json!({"type": "extension_ui_response", "id": id, "cancelled": true})).await;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        })
        .await;
        let text = rpc_internal(&live, json!({"type": "get_last_assistant_text"}))
            .await
            .ok()
            .and_then(|v| v.pointer("/data/text").and_then(Value::as_str).map(String::from))
            .unwrap_or_default();
        let stats = rpc_internal(&live, json!({"type": "get_session_stats"})).await.ok();
        let cost = stats.as_ref().and_then(|v| v.pointer("/data/cost").and_then(Value::as_f64)).unwrap_or(0.0);
        let file = stats.as_ref().and_then(|v| v.pointer("/data/sessionFile").and_then(Value::as_str).map(String::from));
        close(&live).await;
        if let Some(f) = diff_file {
            let _ = std::fs::remove_file(f);
        }
        self.update(h, |r| {
            r.cost += cost;
            let s = r.stages.iter_mut().find(|s| s.id == sid).unwrap();
            s.cost += cost;
            if file.is_some() {
                s.session_file = file.clone();
            }
            s.live_key = None;
        });
        match outcome {
            Err(_) => return Err(format!("timed out after {} minutes", limit.as_secs() / 60)),
            Ok(Err(e)) => return Err(e),
            Ok(Ok(true)) => return Err("aborted".into()),
            Ok(Ok(false)) => {}
        }
        if let Some(e) = last_error {
            return Err(format!("model error: {e}"));
        }
        if review {
            return parse_review(&text);
        }
        let summary = first_line(&text, 200);
        Ok((text, summary))
    }

    async fn run_shell(&self, h: &Arc<Handle>, stage: &Stage, cwd: &str, vars: &HashMap<String, String>) -> Result<(String, String), String> {
        let cmd = workflows::render(stage.run.as_deref().unwrap_or(""), vars);
        let sid = stage.id.clone();
        self.update(h, |r| {
            r.stages.iter_mut().find(|s| s.id == sid).unwrap().prompt = Some(cmd.clone());
        });
        let (run_id, branch) = {
            let r = h.run.lock().unwrap();
            (r.id.clone(), r.branch.clone().unwrap_or_default())
        };
        let child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(format!("{cmd} 2>&1"))
            .current_dir(cwd)
            .env("POCKETPI_RUN_ID", run_id)
            .env("POCKETPI_BRANCH", branch)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .output();
        let limit = Duration::from_secs(60 * stage.timeout_minutes.unwrap_or(30) as u64);
        let out = tokio::select! {
            r = tokio::time::timeout(limit, child) => match r {
                Err(_) => return Err(format!("timed out after {} minutes", limit.as_secs() / 60)),
                Ok(Err(e)) => return Err(format!("could not run: {e}")),
                Ok(Ok(o)) => o,
            },
            _ = h.cancel_notify.notified() => return Err("cancelled".into()),
        };
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        if out.status.success() {
            let summary = text.trim().lines().last().unwrap_or("ok").chars().take(200).collect();
            Ok((text, summary))
        } else {
            Err(format!("exit {}\n{}", out.status.code().unwrap_or(-1), cap(&text, 12_000)))
        }
    }

    async fn run_approval(&self, app: &Arc<AppState>, h: &Arc<Handle>, stage: &Stage, vars: &HashMap<String, String>) -> Result<(String, String), String> {
        let msg = workflows::render(stage.prompt.as_deref().unwrap_or("Continue this run?"), vars);
        let (tx, rx) = oneshot::channel();
        h.approvals.lock().unwrap().insert(stage.id.clone(), tx);
        let sid = stage.id.clone();
        self.update(h, |r| {
            r.status = Status::Waiting;
            r.stages.iter_mut().find(|s| s.id == sid).unwrap().prompt = Some(msg.clone());
        });
        let snapshot = h.run.lock().unwrap().clone();
        crate::notify::approval_needed(app, &snapshot, &stage.label(), &msg).await;
        let answer = rx.await.unwrap_or((false, "run ended".into()));
        self.update(h, |r| r.status = Status::Running);
        match answer {
            (true, note) => Ok((note.clone(), if note.is_empty() { "approved".into() } else { format!("approved: {note}") })),
            (false, note) => Err(if note.is_empty() { "rejected".into() } else { format!("rejected: {note}") }),
        }
    }
}

const REVIEW_PROMPT: &str = "You are a senior engineer doing a code review of an automated change before it is shared. \
Report only real problems: bugs, logic errors, broken builds, security holes, committed secrets, data loss, and changes that do not do what the task asked. \
Ignore style and taste. Do not invent problems. \
Finish with ONLY this JSON as your final message: \
{\"verdict\":\"pass|block\",\"summary\":\"one sentence\",\"issues\":[{\"severity\":\"high|medium|low\",\"file\":\"path\",\"line\":0,\"title\":\"short\",\"detail\":\"what, why, how to fix\"}]} \
Use \"block\" only when there is at least one high-severity issue.";

fn parse_review(text: &str) -> Result<(String, String), String> {
    let v: Option<Value> = match (text.find('{'), text.rfind('}')) {
        (Some(a), Some(b)) if b > a => serde_json::from_str(&text[a..=b]).ok(),
        _ => None,
    };
    let Some(v) = v else {
        return Err(format!("reviewer did not return a verdict:\n{}", cap(text, 2000)));
    };
    let summary = v["summary"].as_str().unwrap_or("").to_string();
    let issues: Vec<String> = v["issues"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|i| {
                    format!(
                        "- [{}] {}{} {}{}",
                        i["severity"].as_str().unwrap_or("?"),
                        i["file"].as_str().unwrap_or(""),
                        i["line"].as_u64().filter(|l| *l > 0).map(|l| format!(":{l}")).unwrap_or_default(),
                        i["title"].as_str().unwrap_or(""),
                        i["detail"].as_str().map(|d| format!(" — {d}")).unwrap_or_default()
                    )
                })
                .collect()
        })
        .unwrap_or_default();
    let body = format!("{summary}\n{}", issues.join("\n"));
    let high = v["issues"].as_array().is_some_and(|a| a.iter().any(|i| i["severity"] == "high"));
    if v["verdict"] == "block" || high {
        Err(format!("Review blocked: {body}"))
    } else {
        Ok((body, format!("pass: {summary}")))
    }
}

async fn close(live: &Arc<Live>) {
    live.stdin.lock().await.take();
}

pub async fn git(cwd: &str, args: &[&str]) -> Result<String, String> {
    let out = tokio::process::Command::new("git")
        .args(["-c", "core.fsmonitor=false"])
        .args(args)
        .current_dir(cwd)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        Err(format!("git {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

async fn commit_all(cwd: &str, msg: &str) -> Result<(), String> {
    if git(cwd, &["status", "--porcelain"]).await?.is_empty() {
        return Ok(());
    }
    git(cwd, &["add", "-A"]).await?;
    git(cwd, &["commit", "-q", "--no-verify", "-m", msg]).await.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn review_verdicts() {
        let pass = r#"Looks fine. {"verdict":"pass","summary":"ok","issues":[{"severity":"low","title":"nit"}]}"#;
        assert!(parse_review(pass).is_ok());
        let block = r#"{"verdict":"pass","summary":"bad","issues":[{"severity":"high","file":"a.rs","line":3,"title":"panic"}]}"#;
        let e = parse_review(block).unwrap_err();
        assert!(e.contains("a.rs:3") && e.contains("panic"));
        assert!(parse_review("no json here").is_err());
    }

    #[test]
    fn caps_from_the_end() {
        assert_eq!(cap("abcdef", 3), "…def");
        assert_eq!(cap("ab", 3), "ab");
    }
}
