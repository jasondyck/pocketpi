//! Usage across every chat: cost and tokens per day, model, provider and
//! project, read from pi's session files (`GET /api/usage`).
//!
//! What counts (pi's session format): an assistant message's `usage`, a
//! `usage` entry (cache warming and the like), and the `usage` of compaction
//! and branch summaries. Assistant messages name the physical model that
//! answered; summaries and usage entries without a model are put on the
//! model the chat was using at that point.
//!
//! Each file's records are cached by (mtime, size) like `sessions::scan`, so
//! only files that changed are read again. A fork or clone copies the
//! entries before it into its new file; records are de-duplicated across
//! files by (entry id, time, tokens, cost) so copies count once.
//!
//! Costs are what pi recorded. Providers used through a subscription (pi's
//! OAuth logins) don't bill per token: their cost is pi's estimate at API
//! rates (or $0), so they're reported apart as `subscription`. OpenCode Go
//! draws from a prepaid dollar pool and is reported apart as `pool`.

use crate::AppState;
use axum::{
    Json,
    extract::{Query, State},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    hash::{Hash, Hasher},
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Instant, UNIX_EPOCH},
};

/// One usage record: a reply, a summary or a usage entry.
#[derive(Clone, Debug, PartialEq)]
pub struct Rec {
    /// Identity across files (fork copies have the same).
    key: u64,
    /// Hours since the epoch (UTC); days are cut at query time, in the
    /// client's time zone.
    hour: i64,
    /// Index into `FileUsage::models`.
    pm: u16,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    cost: f64,
}

/// The records of one session file.
#[derive(Debug, Default)]
pub struct FileUsage {
    pub cwd: String,
    /// (provider, model) pairs the records point at.
    pub models: Vec<(String, String)>,
    pub recs: Vec<Rec>,
}

/// Parsed files keyed by path, invalidated by (mtime, size).
#[derive(Default)]
pub struct Cache(Mutex<HashMap<PathBuf, (u64, u64, Arc<FileUsage>)>>);

#[derive(Deserialize, Default)]
#[serde(default)]
struct Usage {
    input: f64,
    output: f64,
    #[serde(rename = "cacheRead")]
    cache_read: f64,
    #[serde(rename = "cacheWrite")]
    cache_write: f64,
    cost: Option<CostField>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct CostField {
    total: f64,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Msg {
    role: Option<String>,
    provider: Option<String>,
    model: Option<String>,
    usage: Option<Usage>,
    timestamp: Option<f64>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Entry {
    #[serde(rename = "type")]
    ty: String,
    id: Option<String>,
    timestamp: Option<Value>,
    message: Option<Msg>,
    usage: Option<Usage>,
    provider: Option<String>,
    model: Option<String>,
    #[serde(rename = "modelId")]
    model_id: Option<String>,
    cwd: Option<String>,
}

fn entry_ms(ts: &Option<Value>) -> Option<i64> {
    match ts.as_ref()? {
        Value::String(s) => chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp_millis()),
        Value::Number(n) => n.as_f64().map(|f| f as i64),
        _ => None,
    }
}

fn record_key(id: &str, ms: i64, u: &Usage) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    id.hash(&mut h);
    ms.hash(&mut h);
    (u.input as u64, u.output as u64, u.cache_read as u64, u.cache_write as u64).hash(&mut h);
    u.cost.as_ref().map(|c| c.total.to_bits()).hash(&mut h);
    h.finish()
}

impl FileUsage {
    fn model_index(&mut self, provider: &str, model: &str) -> u16 {
        if let Some(i) = self.models.iter().position(|(p, m)| p == provider && m == model) {
            return i as u16;
        }
        self.models.push((provider.to_string(), model.to_string()));
        (self.models.len() - 1).min(u16::MAX as usize) as u16
    }

    fn push(&mut self, id: &str, ms: i64, provider: &str, model: &str, u: &Usage) {
        let cost = u.cost.as_ref().map(|c| c.total).filter(|c| c.is_finite()).unwrap_or(0.0);
        let tokens = u.input + u.output + u.cache_read + u.cache_write;
        if tokens <= 0.0 && cost == 0.0 {
            return;
        }
        let pm = self.model_index(provider, model);
        self.recs.push(Rec {
            key: record_key(id, ms, u),
            hour: ms.div_euclid(3_600_000),
            pm,
            input: u.input.max(0.0) as u64,
            output: u.output.max(0.0) as u64,
            cache_read: u.cache_read.max(0.0) as u64,
            cache_write: u.cache_write.max(0.0) as u64,
            cost,
        });
    }
}

/// Reads one session file's usage records; None if it isn't a pi session.
pub fn read_file(path: &Path) -> Option<FileUsage> {
    let file = std::fs::File::open(path).ok()?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut out: Option<FileUsage> = None;
    // The model in use, for usage that doesn't name one.
    let mut current = ("unknown".to_string(), "unknown".to_string());
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let l = line.trim_end();
        let Some(fu) = out.as_mut() else {
            let e: Entry = serde_json::from_str(l).ok()?;
            if e.ty != "session" {
                return None;
            }
            out = Some(FileUsage { cwd: e.cwd.unwrap_or_default(), ..Default::default() });
            continue;
        };
        let model_change = l.starts_with(r#"{"type":"model_change""#);
        // Most lines are tool results and user messages: skip them unparsed.
        if !model_change && !l.contains(r#""usage":"#) {
            continue;
        }
        let Ok(e) = serde_json::from_str::<Entry>(l) else { continue };
        let id = e.id.as_deref().unwrap_or("");
        match e.ty.as_str() {
            "model_change" => {
                if let (Some(p), Some(m)) = (e.provider, e.model_id) {
                    current = (p, m);
                }
            }
            "message" => {
                let Some(m) = e.message else { continue };
                if m.role.as_deref() != Some("assistant") {
                    continue;
                }
                if let (Some(p), Some(mo)) = (&m.provider, &m.model) {
                    current = (p.clone(), mo.clone());
                }
                let Some(u) = &m.usage else { continue };
                let Some(ms) = m.timestamp.map(|t| t as i64).or_else(|| entry_ms(&e.timestamp)) else { continue };
                let p = m.provider.as_deref().unwrap_or(&current.0).to_string();
                let mo = m.model.as_deref().unwrap_or(&current.1).to_string();
                fu.push(id, ms, &p, &mo, u);
            }
            _ => {
                // `usage` entries, compaction and branch summaries.
                let Some(u) = &e.usage else { continue };
                let Some(ms) = entry_ms(&e.timestamp) else { continue };
                let p = e.provider.as_deref().unwrap_or(&current.0).to_string();
                let mo = e.model.as_deref().unwrap_or(&current.1).to_string();
                fu.push(id, ms, &p, &mo, u);
            }
        }
    }
    out
}

fn mtime_size(md: &std::fs::Metadata) -> (u64, u64) {
    let mtime = md.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_millis() as u64).unwrap_or(0);
    (mtime, md.len())
}

/// Every session file's records under `roots` (pi's layout: one folder per
/// working directory, or flat), reading only files that changed. Returns the
/// files and how many had to be read.
pub fn scan(roots: &[PathBuf], cache: &Cache) -> (Vec<Arc<FileUsage>>, usize) {
    let mut files = Vec::new();
    for root in roots {
        for entry in std::fs::read_dir(root).into_iter().flatten().flatten() {
            match entry.file_type() {
                Ok(t) if t.is_dir() => files.extend(std::fs::read_dir(entry.path()).into_iter().flatten().flatten()),
                Ok(t) if t.is_file() => files.push(entry),
                _ => {}
            }
        }
    }
    let mut out = Vec::new();
    let mut todo: Vec<(PathBuf, u64, u64)> = Vec::new();
    let mut seen = HashSet::new();
    {
        let c = cache.0.lock().unwrap();
        for f in files {
            let path = f.path();
            if path.extension().and_then(|e| e.to_str()) != Some("jsonl") || !seen.insert(path.clone()) {
                continue;
            }
            let Ok(md) = f.metadata() else { continue };
            let (mtime, size) = mtime_size(&md);
            match c.get(&path) {
                Some((m, s, fu)) if *m == mtime && *s == size => out.push(fu.clone()),
                _ => todo.push((path, mtime, size)),
            }
        }
    }
    let read = todo.len();
    // A first scan can be hundreds of MB: read on a few threads.
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2).clamp(1, 8);
    let chunk = todo.len().div_ceil(threads).max(1);
    let parsed: Vec<(PathBuf, u64, u64, Option<FileUsage>)> = std::thread::scope(|s| {
        let handles: Vec<_> = todo
            .chunks(chunk)
            .map(|part| s.spawn(move || part.iter().map(|(p, m, sz)| (p.clone(), *m, *sz, read_file(p))).collect::<Vec<_>>()))
            .collect();
        handles.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
    });
    let mut c = cache.0.lock().unwrap();
    for (path, mtime, size, fu) in parsed {
        // Not a session (yet): cached as empty, so it isn't read every time.
        let fu = Arc::new(fu.unwrap_or_default());
        c.insert(path, (mtime, size, fu.clone()));
        out.push(fu);
    }
    c.retain(|p, _| seen.contains(p));
    (out, read)
}

/// How a provider is paid for.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Billing {
    /// Pay per token: the cost is what was billed.
    Api,
    /// A subscription (pi's OAuth login): the cost is an API-rate estimate.
    Subscription,
    /// OpenCode Go: dollars drawn from a prepaid pool.
    Pool,
}

impl Billing {
    fn name(self) -> &'static str {
        match self {
            Billing::Api => "api",
            Billing::Subscription => "subscription",
            Billing::Pool => "pool",
        }
    }
}

/// Providers that only work through a subscription.
const ALWAYS_SUBSCRIPTION: &[&str] = &["openai-codex", "github-copilot", "kimi-coding"];
const POOLS: &[&str] = &["opencode-go"];

pub fn billing(provider: &str, oauth: &HashSet<String>) -> Billing {
    if POOLS.contains(&provider) {
        Billing::Pool
    } else if oauth.contains(provider) || ALWAYS_SUBSCRIPTION.contains(&provider) {
        Billing::Subscription
    } else {
        Billing::Api
    }
}

/// Providers pi is logged in to with OAuth (`auth.json` type "oauth"); only
/// the types are read, never the credentials.
pub fn oauth_providers(agent_dir: &Path) -> HashSet<String> {
    std::fs::read_to_string(agent_dir.join("auth.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .map(|o| o.into_iter().filter(|(_, v)| v.get("type").and_then(Value::as_str) == Some("oauth")).map(|(k, _)| k).collect())
        .unwrap_or_default()
}

#[derive(Default, Clone, Copy, Debug, PartialEq)]
pub struct Totals {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub cost: f64,
    pub count: u64,
}

impl Totals {
    fn add(&mut self, r: &Rec) {
        self.input += r.input;
        self.output += r.output;
        self.cache_read += r.cache_read;
        self.cache_write += r.cache_write;
        self.cost += r.cost;
        self.count += 1;
    }
    pub fn tokens(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
    fn json(&self) -> Value {
        json!({
            "input": self.input, "output": self.output, "cacheRead": self.cache_read,
            "cacheWrite": self.cache_write, "tokens": self.tokens(),
            "cost": (self.cost * 1e6).round() / 1e6, "count": self.count,
        })
    }
}

/// A day number (days since 1970-01-01) as `YYYY-MM-DD`.
fn day_name(day: i64) -> String {
    chrono::DateTime::from_timestamp(day * 86_400, 0).map(|d| d.format("%Y-%m-%d").to_string()).unwrap_or_default()
}

pub struct Range {
    /// Days back, today included.
    pub days: i64,
    /// The client's offset from UTC, minutes east.
    pub tz_min: i64,
    pub now_ms: i64,
}

/// Adds up `files` over `range`: totals, per day (every day of the range,
/// empty ones too), per model, provider, project, and per billing kind.
pub fn aggregate(files: &[Arc<FileUsage>], range: &Range, oauth: &HashSet<String>) -> Value {
    let off = range.tz_min * 60;
    let today = (range.now_ms / 1000 + off).div_euclid(86_400);
    let first = today - range.days + 1;
    let mut seen: HashSet<u64> = HashSet::new();
    let mut total = Totals::default();
    let mut kinds: HashMap<Billing, Totals> = HashMap::new();
    let mut by_day: BTreeMap<i64, HashMap<Billing, Totals>> = BTreeMap::new();
    let mut by_model: HashMap<(&str, &str), Totals> = HashMap::new();
    let mut by_provider: HashMap<&str, Totals> = HashMap::new();
    let mut by_project: HashMap<&str, Totals> = HashMap::new();
    for f in files {
        for r in &f.recs {
            let day = (r.hour * 3600 + off).div_euclid(86_400);
            if day < first || day > today || !seen.insert(r.key) {
                continue;
            }
            let (p, m) = f.models.get(r.pm as usize).map(|(p, m)| (p.as_str(), m.as_str())).unwrap_or(("unknown", "unknown"));
            let b = billing(p, oauth);
            total.add(r);
            kinds.entry(b).or_default().add(r);
            by_day.entry(day).or_default().entry(b).or_default().add(r);
            by_model.entry((p, m)).or_default().add(r);
            by_provider.entry(p).or_default().add(r);
            by_project.entry(f.cwd.as_str()).or_default().add(r);
        }
    }
    let rank = |a: &Totals, b: &Totals| b.cost.total_cmp(&a.cost).then(b.tokens().cmp(&a.tokens()));
    let days: Vec<Value> = (first..=today)
        .map(|d| {
            let k = by_day.get(&d);
            let get = |b: Billing| k.and_then(|k| k.get(&b)).copied().unwrap_or_default();
            let mut all = Totals::default();
            for b in [Billing::Api, Billing::Subscription, Billing::Pool] {
                let t = get(b);
                all.input += t.input;
                all.output += t.output;
                all.cache_read += t.cache_read;
                all.cache_write += t.cache_write;
                all.cost += t.cost;
                all.count += t.count;
            }
            let mut v = all.json();
            v["day"] = json!(day_name(d));
            for b in [Billing::Api, Billing::Subscription, Billing::Pool] {
                v[b.name()] = json!({"cost": (get(b).cost * 1e6).round() / 1e6, "tokens": get(b).tokens()});
            }
            v
        })
        .collect();
    let mut models: Vec<_> = by_model.into_iter().collect();
    models.sort_by(|a, b| rank(&a.1, &b.1).then(a.0.cmp(&b.0)));
    let mut providers: Vec<_> = by_provider.into_iter().collect();
    providers.sort_by(|a, b| rank(&a.1, &b.1).then(a.0.cmp(b.0)));
    let mut projects: Vec<_> = by_project.into_iter().collect();
    projects.sort_by(|a, b| rank(&a.1, &b.1).then(a.0.cmp(b.0)));
    let with = |t: &Totals, extra: Value| {
        let mut v = t.json();
        if let (Some(o), Value::Object(e)) = (v.as_object_mut(), extra) {
            o.extend(e);
        }
        v
    };
    json!({
        "days": range.days,
        "from": day_name(first),
        "to": day_name(today),
        "tz": range.tz_min,
        "totals": total.json(),
        "billing": {
            "api": kinds.get(&Billing::Api).copied().unwrap_or_default().json(),
            "subscription": kinds.get(&Billing::Subscription).copied().unwrap_or_default().json(),
            "pool": kinds.get(&Billing::Pool).copied().unwrap_or_default().json(),
        },
        "byDay": days,
        "byModel": models.iter().map(|((p, m), t)| with(t, json!({"provider": p, "model": m, "billing": billing(p, oauth).name()}))).collect::<Vec<_>>(),
        "byProvider": providers.iter().map(|(p, t)| with(t, json!({"provider": p, "billing": billing(p, oauth).name()}))).collect::<Vec<_>>(),
        "byProject": projects.iter().map(|(c, t)| with(t, json!({"project": c}))).collect::<Vec<_>>(),
    })
}

#[derive(Deserialize)]
pub struct UsageQuery {
    days: Option<i64>,
    /// Minutes east of UTC (JS: `-new Date().getTimezoneOffset()`); the
    /// server's own zone when absent.
    tz: Option<i64>,
}

/// `GET /api/usage?days=30&tz=<minutes east of UTC>`.
pub async fn route(State(app): State<Arc<AppState>>, Query(q): Query<UsageQuery>) -> Json<Value> {
    let days = q.days.unwrap_or(30).clamp(1, 366);
    let tz_min = q.tz.filter(|t| t.abs() <= 14 * 60).unwrap_or_else(|| chrono::Local::now().offset().local_minus_utc() as i64 / 60);
    let roots = vec![app.sessions_dir.clone(), app.chat_dir.clone()];
    let cache = app.usage_cache.clone();
    let agent_dir = app.agent_dir.clone();
    let out = tokio::task::spawn_blocking(move || {
        let start = Instant::now();
        let (files, read) = scan(&roots, &cache);
        let oauth = oauth_providers(&agent_dir);
        let now_ms = chrono::Utc::now().timestamp_millis();
        let mut v = aggregate(&files, &Range { days, tz_min, now_ms }, &oauth);
        v["files"] = json!(files.len());
        v["read"] = json!(read);
        v["ms"] = json!(start.elapsed().as_millis() as u64);
        v
    })
    .await
    .unwrap_or_else(|e| json!({"error": e.to_string()}));
    Json(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("pocketpi-usage-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    const DAY: i64 = 86_400_000;
    // 2026-11-08T12:00:00Z
    const NOW: i64 = 1_794_139_200_000;

    fn assistant(id: &str, ms: i64, provider: &str, model: &str, input: u64, output: u64, cost: f64) -> String {
        json!({"type":"message","id":id,"parentId":null,"timestamp":"2026-01-01T00:00:00.000Z","message":{
            "role":"assistant","content":[{"type":"text","text":"hi \"usage\":{ nested"},{"type":"toolCall","id":"t","name":"x","arguments":{"usage":{"input":999999}}}],
            "api":"x","provider":provider,"model":model,
            "usage":{"input":input,"output":output,"cacheRead":10,"cacheWrite":5,"totalTokens":input+output+15,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":cost}},
            "stopReason":"stop","timestamp":ms}}).to_string()
    }

    fn iso(ms: i64) -> String {
        chrono::DateTime::from_timestamp_millis(ms).unwrap().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
    }

    fn write_session(path: &Path, cwd: &str, lines: &[String]) {
        let mut s = json!({"type":"session","version":3,"id":"s","timestamp":"2026-01-01T00:00:00.000Z","cwd":cwd}).to_string();
        for l in lines {
            s.push('\n');
            s.push_str(l);
        }
        s.push('\n');
        std::fs::write(path, s).unwrap();
    }

    #[test]
    fn reads_messages_usage_entries_and_summaries() {
        let dir = scratch("read");
        let f = dir.join("a.jsonl");
        write_session(&f, "/p/one", &[
            json!({"type":"message","id":"u1","parentId":null,"timestamp":iso(NOW),"message":{"role":"user","content":"what \"usage\": is","timestamp":NOW}}).to_string(),
            assistant("a1", NOW, "anthropic", "claude-x", 100, 20, 0.5),
            json!({"type":"usage","id":"w1","parentId":"a1","timestamp":iso(NOW),"kind":"cache_warm","provider":"anthropic","model":"claude-x",
                   "usage":{"input":0,"output":0,"cacheRead":50000,"cacheWrite":0,"totalTokens":50000,"cost":{"total":0.015}}}).to_string(),
            json!({"type":"model_change","id":"m1","parentId":"w1","timestamp":iso(NOW),"provider":"opencode-go","modelId":"glm"}).to_string(),
            json!({"type":"compaction","id":"c1","parentId":"m1","timestamp":iso(NOW),"summary":"s","firstKeptEntryId":"a1","tokensBefore":1,
                   "usage":{"input":1000,"output":200,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.01}}}).to_string(),
            json!({"type":"branch_summary","id":"b1","parentId":"c1","timestamp":iso(NOW),"fromId":"a1","summary":"s"}).to_string(),
            "not json at all \"usage\":".to_string(),
        ]);
        let fu = read_file(&f).unwrap();
        assert_eq!(fu.cwd, "/p/one");
        assert_eq!(fu.recs.len(), 3);
        let models: Vec<_> = fu.recs.iter().map(|r| fu.models[r.pm as usize].clone()).collect();
        assert_eq!(models[0], ("anthropic".into(), "claude-x".into()));
        // The compaction has no model: the one in use after the model change.
        assert_eq!(models[2], ("opencode-go".into(), "glm".into()));
        assert_eq!((fu.recs[0].input, fu.recs[0].output, fu.recs[0].cache_read, fu.recs[0].cache_write), (100, 20, 10, 5));
        assert_eq!(fu.recs[1].cache_read, 50000);
        assert!((fu.recs[2].cost - 0.01).abs() < 1e-9);
        // Not a session file.
        std::fs::write(dir.join("b.jsonl"), "{\"type\":\"message\"}\n").unwrap();
        assert!(read_file(&dir.join("b.jsonl")).is_none());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn aggregates_by_day_model_provider_project_and_billing() {
        let dir = scratch("agg");
        std::fs::create_dir_all(dir.join("--p-one--")).unwrap();
        std::fs::create_dir_all(dir.join("--p-two--")).unwrap();
        let a = [
            assistant("a1", NOW, "anthropic", "claude-x", 100, 20, 1.0),
            assistant("a2", NOW - DAY, "openai-codex", "gpt-y", 1000, 100, 0.0),
            assistant("a3", NOW - 2 * DAY, "opencode-go", "glm", 10, 1, 0.25),
            assistant("old", NOW - 40 * DAY, "anthropic", "claude-x", 5, 5, 9.0),
        ];
        write_session(&dir.join("--p-one--/a.jsonl"), "/p/one", &a);
        // A fork: copies a1 and a2, adds its own reply.
        let fork = [a[0].clone(), a[1].clone(), assistant("f1", NOW, "xai", "grok", 1, 1, 0.5)];
        write_session(&dir.join("--p-two--/fork.jsonl"), "/p/two", &fork);
        let cache = Cache::default();
        let (files, read) = scan(&[dir.clone()], &cache);
        assert_eq!((files.len(), read), (2, 2));
        let oauth: HashSet<String> = ["xai".to_string()].into();
        let v = aggregate(&files, &Range { days: 7, tz_min: 0, now_ms: NOW }, &oauth);
        assert_eq!(v["totals"]["count"], 4, "{v}");
        assert!((v["totals"]["cost"].as_f64().unwrap() - 1.75).abs() < 1e-9);
        assert_eq!(v["totals"]["input"], 100 + 1000 + 10 + 1);
        assert_eq!(v["totals"]["tokens"], (100 + 20 + 15) + (1000 + 100 + 15) + (10 + 1 + 15) + (1 + 1 + 15));
        assert_eq!(v["billing"]["api"]["cost"], 1.0);
        assert_eq!(v["billing"]["pool"]["cost"], 0.25);
        assert_eq!(v["billing"]["subscription"]["cost"], 0.5);
        assert_eq!(v["billing"]["subscription"]["count"], 2);
        let days = v["byDay"].as_array().unwrap();
        assert_eq!(days.len(), 7);
        assert_eq!(days[6]["day"], "2026-11-08");
        assert_eq!(days[6]["cost"], 1.5);
        assert_eq!(days[6]["api"]["cost"], 1.0);
        assert_eq!(days[5]["subscription"]["tokens"], 1115);
        assert_eq!(days[4]["pool"]["cost"], 0.25);
        assert_eq!(days[0]["count"], 0);
        assert_eq!(v["byModel"][0]["model"], "claude-x");
        let provider = |p: &str| v["byProvider"].as_array().unwrap().iter().find(|x| x["provider"] == p).unwrap().clone();
        assert_eq!(provider("openai-codex")["billing"], "subscription");
        assert_eq!(provider("xai")["billing"], "subscription");
        assert_eq!(provider("opencode-go")["billing"], "pool");
        assert_eq!(provider("anthropic")["billing"], "api");
        let projects = v["byProject"].as_array().unwrap();
        assert_eq!(projects.len(), 2);
        let total: u64 = projects.iter().map(|p| p["count"].as_u64().unwrap()).sum();
        assert_eq!(total, 4, "fork copies count once");
        // 90 days takes the old one in.
        let v = aggregate(&files, &Range { days: 90, tz_min: 0, now_ms: NOW }, &oauth);
        assert_eq!(v["totals"]["count"], 5);
        assert_eq!(v["byDay"].as_array().unwrap().len(), 90);

        // Cached: nothing read again until a file changes.
        let (_, read) = scan(&[dir.clone()], &cache);
        assert_eq!(read, 0);
        std::thread::sleep(std::time::Duration::from_millis(20));
        let mut more = a.to_vec();
        more.push(assistant("a5", NOW, "anthropic", "claude-x", 1, 1, 2.0));
        write_session(&dir.join("--p-one--/a.jsonl"), "/p/one", &more);
        let (files, read) = scan(&[dir.clone()], &cache);
        assert_eq!(read, 1);
        let v = aggregate(&files, &Range { days: 7, tz_min: 0, now_ms: NOW }, &oauth);
        assert!((v["totals"]["cost"].as_f64().unwrap() - 3.75).abs() < 1e-9);
        // A deleted file leaves the cache.
        std::fs::remove_file(dir.join("--p-two--/fork.jsonl")).unwrap();
        let (files, _) = scan(&[dir.clone()], &cache);
        assert_eq!(files.len(), 1);
        assert_eq!(cache.0.lock().unwrap().len(), 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn days_follow_the_clients_time_zone() {
        // 2026-11-08T02:30Z is still the 7th in New York (UTC-5).
        let ms = NOW - 9 * 3_600_000 - 30 * 60_000;
        let mut fu = FileUsage { cwd: "/p".into(), ..Default::default() };
        fu.push("x", ms, "anthropic", "m", &Usage { input: 1.0, cost: Some(CostField { total: 1.0 }), ..Default::default() });
        let files = [Arc::new(fu)];
        let utc = aggregate(&files, &Range { days: 2, tz_min: 0, now_ms: NOW }, &HashSet::new());
        assert_eq!(utc["byDay"][1]["count"], 1);
        assert_eq!(utc["byDay"][1]["day"], "2026-11-08");
        let ny = aggregate(&files, &Range { days: 2, tz_min: -300, now_ms: NOW }, &HashSet::new());
        assert_eq!(ny["byDay"][0]["day"], "2026-11-07");
        assert_eq!(ny["byDay"][0]["count"], 1);
    }

    #[test]
    fn oauth_logins_are_subscriptions() {
        let dir = scratch("auth");
        std::fs::write(dir.join("auth.json"), r#"{"xai":{"type":"oauth","access":"secret"},"groq":{"type":"api_key","key":"k"}}"#).unwrap();
        let o = oauth_providers(&dir);
        assert_eq!(billing("xai", &o), Billing::Subscription);
        assert_eq!(billing("groq", &o), Billing::Api);
        assert_eq!(billing("openai-codex", &o), Billing::Subscription);
        assert_eq!(billing("opencode-go", &o), Billing::Pool);
        assert!(oauth_providers(&dir.join("nope")).is_empty());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A few hundred synthetic sessions: the first scan and a cached one.
    /// `cargo test usage_scan_speed -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn usage_scan_speed() {
        let dir = scratch("speed");
        let filler = "x".repeat(4000);
        for p in 0..20 {
            let d = dir.join(format!("--proj-{p}--"));
            std::fs::create_dir_all(&d).unwrap();
            for s in 0..20 {
                let mut lines = Vec::new();
                for i in 0..150 {
                    lines.push(json!({"type":"message","id":format!("u{i}"),"parentId":null,"timestamp":iso(NOW),"message":{"role":"toolResult","content":[{"type":"text","text":filler}],"timestamp":NOW}}).to_string());
                    lines.push(assistant(&format!("{p}-{s}-{i}"), NOW - (i as i64) * 3_600_000, "anthropic", "claude-x", 1000, 100, 0.01));
                }
                write_session(&d.join(format!("{s}.jsonl")), &format!("/p/{p}"), &lines);
            }
        }
        let cache = Cache::default();
        let t = Instant::now();
        let (files, read) = scan(&[dir.clone()], &cache);
        let first = t.elapsed();
        let t = Instant::now();
        let v = aggregate(&files, &Range { days: 30, tz_min: 0, now_ms: NOW }, &HashSet::new());
        let agg = t.elapsed();
        let t = Instant::now();
        let (_, again) = scan(&[dir.clone()], &cache);
        let cached = t.elapsed();
        let mb: u64 = walk_size(&dir) / 1_000_000;
        println!("{read} files, {mb} MB: first scan {first:?}, aggregate {agg:?}, cached scan {cached:?} ({again} read), {} records", v["totals"]["count"]);
        assert_eq!(v["totals"]["count"], 400 * 150);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn walk_size(d: &Path) -> u64 {
        std::fs::read_dir(d).unwrap().flatten().map(|e| if e.path().is_dir() { walk_size(&e.path()) } else { e.metadata().unwrap().len() }).sum()
    }
}
