//! Sensors start workflow runs on their own: schedules, git activity and
//! webhooks. Only enabled workflows fire, a workflow never gets a second run
//! while one is active, and git sensors record what they see on first look
//! instead of firing for history.

use crate::AppState;
use crate::cron::Cron;
use crate::workflows::{self, Trigger, Workflow};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};

#[derive(Serialize, Deserialize, Default)]
pub struct SensorState {
    /// workflow id -> webhook token
    #[serde(default)]
    pub tokens: HashMap<String, String>,
    /// "<wf>:<trigger index>" -> last seen commit sha
    #[serde(default)]
    pub shas: HashMap<String, String>,
    /// "<wf>:<trigger index>" -> PR/issue number -> last seen updatedAt
    #[serde(default)]
    pub seen: HashMap<String, HashMap<String, String>>,
}

pub struct Sensors {
    path: PathBuf,
    pub state: StdMutex<SensorState>,
    last_poll: StdMutex<HashMap<String, Instant>>,
    last_minute: StdMutex<HashMap<String, i64>>,
}

impl Sensors {
    pub fn new(home: &std::path::Path) -> Sensors {
        let data = std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".local/share"));
        let path = data.join("pocketpi/sensors.json");
        let state = std::fs::read_to_string(&path).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        Sensors { path, state: StdMutex::new(state), last_poll: StdMutex::new(HashMap::new()), last_minute: StdMutex::new(HashMap::new()) }
    }

    fn save(&self) {
        let st = self.state.lock().unwrap();
        if let Ok(bytes) = serde_json::to_vec_pretty(&*st) {
            let tmp = self.path.with_extension("json.tmp");
            if std::fs::write(&tmp, bytes).is_ok() {
                let _ = std::fs::rename(&tmp, &self.path);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(&self.path, std::fs::Permissions::from_mode(0o600));
                }
            }
        }
    }

    /// The webhook token for a workflow, created on first use.
    pub fn token(&self, wf: &str) -> String {
        let t = {
            let mut st = self.state.lock().unwrap();
            if let Some(t) = st.tokens.get(wf) {
                return t.clone();
            }
            let t = random_hex(20);
            st.tokens.insert(wf.to_string(), t.clone());
            t
        };
        self.save();
        t
    }

    pub fn check_token(&self, wf: &str, token: &str) -> bool {
        let st = self.state.lock().unwrap();
        st.tokens.get(wf).is_some_and(|t| constant_eq(t.as_bytes(), token.as_bytes()))
    }

    pub fn rotate(&self, wf: &str) -> String {
        self.state.lock().unwrap().tokens.remove(wf);
        self.token(wf)
    }
}

fn constant_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn random_hex(n: usize) -> String {
    use std::io::Read;
    let mut buf = vec![0u8; n];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut buf);
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

fn active(app: &AppState, wf: &str) -> bool {
    app.engine.list_active().iter().any(|id| id == wf)
}

fn fire(app: &Arc<AppState>, wf: &Workflow, trigger: &str, inputs: HashMap<String, String>) {
    if active(app, &wf.id) {
        eprintln!("sensor {trigger}: {} already running, skipped", wf.id);
        return;
    }
    match app.engine.start(app.clone(), wf.clone(), trigger, inputs) {
        Ok(id) => eprintln!("sensor {trigger}: started {} run {id}", wf.id),
        Err(e) => eprintln!("sensor {trigger}: could not start {}: {e}", wf.id),
    }
}

/// Main loop: wakes every 20 seconds.
pub async fn run(app: Arc<AppState>) {
    loop {
        tokio::time::sleep(Duration::from_secs(20)).await;
        let wfs: Vec<Workflow> = workflows::load_all(&app.engine.workflows_dir).into_iter().filter(|w| w.enabled).collect();
        for wf in wfs {
            for (i, t) in wf.triggers.iter().enumerate() {
                let key = format!("{}:{i}", wf.id);
                match t {
                    Trigger::Schedule { cron } => schedule(&app, &wf, &key, cron),
                    Trigger::Git { branch, on, poll_minutes } => {
                        let due = {
                            let mut lp = app.sensors.last_poll.lock().unwrap();
                            let due = lp.get(&key).is_none_or(|t| t.elapsed() >= Duration::from_secs(*poll_minutes as u64 * 60));
                            if due {
                                lp.insert(key.clone(), Instant::now());
                            }
                            due
                        };
                        if due {
                            let (app, wf, key, branch, on) = (app.clone(), wf.clone(), key.clone(), branch.clone(), on.clone());
                            tokio::spawn(async move {
                                let r = match on.as_str() {
                                    "pr" | "issue" => poll_gh(&app, &wf, &key, &on).await,
                                    _ => poll_commits(&app, &wf, &key, branch).await,
                                };
                                if let Err(e) = r {
                                    eprintln!("sensor git {}: {e}", wf.id);
                                }
                            });
                        }
                    }
                    _ => {}
                }
            }
        }
    }
}

fn schedule(app: &Arc<AppState>, wf: &Workflow, key: &str, cron: &str) {
    let Ok(c) = Cron::parse(cron) else { return };
    let now = chrono::Local::now();
    if !c.matches(&now) {
        return;
    }
    let minute = now.timestamp() / 60;
    {
        let mut lm = app.sensors.last_minute.lock().unwrap();
        if lm.get(key) == Some(&minute) {
            return;
        }
        lm.insert(key.to_string(), minute);
    }
    let mut inputs = HashMap::new();
    inputs.insert("scheduled_for".into(), now.format("%Y-%m-%d %H:%M").to_string());
    fire(app, wf, "schedule", inputs);
}

async fn poll_commits(app: &Arc<AppState>, wf: &Workflow, key: &str, branch: Option<String>) -> Result<(), String> {
    let branch = match branch.or_else(|| wf.base.clone()) {
        Some(b) => b,
        None => crate::engine::git(&wf.project, &["rev-parse", "--abbrev-ref", "HEAD"]).await?,
    };
    let remote_ref = format!("refs/remotes/origin/{branch}");
    let sha = match crate::engine::git(&wf.project, &["fetch", "-q", "origin", &branch]).await {
        Ok(_) => crate::engine::git(&wf.project, &["rev-parse", &remote_ref]).await?,
        // no remote: watch the local branch instead
        Err(_) => crate::engine::git(&wf.project, &["rev-parse", &format!("refs/heads/{branch}")]).await?,
    };
    let prev = app.sensors.state.lock().unwrap().shas.insert(key.to_string(), sha.clone());
    app.sensors.save();
    if let Some(prev) = prev {
        if prev != sha {
            let mut inputs = HashMap::new();
            inputs.insert("commit".into(), sha);
            inputs.insert("previous".into(), prev);
            inputs.insert("branch".into(), branch);
            fire(app, wf, "git", inputs);
        }
    }
    Ok(())
}

async fn poll_gh(app: &Arc<AppState>, wf: &Workflow, key: &str, on: &str) -> Result<(), String> {
    let args: &[&str] = if on == "pr" {
        &["pr", "list", "--state", "open", "--limit", "30", "--json", "number,title,headRefName,updatedAt,url"]
    } else {
        &["issue", "list", "--state", "open", "--limit", "30", "--json", "number,title,createdAt,url"]
    };
    let out = tokio::process::Command::new("gh")
        .args(args)
        .current_dir(&wf.project)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map_err(|e| format!("gh: {e}"))?;
    if !out.status.success() {
        return Err(format!("gh: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    let items: Vec<Value> = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    let first_look = !app.sensors.state.lock().unwrap().seen.contains_key(key);
    let mut fresh = Vec::new();
    {
        let mut st = app.sensors.state.lock().unwrap();
        let seen = st.seen.entry(key.to_string()).or_default();
        for it in &items {
            let num = it["number"].to_string();
            let stamp = it["updatedAt"].as_str().or(it["createdAt"].as_str()).unwrap_or("").to_string();
            let changed = match seen.get(&num) {
                None => true,
                Some(old) => on == "pr" && old != &stamp,
            };
            seen.insert(num, stamp);
            if changed && !first_look {
                fresh.push(it.clone());
            }
        }
    }
    app.sensors.save();
    // one run per poll at most; the rest are picked up on later polls by
    // re-marking them unseen
    if let Some(it) = fresh.first() {
        let mut inputs = HashMap::new();
        inputs.insert(on.to_string(), it["number"].to_string());
        inputs.insert("title".into(), it["title"].as_str().unwrap_or("").to_string());
        inputs.insert("url".into(), it["url"].as_str().unwrap_or("").to_string());
        if let Some(b) = it["headRefName"].as_str() {
            inputs.insert("branch".into(), b.to_string());
        }
        fire(app, wf, on, inputs);
        let mut st = app.sensors.state.lock().unwrap();
        if let Some(seen) = st.seen.get_mut(key) {
            for later in fresh.iter().skip(1) {
                seen.remove(&later["number"].to_string());
            }
        }
    }
    Ok(())
}

/// Next time a schedule fires, for display.
pub fn next_fire(cron: &str) -> Option<String> {
    Cron::parse(cron).ok()?.next_after(chrono::Local::now()).map(|t| t.format("%a %b %-d, %-H:%M").to_string())
}
