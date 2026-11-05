//! Workflow definitions: a DAG of stages plus the sensors that start runs.
//!
//! Stored as one JSON file per workflow in ~/.config/pocketpi/workflows/.
//! Stage types:
//! - `agent`    a pi run (model, thinking, prompt template) in the run's worktree
//! - `shell`    a shell command in the worktree; non-zero exit fails the stage
//! - `review`   a read-only pi run that returns a pass/block verdict on the diff
//! - `approval` waits for the user to approve or reject in pocketpi
//! Any stage may set `on_fail: {goto, max}` to loop back with the failure as
//! `{{feedback}}`, e.g. review blocks -> back to the implement stage.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Workflow {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// Project folder (git repo) the workflow operates on.
    pub project: String,
    /// Run in a fresh git worktree + branch (default true).
    #[serde(default = "yes")]
    pub worktree: bool,
    /// Branch to start from; defaults to the project's current branch.
    #[serde(default)]
    pub base: Option<String>,
    /// Drafts can still be run by hand, but sensors only fire when enabled.
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub triggers: Vec<Trigger>,
    #[serde(default)]
    pub inputs: Vec<Input>,
    /// Stop the run if the summed agent cost (USD) goes over this.
    #[serde(default)]
    pub max_cost: Option<f64>,
    pub stages: Vec<Stage>,
}

fn yes() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Trigger {
    Manual,
    Schedule { cron: String },
    Git {
        #[serde(default)]
        branch: Option<String>,
        /// "commits" (new commits on branch), "pr" (new/updated PRs), "issue" (new issues)
        #[serde(default = "commits")]
        on: String,
        #[serde(default = "ten")]
        poll_minutes: u32,
    },
    Webhook,
}

fn commits() -> String {
    "commits".into()
}
fn ten() -> u32 {
    10
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Input {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub required: bool,
    #[serde(default)]
    pub default: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Stage {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: StageKind,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub needs: Vec<String>,
    /// agent/review: prompt template. approval: message shown to the user.
    #[serde(default)]
    pub prompt: Option<String>,
    /// shell: command line (run with sh -c).
    #[serde(default)]
    pub run: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub thinking: Option<String>,
    /// agent: restrict pi tools, e.g. ["read","grep","find","ls"].
    #[serde(default)]
    pub tools: Option<Vec<String>>,
    #[serde(default)]
    pub on_fail: Option<OnFail>,
    /// shell: let the run continue even if the command fails.
    #[serde(default)]
    pub allow_fail: bool,
    #[serde(default)]
    pub timeout_minutes: Option<u32>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StageKind {
    Agent,
    Shell,
    Review,
    Approval,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct OnFail {
    pub goto: String,
    #[serde(default = "two")]
    pub max: u32,
}

fn two() -> u32 {
    2
}

impl Stage {
    pub fn label(&self) -> String {
        self.name.clone().unwrap_or_else(|| self.id.clone())
    }
}

pub fn dir(home: &Path) -> PathBuf {
    std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home.join(".config"))
        .join("pocketpi/workflows")
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Checks a workflow and returns human-readable problems (empty = valid).
pub fn validate(wf: &Workflow) -> Vec<String> {
    let mut errs = Vec::new();
    if !valid_id(&wf.id) {
        errs.push(format!("id {:?} must be 1-64 chars of letters, digits, - or _", wf.id));
    }
    if wf.name.trim().is_empty() {
        errs.push("name is empty".into());
    }
    let project = Path::new(&wf.project);
    if !project.is_dir() {
        errs.push(format!("project folder not found: {}", wf.project));
    } else if wf.worktree && !project.join(".git").exists() {
        errs.push(format!("{} is not a git repository (set \"worktree\": false to run in place)", wf.project));
    }
    if wf.stages.is_empty() {
        errs.push("no stages".into());
    }
    let mut seen = HashSet::new();
    for s in &wf.stages {
        if !valid_id(&s.id) {
            errs.push(format!("stage id {:?} must be letters, digits, - or _", s.id));
        }
        if !seen.insert(s.id.as_str()) {
            errs.push(format!("duplicate stage id {:?}", s.id));
        }
        match s.kind {
            StageKind::Agent if s.prompt.as_deref().unwrap_or("").trim().is_empty() => {
                errs.push(format!("agent stage {:?} needs a prompt", s.id))
            }
            StageKind::Shell if s.run.as_deref().unwrap_or("").trim().is_empty() => {
                errs.push(format!("shell stage {:?} needs a run command", s.id))
            }
            _ => {}
        }
        if let Some(t) = &s.thinking {
            if !["off", "minimal", "low", "medium", "high", "xhigh", "max"].contains(&t.as_str()) {
                errs.push(format!("stage {:?}: unknown thinking level {:?}", s.id, t));
            }
        }
    }
    let ids: HashSet<&str> = wf.stages.iter().map(|s| s.id.as_str()).collect();
    for s in &wf.stages {
        for n in &s.needs {
            if !ids.contains(n.as_str()) {
                errs.push(format!("stage {:?} needs unknown stage {:?}", s.id, n));
            }
        }
        if let Some(f) = &s.on_fail {
            if !ids.contains(f.goto.as_str()) {
                errs.push(format!("stage {:?} on_fail goes to unknown stage {:?}", s.id, f.goto));
            } else if f.goto != s.id && !upstream_of(wf, &s.id).contains(f.goto.as_str()) {
                errs.push(format!("stage {:?} on_fail must go back to itself or an earlier stage it depends on", s.id));
            }
            if f.max == 0 || f.max > 10 {
                errs.push(format!("stage {:?} on_fail.max must be 1-10", s.id));
            }
        }
    }
    if errs.is_empty() && topo_order(wf).is_none() {
        errs.push("stages have a dependency cycle".into());
    }
    for t in &wf.triggers {
        match t {
            Trigger::Schedule { cron } => {
                if let Err(e) = crate::cron::Cron::parse(cron) {
                    errs.push(format!("schedule {cron:?}: {e}"));
                }
            }
            Trigger::Git { on, poll_minutes, .. } => {
                if !["commits", "pr", "issue"].contains(&on.as_str()) {
                    errs.push(format!("git trigger 'on' must be commits, pr or issue (got {on:?})"));
                }
                if *poll_minutes < 2 {
                    errs.push("git trigger poll_minutes must be at least 2".into());
                }
            }
            _ => {}
        }
    }
    errs
}

/// Every stage that `id` transitively depends on.
pub fn upstream_of<'a>(wf: &'a Workflow, id: &str) -> HashSet<&'a str> {
    let by_id: HashMap<&str, &Stage> = wf.stages.iter().map(|s| (s.id.as_str(), s)).collect();
    let mut out = HashSet::new();
    let mut stack: Vec<&str> = by_id.get(id).map(|s| s.needs.iter().map(String::as_str).collect()).unwrap_or_default();
    while let Some(n) = stack.pop() {
        if out.insert(n) {
            if let Some(s) = by_id.get(n) {
                stack.extend(s.needs.iter().map(String::as_str));
            }
        }
    }
    out
}

/// Every stage that transitively depends on `id` (plus `id` itself).
pub fn downstream_of<'a>(wf: &'a Workflow, id: &str) -> HashSet<&'a str> {
    let mut out: HashSet<&str> = HashSet::new();
    if let Some(s) = wf.stages.iter().find(|s| s.id == id) {
        out.insert(s.id.as_str());
    }
    loop {
        let before = out.len();
        for s in &wf.stages {
            if s.needs.iter().any(|n| out.contains(n.as_str())) {
                out.insert(s.id.as_str());
            }
        }
        if out.len() == before {
            return out;
        }
    }
}

pub fn topo_order(wf: &Workflow) -> Option<Vec<String>> {
    let mut done: Vec<String> = Vec::new();
    let mut left: Vec<&Stage> = wf.stages.iter().collect();
    while !left.is_empty() {
        let ready: Vec<&Stage> = left.iter().copied().filter(|s| s.needs.iter().all(|n| done.contains(n))).collect();
        if ready.is_empty() {
            return None;
        }
        for r in &ready {
            done.push(r.id.clone());
        }
        left.retain(|s| !done.contains(&s.id));
    }
    Some(done)
}

pub fn load_all(dir: &Path) -> Vec<Workflow> {
    let mut out: Vec<Workflow> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().extension().and_then(|x| x.to_str()) == Some("json"))
        .filter_map(|e| std::fs::read_to_string(e.path()).ok())
        .filter_map(|s| serde_json::from_str::<Workflow>(&s).ok())
        .collect();
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

pub fn load(dir: &Path, id: &str) -> Option<Workflow> {
    if !valid_id(id) {
        return None;
    }
    serde_json::from_str(&std::fs::read_to_string(dir.join(format!("{id}.json"))).ok()?).ok()
}

pub fn save(dir: &Path, wf: &Workflow) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let path = dir.join(format!("{}.json", wf.id));
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(wf)?)?;
    std::fs::rename(tmp, path)
}

pub fn delete(dir: &Path, id: &str) -> std::io::Result<()> {
    if !valid_id(id) {
        return Ok(());
    }
    std::fs::remove_file(dir.join(format!("{id}.json")))
}

/// Replaces {{input.x}}, {{stages.id.output}}, {{stages.id.summary}},
/// {{feedback}}, {{run.id}}, {{run.branch}}, {{run.base}} in a template.
pub fn render(template: &str, vars: &HashMap<String, String>) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(a) = rest.find("{{") {
        out.push_str(&rest[..a]);
        let after = &rest[a + 2..];
        match after.find("}}") {
            Some(b) => {
                let key = after[..b].trim();
                match vars.get(key) {
                    Some(v) => out.push_str(v),
                    None => out.push_str(""),
                }
                rest = &after[b + 2..];
            }
            None => {
                out.push_str(&rest[a..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

/// JSON Schema-ish description used by the chat tool and the docs page.
pub fn schema_doc() -> Value {
    serde_json::json!({
        "format": "One JSON object per workflow. Stages form a DAG via `needs`.",
        "fields": {
            "id": "slug, letters/digits/-/_",
            "name": "display name",
            "description": "what it does",
            "project": "absolute path of the git repo it works on",
            "worktree": "default true: each run gets its own git worktree and branch pocketpi/<id>/<run>",
            "base": "branch to start from (default: project's current branch)",
            "enabled": "sensors only fire when true; drafts can still be run by hand",
            "triggers": "[{type:manual} | {type:schedule, cron:'m h dom mon dow'} | {type:git, on:'commits'|'pr'|'issue', branch?, poll_minutes?} | {type:webhook}]",
            "inputs": "[{name, description, required, default}] available as {{input.name}}",
            "max_cost": "optional USD cap for the whole run",
            "stages": "[{id, type:'agent'|'shell'|'review'|'approval', name?, needs?:[ids], prompt?, run?, model?, thinking?, tools?, on_fail?:{goto, max}, allow_fail?, timeout_minutes?}]"
        },
        "stage_types": {
            "agent": "pi works in the worktree. prompt is required. Changes are committed automatically after the stage.",
            "shell": "run is a shell command in the worktree; non-zero exit fails the stage (unless allow_fail)",
            "review": "read-only reviewer; sees the run's diff and returns pass/block. prompt adds focus areas. Block = failure.",
            "approval": "pauses until the user approves or rejects in pocketpi; prompt is the message. Reject (with a note) fails the stage."
        },
        "templates": "{{input.NAME}}, {{stages.ID.output}}, {{stages.ID.summary}}, {{feedback}} (why the last attempt failed, on loop-backs), {{run.id}}, {{run.branch}}, {{run.base}}",
        "models": "pi model ids such as opencode-go/glm-5.2 (default work), opencode-go/minimax-m3.1-flash or opencode-go/deepseek-v4.1-flash (cheap/fast), opencode-go/glm-5.3 or opencode-go/kimi-k3.1-pro (hard problems), opencode-go/deepseek-v4-pro (reviews). Omit to use pi's default.",
        "example": {
            "id": "fix-and-pr", "name": "Fix and open PR", "project": "/home/user/projects/app", "enabled": false,
            "triggers": [{"type": "manual"}],
            "inputs": [{"name": "task", "description": "What to fix", "required": true}],
            "max_cost": 1.5,
            "stages": [
                {"id": "plan", "type": "agent", "model": "opencode-go/glm-5.3", "thinking": "high", "tools": ["read", "grep", "find", "ls"], "prompt": "Read the code and write a short plan for: {{input.task}}. Do not edit files."},
                {"id": "build", "type": "agent", "needs": ["plan"], "model": "opencode-go/glm-5.2", "prompt": "Implement this plan:\n{{stages.plan.output}}\n{{feedback}}"},
                {"id": "test", "type": "shell", "needs": ["build"], "run": "cargo test", "on_fail": {"goto": "build", "max": 2}},
                {"id": "review", "type": "review", "needs": ["test"], "model": "opencode-go/deepseek-v4-pro", "on_fail": {"goto": "build", "max": 2}},
                {"id": "approve", "type": "approval", "needs": ["review"], "prompt": "Open a PR for {{run.branch}}?"},
                {"id": "pr", "type": "shell", "needs": ["approve"], "run": "git push -u origin HEAD && gh pr create --fill"}
            ]
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wf(stages: Value) -> Workflow {
        serde_json::from_value(serde_json::json!({
            "id": "t", "name": "T", "project": "/tmp", "worktree": false, "stages": stages
        }))
        .unwrap()
    }

    #[test]
    fn example_parses_and_orders() {
        let mut ex: Workflow = serde_json::from_value(schema_doc()["example"].clone()).unwrap();
        ex.project = "/tmp".into();
        ex.worktree = false;
        assert!(validate(&ex).is_empty(), "{:?}", validate(&ex));
        assert_eq!(topo_order(&ex).unwrap(), vec!["plan", "build", "test", "review", "approve", "pr"]);
        assert!(downstream_of(&ex, "build").contains("pr"));
        assert!(!downstream_of(&ex, "build").contains("plan"));
    }

    #[test]
    fn catches_cycles_and_bad_refs() {
        let c = wf(serde_json::json!([
            {"id": "a", "type": "shell", "run": "true", "needs": ["b"]},
            {"id": "b", "type": "shell", "run": "true", "needs": ["a"]}
        ]));
        assert!(validate(&c).iter().any(|e| e.contains("cycle")));
        let bad = wf(serde_json::json!([
            {"id": "a", "type": "shell", "run": "true", "needs": ["zzz"]},
            {"id": "b", "type": "agent"},
            {"id": "c", "type": "shell", "run": "x", "on_fail": {"goto": "b"}}
        ]));
        let e = validate(&bad);
        assert!(e.iter().any(|e| e.contains("unknown stage")));
        assert!(e.iter().any(|e| e.contains("needs a prompt")));
        assert!(e.iter().any(|e| e.contains("earlier stage")));
    }

    #[test]
    fn renders_templates() {
        let mut v = HashMap::new();
        v.insert("input.task".to_string(), "fix it".to_string());
        assert_eq!(render("Do: {{input.task}} {{missing}}!", &v), "Do: fix it !");
        assert_eq!(render("open {{ unclosed", &v), "open {{ unclosed");
    }
}
