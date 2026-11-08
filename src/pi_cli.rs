//! Running the pi CLI for the things only it does: installing, removing,
//! listing and updating packages, managing MCP servers, checking provider
//! credentials, and reporting pi's version.
//!
//! Only a fixed set of invocations is possible ([`Action`]); each is turned
//! into an argv here, with every user-supplied value checked so it can't be
//! read as a flag, and run directly (never through a shell) with stdin from
//! /dev/null, because a pi waiting for input would hang forever.
//!
//! Slow ones run as jobs: one at a time, their output streamed line by line
//! as `{"type":"job",...}` events on the runs event stream
//! (`/api/runs/events`), and kept for `GET /api/pi/jobs/{id}`. Quick read-only
//! ones (version, auth check, MCP list) also have a direct call, [`run_quick`].

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Command,
};

/// Jobs remembered for `GET /api/pi/jobs/{id}`.
const KEEP_JOBS: usize = 20;
/// Output kept per job (the stream has all of it).
const MAX_OUTPUT: usize = 200_000;
/// A job that runs longer than this is killed (npm on a bad network).
const JOB_TIMEOUT: Duration = Duration::from_secs(15 * 60);

#[derive(Deserialize, Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Action {
    /// `pi install <source> [-l]`; `cwd` is the project for `local`.
    Install {
        source: String,
        #[serde(default)]
        local: bool,
        #[serde(default)]
        cwd: Option<String>,
    },
    /// `pi remove <source> [-l]`.
    Remove {
        source: String,
        #[serde(default)]
        local: bool,
        #[serde(default)]
        cwd: Option<String>,
    },
    /// `pi list`.
    List {
        #[serde(default)]
        cwd: Option<String>,
    },
    /// `pi update [<source> | --extensions | --models | --all]`; with none
    /// of them, pi updates itself.
    Update {
        #[serde(default)]
        source: Option<String>,
        #[serde(default)]
        extensions: bool,
        #[serde(default)]
        models: bool,
        #[serde(default)]
        all: bool,
    },
    /// `pi mcp list --json`.
    McpList {
        #[serde(default)]
        cwd: Option<String>,
    },
    /// `pi mcp add <name> [-l] [--description d] [--exposure e] (--url <url> [--header K=V]... | [--env K=V]... -- <command> [args...])`.
    McpAdd {
        name: String,
        #[serde(default)]
        local: bool,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        url: Option<String>,
        #[serde(default)]
        headers: Vec<String>,
        #[serde(default)]
        bearer_token_env_var: Option<String>,
        #[serde(default)]
        command: Option<String>,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        env: Vec<String>,
        #[serde(default)]
        exposure: Option<String>,
        #[serde(default)]
        description: Option<String>,
    },
    /// `pi mcp remove <name> [-l]`.
    McpRemove {
        name: String,
        #[serde(default)]
        local: bool,
        #[serde(default)]
        cwd: Option<String>,
    },
    /// `pi auth check --provider <provider> --json`.
    AuthCheck { provider: String },
    /// `pi --version`.
    Version,
}

fn plain_name(what: &str, s: &str) -> Result<(), String> {
    if s.is_empty() || s.len() > 100 || !s.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)) {
        return Err(format!("{what} must be letters, digits, '.', '_' or '-'"));
    }
    Ok(())
}

/// A value that pi will see as an argument, never as an option.
fn not_a_flag(what: &str, s: &str) -> Result<(), String> {
    if s.trim().is_empty() || s.starts_with('-') || s.len() > 2000 || s.contains('\0') || s.contains('\n') {
        return Err(format!("{what} is not acceptable: {s:?}"));
    }
    Ok(())
}

fn key_value(what: &str, s: &str) -> Result<(), String> {
    not_a_flag(what, s)?;
    if !s.contains('=') {
        return Err(format!("{what} must be KEY=VALUE"));
    }
    Ok(())
}

impl Action {
    /// The arguments after `pi`, or why they can't be built.
    pub fn argv(&self) -> Result<Vec<String>, String> {
        let s = |x: &str| x.to_string();
        let mut a: Vec<String> = Vec::new();
        match self {
            Action::Install { source, local, .. } | Action::Remove { source, local, .. } => {
                not_a_flag("source", source)?;
                a.push(s(if matches!(self, Action::Install { .. }) { "install" } else { "remove" }));
                a.push(source.clone());
                if *local {
                    a.push(s("-l"));
                }
            }
            Action::List { .. } => a.push(s("list")),
            Action::Update { source, extensions, models, all } => {
                a.push(s("update"));
                let picked = source.is_some() as u8 + *extensions as u8 + *models as u8 + *all as u8;
                if picked > 1 {
                    return Err("update takes one of source, extensions, models or all".into());
                }
                if let Some(src) = source {
                    not_a_flag("source", src)?;
                    a.push(src.clone());
                }
                if *extensions {
                    a.push(s("--extensions"));
                }
                if *models {
                    a.push(s("--models"));
                }
                if *all {
                    a.push(s("--all"));
                }
            }
            Action::McpList { .. } => a.extend([s("mcp"), s("list"), s("--json")]),
            Action::McpAdd { name, local, url, headers, bearer_token_env_var, command, args, env, exposure, description, .. } => {
                plain_name("server name", name)?;
                a.extend([s("mcp"), s("add"), name.clone()]);
                if *local {
                    a.push(s("-l"));
                }
                if let Some(d) = description {
                    not_a_flag("description", d)?;
                    a.extend([s("--description"), d.clone()]);
                }
                if let Some(e) = exposure {
                    plain_name("exposure", e)?;
                    a.extend([s("--exposure"), e.clone()]);
                }
                match (url, command) {
                    (Some(u), None) => {
                        if !(u.starts_with("https://") || u.starts_with("http://")) {
                            return Err("url must be http(s)".into());
                        }
                        not_a_flag("url", u)?;
                        a.extend([s("--url"), u.clone()]);
                        for h in headers {
                            key_value("header", h)?;
                            a.extend([s("--header"), h.clone()]);
                        }
                        if let Some(v) = bearer_token_env_var {
                            plain_name("bearer token env var", v)?;
                            a.extend([s("--bearer-token-env-var"), v.clone()]);
                        }
                        if !env.is_empty() || !args.is_empty() {
                            return Err("env and args are for command servers".into());
                        }
                    }
                    (None, Some(c)) => {
                        not_a_flag("command", c)?;
                        for e in env {
                            key_value("env", e)?;
                            a.extend([s("--env"), e.clone()]);
                        }
                        if !headers.is_empty() || bearer_token_env_var.is_some() {
                            return Err("headers are for url servers".into());
                        }
                        // After `--` everything is the server's own command
                        // line, so its arguments may start with '-'.
                        a.push(s("--"));
                        a.push(c.clone());
                        for x in args {
                            if x.contains('\0') {
                                return Err("bad argument".into());
                            }
                            a.push(x.clone());
                        }
                    }
                    _ => return Err("give either url or command".into()),
                }
            }
            Action::McpRemove { name, local, .. } => {
                plain_name("server name", name)?;
                a.extend([s("mcp"), s("remove"), name.clone()]);
                if *local {
                    a.push(s("-l"));
                }
            }
            Action::AuthCheck { provider } => {
                plain_name("provider", provider)?;
                a.extend([s("auth"), s("check"), s("--provider"), provider.clone(), s("--json")]);
            }
            Action::Version => a.push(s("--version")),
        }
        Ok(a)
    }

    /// The folder pi runs in: the project for `-l` and project-aware lists.
    pub fn cwd(&self) -> Option<&str> {
        match self {
            Action::Install { cwd, .. }
            | Action::Remove { cwd, .. }
            | Action::List { cwd }
            | Action::McpList { cwd }
            | Action::McpAdd { cwd, .. }
            | Action::McpRemove { cwd, .. } => cwd.as_deref(),
            _ => None,
        }
    }

    /// Whether it may change pi's config files (and so the config epoch).
    pub fn writes_config(&self) -> bool {
        matches!(self, Action::Install { .. } | Action::Remove { .. } | Action::Update { .. } | Action::McpAdd { .. } | Action::McpRemove { .. })
    }

    /// Read-only and quick: allowed through [`run_quick`].
    pub fn is_quick(&self) -> bool {
        matches!(self, Action::Version | Action::AuthCheck { .. } | Action::McpList { .. } | Action::List { .. })
    }

    fn needs_local_cwd(&self) -> bool {
        matches!(
            self,
            Action::Install { local: true, .. } | Action::Remove { local: true, .. } | Action::McpAdd { local: true, .. } | Action::McpRemove { local: true, .. }
        )
    }
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Running,
    Ok,
    Failed,
}

#[derive(Serialize, Clone, Debug)]
pub struct Job {
    pub id: String,
    pub action: Action,
    pub argv: Vec<String>,
    pub status: JobStatus,
    pub code: Option<i32>,
    pub output: String,
    pub started: u64,
    pub ended: Option<u64>,
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

#[derive(Default)]
pub struct Jobs {
    list: Mutex<VecDeque<Job>>,
    /// One job at a time: pi's package and config commands all write the
    /// same files.
    running: Arc<tokio::sync::Mutex<()>>,
}

impl Jobs {
    pub fn get(&self, id: &str) -> Option<Job> {
        self.list.lock().unwrap().iter().find(|j| j.id == id).cloned()
    }

    pub fn recent(&self) -> Vec<Job> {
        self.list.lock().unwrap().iter().rev().cloned().collect()
    }

    fn update(&self, id: &str, f: impl FnOnce(&mut Job)) {
        if let Some(j) = self.list.lock().unwrap().iter_mut().find(|j| j.id == id) {
            f(j);
        }
    }
}

/// Resolves the folder for an action, checking it exists.
pub fn resolve_cwd(action: &Action, fallback: &std::path::Path) -> Result<std::path::PathBuf, String> {
    match action.cwd().filter(|c| !c.is_empty()) {
        Some(c) => {
            let p = std::fs::canonicalize(c).map_err(|_| format!("folder not found: {c}"))?;
            if !p.is_dir() {
                return Err(format!("not a folder: {c}"));
            }
            Ok(p)
        }
        None if action.needs_local_cwd() => Err("a project (cwd) is needed with local".into()),
        None => Ok(fallback.to_path_buf()),
    }
}

/// Starts `action` as a job and returns its id at once; 409-style error when
/// another job is running. `on_end(changed_config)` runs when it finishes.
pub fn start(
    jobs: Arc<Jobs>,
    pi_bin: String,
    action: Action,
    cwd: std::path::PathBuf,
    tx: tokio::sync::broadcast::Sender<Arc<str>>,
    on_end: impl FnOnce(bool) + Send + 'static,
) -> Result<String, String> {
    let argv = action.argv()?;
    let guard = jobs.running.clone().try_lock_owned().map_err(|_| "another pi job is running; wait for it to finish".to_string())?;
    let id = format!("job-{:x}", now());
    let job = Job { id: id.clone(), action: action.clone(), argv: argv.clone(), status: JobStatus::Running, code: None, output: String::new(), started: now(), ended: None };
    {
        let mut l = jobs.list.lock().unwrap();
        l.push_back(job);
        while l.len() > KEEP_JOBS {
            l.pop_front();
        }
    }
    let send = {
        let tx = tx.clone();
        let id = id.clone();
        move |v: Value| {
            let mut v = v;
            v["type"] = json!("job");
            v["id"] = json!(id);
            let _ = tx.send(Arc::from(v.to_string().as_str()));
        }
    };
    send(json!({"event": "start", "status": "running", "argv": argv}));
    let id2 = id.clone();
    tokio::spawn(async move {
        let _guard = guard;
        let mut cmd = Command::new(&pi_bin);
        cmd.args(&argv)
            .current_dir(&cwd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let result: Result<Option<i32>, String> = async {
            let mut child = cmd.spawn().map_err(|e| format!("failed to start pi: {e}"))?;
            let (out, err) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
            let pump = |r: Box<dyn tokio::io::AsyncRead + Unpin + Send>, stream: &'static str| {
                let (jobs, send, id) = (jobs.clone(), send.clone(), id2.clone());
                tokio::spawn(async move {
                    let mut lines = BufReader::new(r).lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        jobs.update(&id, |j| {
                            if j.output.len() < MAX_OUTPUT {
                                j.output.push_str(&line);
                                j.output.push('\n');
                            }
                        });
                        send(json!({"event": "output", "stream": stream, "line": line}));
                    }
                })
            };
            let a = pump(Box::new(out), "stdout");
            let b = pump(Box::new(err), "stderr");
            let status = tokio::time::timeout(JOB_TIMEOUT, child.wait()).await.map_err(|_| "timed out".to_string())?.map_err(|e| e.to_string())?;
            let _ = a.await;
            let _ = b.await;
            Ok(status.code())
        }
        .await;
        let (status, code, error) = match result {
            Ok(Some(0)) => (JobStatus::Ok, Some(0), None),
            Ok(code) => (JobStatus::Failed, code, None),
            Err(e) => (JobStatus::Failed, None, Some(e)),
        };
        jobs.update(&id2, |j| {
            j.status = status.clone();
            j.code = code;
            j.ended = Some(now());
            if let Some(e) = &error {
                j.output.push_str(e);
                j.output.push('\n');
            }
        });
        // Even a failed install may have half-written settings.
        on_end(action.writes_config());
        send(json!({"event": "end", "status": status, "code": code, "error": error}));
    });
    Ok(id)
}

/// Runs a quick read-only action and returns `{code, stdout, stderr, json}`
/// (`json` when stdout parses). Exit codes are information here, not
/// failures: `auth check` exits 1 for "not ready", `mcp list` for a server
/// that didn't connect, and both still print their JSON.
pub async fn run_quick(pi_bin: &str, action: &Action, cwd: &std::path::Path) -> Result<Value, String> {
    if !action.is_quick() {
        return Err("not a quick action; start it as a job".into());
    }
    let argv = action.argv()?;
    let out = Command::new(pi_bin)
        .args(&argv)
        .current_dir(cwd)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(Duration::from_secs(60), out)
        .await
        .map_err(|_| "pi took too long".to_string())?
        .map_err(|e| format!("failed to start pi: {e}"))?;
    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let parsed = serde_json::from_str::<Value>(stdout.trim()).ok();
    Ok(json!({
        "code": out.status.code(),
        "stdout": stdout,
        "stderr": String::from_utf8_lossy(&out.stderr),
        "json": parsed,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn act(v: Value) -> Result<Action, serde_json::Error> {
        serde_json::from_value(v)
    }

    #[test]
    fn builds_the_allowed_command_lines() {
        let a = act(json!({"action": "install", "source": "npm:@x/y@1", "local": true, "cwd": "/tmp"})).unwrap();
        assert_eq!(a.argv().unwrap(), ["install", "npm:@x/y@1", "-l"]);
        assert_eq!(act(json!({"action": "update", "models": true})).unwrap().argv().unwrap(), ["update", "--models"]);
        assert_eq!(act(json!({"action": "update"})).unwrap().argv().unwrap(), ["update"]);
        assert_eq!(act(json!({"action": "auth_check", "provider": "openai"})).unwrap().argv().unwrap(), ["auth", "check", "--provider", "openai", "--json"]);
        assert_eq!(act(json!({"action": "mcp_list"})).unwrap().argv().unwrap(), ["mcp", "list", "--json"]);
        assert_eq!(act(json!({"action": "version"})).unwrap().argv().unwrap(), ["--version"]);
        assert_eq!(
            act(json!({"action": "mcp_add", "name": "fs", "command": "npx", "args": ["-y", "srv", "."], "env": ["A=b"]})).unwrap().argv().unwrap(),
            ["mcp", "add", "fs", "--env", "A=b", "--", "npx", "-y", "srv", "."]
        );
        assert_eq!(
            act(json!({"action": "mcp_add", "name": "docs", "url": "https://e.com/mcp", "bearer_token_env_var": "DOCS_TOKEN"})).unwrap().argv().unwrap(),
            ["mcp", "add", "docs", "--url", "https://e.com/mcp", "--bearer-token-env-var", "DOCS_TOKEN"]
        );
    }

    #[test]
    fn refuses_flags_and_unknown_actions() {
        assert!(act(json!({"action": "install", "source": "--self"})).unwrap().argv().is_err());
        assert!(act(json!({"action": "auth_check", "provider": "x --credentials"})).unwrap().argv().is_err());
        assert!(act(json!({"action": "mcp_remove", "name": "../x"})).unwrap().argv().is_err());
        assert!(act(json!({"action": "update", "models": true, "all": true})).unwrap().argv().is_err());
        assert!(act(json!({"action": "mcp_add", "name": "x"})).unwrap().argv().is_err());
        assert!(act(json!({"action": "print_api_key", "provider": "openai"})).is_err());
        assert!(act(json!({"action": "mcp_login", "name": "x"})).is_err());
    }

    #[test]
    fn local_needs_a_project() {
        let a = act(json!({"action": "remove", "source": "npm:x", "local": true})).unwrap();
        assert!(resolve_cwd(&a, std::path::Path::new("/")).is_err());
        let a = act(json!({"action": "remove", "source": "npm:x"})).unwrap();
        assert_eq!(resolve_cwd(&a, std::path::Path::new("/")).unwrap(), std::path::PathBuf::from("/"));
    }
}
