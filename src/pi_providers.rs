//! Settings › Providers: which model providers pi can use, and API keys for
//! the ones that take one (docs/pi-parity-plan.md D1, D2).
//!
//! `GET /api/pi/providers[?refresh=1]` runs `pi auth check --provider X
//! --json` for every provider pi knows (a few at a time) and joins it with
//! what `auth.json` holds (type and whether there is a key, never the key)
//! and which environment variable would do instead. The answer is cached
//! briefly and dropped when pi's config changes or `auth.json` does (a
//! `/login` in a terminal).
//!
//! `POST /api/pi/providers/{id}/key {"key": "…"}` stores a literal API key
//! (`{"<id>": {"type": "api_key", "key": "…"}}`, through `pi_admin`, so with
//! backups and the config epoch); `POST /api/pi/providers/{id}/remove` takes
//! it out again. Keys are never sent back, and `!command` keys (pi runs
//! those) are refused: setting up a secret manager is a terminal job. OAuth
//! sign-ins also stay in the terminal (`pi` → `/login <id>`).

use crate::{AppResult, AppState, err, pi_admin, pi_cli};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};

/// How long a status list is reused.
const CACHE_TTL: Duration = Duration::from_secs(30);
/// `pi auth check`s at once (each is a node process).
const PARALLEL: usize = 6;
/// The subscription-fallback extension's defaults (extensions/subscription-fallback.ts).
const FALLBACK_MODEL: &str = "opencode-go/deepseek-v4.1-flash";
const FALLBACK_PROVIDERS: &str = "xai,openai,openai-codex";

/// A provider pi has built in.
pub struct Known {
    pub id: &'static str,
    pub name: &'static str,
    /// Environment variables pi reads a key from, in its order.
    pub env: &'static [&'static str],
    /// Takes an API key (in auth.json or the environment).
    pub api_key: bool,
    /// Has an OAuth sign-in (`/login` in pi's terminal UI).
    pub oauth: bool,
    /// The sign-in is a subscription (ChatGPT, SuperGrok, Claude, ...).
    pub subscription: bool,
}

const fn p(id: &'static str, name: &'static str, env: &'static [&'static str], api_key: bool, oauth: bool, subscription: bool) -> Known {
    Known { id, name, env, api_key, oauth, subscription }
}

/// pi 1.5.0's providers: `builtinProviders()` and `findEnvKeys()` in
/// @earendil-works/pi-ai (regenerate with `node scripts/pi-providers.mjs`),
/// plus llama.cpp, which pi's built-in llama.cpp extension adds.
pub const KNOWN: &[Known] = &[
    p("amazon-bedrock", "Amazon Bedrock", &["AWS_BEARER_TOKEN_BEDROCK", "AWS_PROFILE", "AWS_ACCESS_KEY_ID"], true, false, false),
    p("ant-ling", "Ant Ling", &["ANT_LING_API_KEY"], true, false, false),
    p("anthropic", "Anthropic", &["ANTHROPIC_API_KEY", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"], true, true, true),
    p("azure", "Azure", &["AZURE_OPENAI_API_KEY"], true, false, false),
    p("baseten", "Baseten", &["BASETEN_API_KEY"], true, false, false),
    p("cerebras", "Cerebras", &["CEREBRAS_API_KEY"], true, false, false),
    p("cloudflare-ai-gateway", "Cloudflare AI Gateway", &["CLOUDFLARE_API_KEY"], true, false, false),
    p("cloudflare-workers-ai", "Cloudflare Workers AI", &["CLOUDFLARE_API_KEY"], true, false, false),
    p("deepseek", "DeepSeek", &["DEEPSEEK_API_KEY"], true, false, false),
    p("fireworks", "Fireworks", &["FIREWORKS_API_KEY"], true, false, false),
    p("github-copilot", "GitHub Copilot", &["COPILOT_GITHUB_TOKEN"], true, true, true),
    p("google", "Google", &["GEMINI_API_KEY"], true, false, false),
    p("google-vertex", "Google Vertex AI", &["GOOGLE_CLOUD_API_KEY"], true, false, false),
    p("groq", "Groq", &["GROQ_API_KEY"], true, false, false),
    p("huggingface", "Hugging Face", &["HF_TOKEN"], true, false, false),
    p("kimi-coding", "Kimi For Coding", &["KIMI_API_KEY"], true, true, true),
    p("llama.cpp", "llama.cpp (local)", &["LLAMA_BASE_URL"], false, false, false),
    p("meta", "Meta", &["META_API_KEY"], true, true, true),
    p("minimax", "MiniMax", &["MINIMAX_API_KEY"], true, false, false),
    p("minimax-cn", "MiniMax CN", &["MINIMAX_CN_API_KEY"], true, false, false),
    p("mistral", "Mistral", &["MISTRAL_API_KEY"], true, false, false),
    p("moonshotai", "Moonshot AI", &["MOONSHOT_API_KEY"], true, false, false),
    p("moonshotai-cn", "Moonshot AI CN", &["MOONSHOT_API_KEY"], true, false, false),
    p("nvidia", "NVIDIA", &["NVIDIA_API_KEY"], true, false, false),
    p("openai", "OpenAI", &["OPENAI_API_KEY"], true, true, true),
    p("openai-codex", "OpenAI Codex (ChatGPT)", &[], false, true, true),
    p("opencode", "OpenCode Zen", &["OPENCODE_API_KEY"], true, false, false),
    p("opencode-go", "OpenCode Go", &["OPENCODE_API_KEY"], true, false, false),
    p("openrouter", "OpenRouter", &["OPENROUTER_API_KEY"], true, true, false),
    p("qwen-token-plan", "Qwen Token Plan", &["QWEN_TOKEN_PLAN_API_KEY"], true, false, false),
    p("qwen-token-plan-cn", "Qwen Token Plan CN", &["QWEN_TOKEN_PLAN_CN_API_KEY"], true, false, false),
    p("qwen-token-plan-individual", "Qwen Token Plan Individual", &["QWEN_TOKEN_PLAN_API_KEY"], true, false, false),
    p("radius", "Radius", &["RADIUS_API_KEY"], true, true, false),
    p("together", "Together", &["TOGETHER_API_KEY"], true, false, false),
    p("typesafe", "TypeSafe", &["TYPESAFE_API_KEY"], true, false, false),
    p("vercel-ai-gateway", "Vercel AI Gateway", &["AI_GATEWAY_API_KEY"], true, false, false),
    p("xai", "xAI", &["XAI_API_KEY"], true, true, true),
    p("xiaomi", "Xiaomi", &["XIAOMI_API_KEY"], true, false, false),
    p("xiaomi-token-plan-ams", "Xiaomi Token Plan AMS", &["XIAOMI_TOKEN_PLAN_AMS_API_KEY"], true, false, false),
    p("xiaomi-token-plan-cn", "Xiaomi Token Plan CN", &["XIAOMI_TOKEN_PLAN_CN_API_KEY"], true, false, false),
    p("xiaomi-token-plan-sgp", "Xiaomi Token Plan SGP", &["XIAOMI_TOKEN_PLAN_SGP_API_KEY"], true, false, false),
    p("zai", "Z.AI", &["ZAI_API_KEY"], true, false, false),
    p("zai-coding-cn", "Z.AI Coding CN", &["ZAI_CODING_CN_API_KEY"], true, false, false),
];

/// Shown first, before "more providers", even when not set up.
const COMMON: &[&str] = &["anthropic", "openai", "openai-codex", "xai", "opencode-go", "openrouter", "google", "llama.cpp"];

fn known(id: &str) -> Option<&'static Known> {
    KNOWN.iter().find(|k| k.id == id)
}

/// A provider id as pi writes them; also what may go into a patch path.
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 100 && !id.starts_with('-') && id.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

/// `auth.json` and `models.json` key for a patch path (dots escaped).
fn path_seg(id: &str) -> String {
    id.replace('\\', "\\\\").replace('.', "\\.")
}

/// Why `key` can't be stored, if it can't. Only literal keys: a value
/// starting with `!` is a command pi would run.
pub fn check_key(key: &str) -> Result<&str, String> {
    let k = key.trim();
    if k.is_empty() {
        return Err("the key is empty".into());
    }
    if k.starts_with('!') {
        return Err("keys starting with '!' are commands pi runs; set those up in auth.json from a terminal".into());
    }
    if k.len() > 4096 {
        return Err("that key is too long".into());
    }
    if k.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("an API key has no spaces or line breaks".into());
    }
    if k == pi_admin::REDACTED {
        return Err("that's the redaction marker, not a key".into());
    }
    Ok(k)
}

/// The patch that stores `key` for `id`, given its current raw credential.
/// An API-key credential keeps its other fields (an `env` with a base URL or
/// account id); anything else (an OAuth sign-in) is replaced whole.
pub fn set_key_patch(id: &str, current: Option<&Value>, key: &str) -> Value {
    let seg = path_seg(id);
    let is_api_key = current.and_then(|c| c.get("type")).and_then(Value::as_str) == Some("api_key");
    if is_api_key && current.is_some_and(Value::is_object) {
        json!({"set": {format!("{seg}.type"): "api_key", format!("{seg}.key"): key}})
    } else {
        json!({"set": {seg: {"type": "api_key", "key": key}}})
    }
}

/// The patch that removes `id`'s API key: the whole credential, or only its
/// `key` when it has more (an `env`). OAuth sign-ins aren't removed here.
pub fn remove_key_patch(id: &str, current: Option<&Value>) -> Result<Option<Value>, String> {
    let Some(cur) = current else { return Ok(None) };
    let ty = cur.get("type").and_then(Value::as_str).unwrap_or("");
    if ty != "api_key" {
        return Err(format!("{id} is signed in with {}; sign out from a terminal: pi → /logout {id}", if ty.is_empty() { "something else" } else { ty }));
    }
    let seg = path_seg(id);
    let others = cur.as_object().map(|o| o.keys().any(|k| k != "type" && k != "key")).unwrap_or(false);
    Ok(Some(if others { json!({"unset": [format!("{seg}.key")]}) } else { json!({"unset": [seg]}) }))
}

/// pi's `auth check` JSON turned into one of ready / not_configured /
/// invalid / unknown, plus pi's reason. `stored` says whether auth.json has
/// a credential, for providers pi's CLI can't see (extension providers like
/// llama.cpp answer `provider_not_found`).
pub fn status_of(check: Option<&Value>, stored: bool) -> (&'static str, Option<String>) {
    let Some(c) = check else { return ("unknown", Some("pi didn't answer".into())) };
    let reason = c.get("reason").and_then(Value::as_str).map(String::from);
    match c.get("status").and_then(Value::as_str) {
        Some("ready") => ("ready", reason),
        Some("invalid") => ("invalid", reason),
        Some("not_ready") if reason.as_deref() == Some("provider_not_found") && stored => ("unknown", reason),
        Some("not_ready") => ("not_configured", reason),
        _ => ("unknown", reason),
    }
}

/// Every provider to show: pi's built-ins, then anything else auth.json or
/// models.json names (custom providers, extension providers).
pub fn provider_ids(auth: &Value, models: &Value) -> Vec<(String, &'static str)> {
    let mut ids: Vec<(String, &'static str)> = KNOWN.iter().map(|k| (k.id.to_string(), "builtin")).collect();
    let mut extra = |id: &str, source: &'static str| {
        if valid_id(id) && !ids.iter().any(|(x, _)| x == id) {
            ids.push((id.to_string(), source));
        }
    };
    if let Some(o) = models.get("providers").and_then(Value::as_object) {
        for k in o.keys() {
            extra(k, "custom");
        }
    }
    if let Some(o) = auth.as_object() {
        for k in o.keys() {
            extra(k, "stored");
        }
    }
    ids
}

/// One row of the answer. `env_set` gets the names of the variables that are
/// set (never their values).
pub fn entry(id: &str, source: &str, stored: Option<&Value>, check: Option<&Value>, env_set: &dyn Fn(&str) -> bool) -> Value {
    let k = known(id);
    let has_stored = stored.is_some();
    let (status, reason) = status_of(check, has_stored);
    let env: Vec<&str> = k.map(|k| k.env.to_vec()).unwrap_or_default();
    let set: Vec<&str> = env.iter().copied().filter(|v| env_set(v)).collect();
    let stored_type = stored.and_then(|s| s.get("type")).and_then(Value::as_str);
    json!({
        "id": id,
        "name": k.map(|k| k.name).unwrap_or(id),
        "source": source,
        "common": COMMON.contains(&id),
        // A custom provider (models.json) takes a key like any other.
        "apiKey": k.map(|k| k.api_key).unwrap_or(source == "custom"),
        "oauth": k.map(|k| k.oauth).unwrap_or(false),
        "subscription": k.map(|k| k.subscription).unwrap_or(false),
        "env": env,
        "envSet": set,
        "stored": stored.map(|s| json!({
            "type": stored_type.unwrap_or("unknown"),
            "hasKey": has_secret(s),
        })),
        "status": status,
        "reason": reason,
        "authType": check.filter(|_| status == "ready").and_then(|c| c.get("authType")).and_then(Value::as_str),
        "login": format!("/login {id}"),
    })
}

/// Whether a stored credential holds something usable (as pi_admin's view says).
fn has_secret(cred: &Value) -> bool {
    ["key", "access", "refresh"].iter().any(|f| cred.get(f).and_then(Value::as_str).is_some_and(|v| !v.is_empty()))
}

fn read_json(path: &std::path::Path) -> Value {
    std::fs::read_to_string(path).ok().and_then(|s| serde_json::from_str::<Value>(&s).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}))
}

fn mtime(path: &std::path::Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// `provider/model` from settings.json, and the subscription fallback's
/// target from the environment pocketpi (and so every pi) runs with.
fn models_summary(app: &AppState) -> Value {
    let settings = read_json(&app.agent_dir.join("settings.json"));
    let s = |k: &str| settings.get(k).and_then(Value::as_str).filter(|v| !v.is_empty()).map(String::from);
    let fallback = std::env::var("PI_SUB_FALLBACK").ok().filter(|v| !v.trim().is_empty()).unwrap_or_else(|| FALLBACK_MODEL.into());
    let from: Vec<String> = std::env::var("PI_SUB_FALLBACK_PROVIDERS")
        .ok()
        .filter(|v| !v.trim().is_empty())
        .unwrap_or_else(|| FALLBACK_PROVIDERS.into())
        .split(',')
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .collect();
    json!({
        "default": {"provider": s("defaultProvider"), "model": s("defaultModel")},
        "fallback": {
            "model": fallback,
            "provider": fallback.split('/').next().unwrap_or(""),
            "from": from,
        },
    })
}

struct Cached {
    at: Instant,
    epoch: u64,
    auth_mtime: Option<SystemTime>,
    report: Value,
}

/// One list at a time (a second request waits for the first's answer).
static CACHE: tokio::sync::Mutex<Option<Cached>> = tokio::sync::Mutex::const_new(None);

async fn check_one(pi_bin: &str, home: &std::path::Path, id: &str) -> Option<Value> {
    let action = pi_cli::Action::AuthCheck { provider: id.to_string() };
    pi_cli::run_quick(pi_bin, &action, home).await.ok().and_then(|v| v.get("json").cloned()).filter(Value::is_object)
}

fn env_is_set(name: &str) -> bool {
    std::env::var_os(name).is_some_and(|v| !v.is_empty())
}

async fn build(app: &Arc<AppState>) -> Value {
    let auth_path = app.agent_dir.join("auth.json");
    let auth = read_json(&auth_path);
    let models = read_json(&app.agent_dir.join("models.json"));
    let ids = provider_ids(&auth, &models);
    let sem = Arc::new(tokio::sync::Semaphore::new(PARALLEL));
    let mut set = tokio::task::JoinSet::new();
    for (i, (id, _)) in ids.iter().enumerate() {
        let (sem, app, id) = (sem.clone(), app.clone(), id.clone());
        set.spawn(async move {
            let _permit = sem.acquire_owned().await;
            (i, check_one(&app.pi_bin, &app.home, &id).await)
        });
    }
    let mut checks: Vec<Option<Value>> = vec![None; ids.len()];
    while let Some(r) = set.join_next().await {
        if let Ok((i, c)) = r {
            checks[i] = c;
        }
    }
    let providers: Vec<Value> = ids
        .iter()
        .zip(&checks)
        .map(|((id, source), check)| entry(id, source, auth.get(id), check.as_ref(), &env_is_set))
        .collect();
    json!({
        "providers": providers,
        "models": models_summary(app),
        "checked": SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_millis() as u64,
    })
}

#[derive(Deserialize)]
pub struct ListQuery {
    #[serde(default)]
    refresh: Option<String>,
}

/// `GET /api/pi/providers[?refresh=1]`: `{providers, models, checked, cached}`.
pub async fn list(State(app): State<Arc<AppState>>, Query(q): Query<ListQuery>) -> Json<Value> {
    let fresh = q.refresh.as_deref().is_some_and(|r| r != "0" && r != "false");
    let epoch = app.admin.epoch();
    let auth_mtime = mtime(&app.agent_dir.join("auth.json"));
    let mut cache = CACHE.lock().await;
    if let Some(c) = cache.as_ref().filter(|c| !fresh && c.epoch == epoch && c.auth_mtime == auth_mtime && c.at.elapsed() < CACHE_TTL) {
        let mut r = c.report.clone();
        r["cached"] = json!(true);
        return Json(r);
    }
    let report = build(&app).await;
    // The checks themselves may rewrite auth.json (pi refreshes OAuth tokens).
    *cache = Some(Cached { at: Instant::now(), epoch: app.admin.epoch(), auth_mtime: mtime(&app.agent_dir.join("auth.json")), report: report.clone() });
    let mut r = report;
    r["cached"] = json!(false);
    Json(r)
}

/// Whether the page may store a key for `id`: a built-in that takes one, or
/// a provider models.json defines.
fn takes_key(app: &AppState, id: &str) -> bool {
    match known(id) {
        Some(k) => k.api_key,
        None => read_json(&app.agent_dir.join("models.json")).pointer("/providers").and_then(|p| p.get(id)).is_some(),
    }
}

async fn write(app: &Arc<AppState>, id: &str, patch: Value) -> AppResult<Json<Value>> {
    let patch: pi_admin::Patch = serde_json::from_value(patch).map_err(|e| err(StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    app.admin.patch(pi_admin::File::Auth, None, &patch).map_err(crate::admin_err)?;
    crate::config_changed(app);
    *CACHE.lock().await = None;
    Ok(Json(row(app, id).await))
}

/// One provider's row, checked now (after a change).
async fn row(app: &Arc<AppState>, id: &str) -> Value {
    let auth = read_json(&app.agent_dir.join("auth.json"));
    let source = if known(id).is_some() { "builtin" } else { "custom" };
    let check = check_one(&app.pi_bin, &app.home, id).await;
    json!({ "provider": entry(id, source, auth.get(id), check.as_ref(), &env_is_set), "epoch": app.admin.epoch() })
}

#[derive(Deserialize)]
pub struct KeyReq {
    key: String,
}

/// `POST /api/pi/providers/{id}/key {"key"}`: store a literal API key.
/// Answers `{provider, epoch}` (the row, re-checked; never the key).
pub async fn set_key(State(app): State<Arc<AppState>>, Path(id): Path<String>, Json(req): Json<KeyReq>) -> AppResult<Json<Value>> {
    if !valid_id(&id) {
        return Err(err(StatusCode::BAD_REQUEST, "bad provider id"));
    }
    if !takes_key(&app, &id) {
        return Err(err(StatusCode::BAD_REQUEST, format!("{id} doesn't take an API key here; sign in from a terminal: pi → /login {id}")));
    }
    let key = check_key(&req.key).map_err(|e| err(StatusCode::BAD_REQUEST, e))?;
    let auth = read_json(&app.agent_dir.join("auth.json"));
    write(&app, &id, set_key_patch(&id, auth.get(&id), key)).await
}

/// `POST /api/pi/providers/{id}/remove`: forget a stored API key.
pub async fn remove_key(State(app): State<Arc<AppState>>, Path(id): Path<String>) -> AppResult<Json<Value>> {
    if !valid_id(&id) {
        return Err(err(StatusCode::BAD_REQUEST, "bad provider id"));
    }
    let auth = read_json(&app.agent_dir.join("auth.json"));
    match remove_key_patch(&id, auth.get(&id)).map_err(|e| err(StatusCode::BAD_REQUEST, e))? {
        Some(patch) => write(&app, &id, patch).await,
        None => Ok(Json(row(&app, &id).await)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn apply(doc: &mut Value, patch: Value) {
        let p: pi_admin::Patch = serde_json::from_value(patch).unwrap();
        pi_admin::apply(doc, &p).unwrap();
    }

    #[test]
    fn only_literal_keys() {
        assert_eq!(check_key("  sk-abc123 \n").unwrap(), "sk-abc123");
        assert!(check_key("").is_err());
        assert!(check_key("   ").is_err());
        assert!(check_key("!security find-generic-password -ws x").is_err());
        assert!(check_key(" !op read x").is_err());
        assert!(check_key("sk abc").is_err());
        assert!(check_key("<redacted>").is_err());
        assert!(check_key(&"x".repeat(5000)).is_err());
    }

    #[test]
    fn setting_a_key_keeps_env_and_replaces_oauth() {
        let mut doc = json!({
            "llama.cpp": {"type": "api_key", "env": {"LLAMA_BASE_URL": "http://h:1"}},
            "xai": {"type": "oauth", "access": "a", "refresh": "r", "expires": 1},
        });
        let p = set_key_patch("llama.cpp", doc.get("llama.cpp"), "k1");
        apply(&mut doc, p);
        assert_eq!(doc["llama.cpp"], json!({"type": "api_key", "key": "k1", "env": {"LLAMA_BASE_URL": "http://h:1"}}));
        let p = set_key_patch("xai", doc.get("xai"), "k2");
        apply(&mut doc, p);
        assert_eq!(doc["xai"], json!({"type": "api_key", "key": "k2"}));
        let p = set_key_patch("openai", None, "k3");
        apply(&mut doc, p);
        assert_eq!(doc["openai"], json!({"type": "api_key", "key": "k3"}));
    }

    #[test]
    fn removing_a_key() {
        let mut doc = json!({
            "llama.cpp": {"type": "api_key", "key": "k", "env": {"LLAMA_BASE_URL": "http://h:1"}},
            "openai": {"type": "api_key", "key": "k"},
            "xai": {"type": "oauth", "access": "a"},
        });
        let p = remove_key_patch("llama.cpp", doc.get("llama.cpp")).unwrap().unwrap();
        apply(&mut doc, p);
        assert_eq!(doc["llama.cpp"], json!({"type": "api_key", "env": {"LLAMA_BASE_URL": "http://h:1"}}));
        let p = remove_key_patch("openai", doc.get("openai")).unwrap().unwrap();
        apply(&mut doc, p);
        assert!(doc.get("openai").is_none());
        assert!(remove_key_patch("xai", doc.get("xai")).is_err());
        assert_eq!(remove_key_patch("groq", None).unwrap(), None);
    }

    #[test]
    fn maps_pi_auth_check() {
        assert_eq!(status_of(Some(&json!({"status": "ready", "authType": "api_key"})), true).0, "ready");
        assert_eq!(status_of(Some(&json!({"status": "invalid", "reason": "invalid_state"})), true), ("invalid", Some("invalid_state".into())));
        assert_eq!(status_of(Some(&json!({"status": "not_ready", "reason": "credentials_not_configured"})), false).0, "not_configured");
        assert_eq!(status_of(Some(&json!({"status": "not_ready", "reason": "provider_not_found"})), true).0, "unknown");
        assert_eq!(status_of(Some(&json!({"status": "not_ready", "reason": "provider_not_found"})), false).0, "not_configured");
        assert_eq!(status_of(None, false).0, "unknown");
    }

    #[test]
    fn rows_never_carry_secrets() {
        let stored = json!({"type": "api_key", "key": "sk-very-secret", "env": {"X": "also-secret"}});
        let e = entry("openai", "builtin", Some(&stored), Some(&json!({"status": "ready", "authType": "api_key"})), &|v| v == "OPENAI_API_KEY");
        let s = e.to_string();
        assert!(!s.contains("sk-very-secret") && !s.contains("also-secret"), "{s}");
        assert_eq!(e["stored"], json!({"type": "api_key", "hasKey": true}));
        assert_eq!(e["status"], "ready");
        assert_eq!(e["authType"], "api_key");
        assert_eq!(e["envSet"], json!(["OPENAI_API_KEY"]));
        assert_eq!(e["login"], "/login openai");
        assert_eq!(e["common"], true);
        let codex = entry("openai-codex", "builtin", None, Some(&json!({"status": "not_ready", "reason": "credentials_not_configured"})), &|_| false);
        assert_eq!(codex["apiKey"], false);
        assert_eq!(codex["oauth"], true);
        assert_eq!(codex["stored"], Value::Null);
    }

    #[test]
    fn lists_builtins_then_custom_and_stored() {
        let auth = json!({"xai": {}, "my-proxy": {"type": "api_key", "key": "k"}, "bad id!": {}});
        let models = json!({"providers": {"mine": {"baseUrl": "http://h"}, "openai": {"baseUrl": "x"}}});
        let ids = provider_ids(&auth, &models);
        assert_eq!(ids.len(), KNOWN.len() + 2);
        assert!(ids.contains(&("mine".to_string(), "custom")));
        assert!(ids.contains(&("my-proxy".to_string(), "stored")));
        assert!(ids.iter().filter(|(i, _)| i == "openai").count() == 1);
        // Every common provider is a known one, and ids are plain.
        assert!(COMMON.iter().all(|c| known(c).is_some()));
        assert!(KNOWN.iter().all(|k| valid_id(k.id)));
    }

    #[test]
    fn dots_in_ids_are_escaped() {
        assert_eq!(path_seg("llama.cpp"), "llama\\.cpp");
        assert!(!valid_id("-x") && !valid_id("a/b") && valid_id("llama.cpp"));
    }
}
