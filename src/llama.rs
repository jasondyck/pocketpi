//! The llama.cpp router pi is logged in to (`/login llama.cpp`), so the app
//! can show local models and load one from the phone. pi lists a router model
//! only once it is loaded when the router runs with `--no-models-autoload`;
//! loading is otherwise only possible from pi's interactive `/llama`.
//!
//! The router URL comes from pi's stored credential (`auth.json`
//! `"llama.cpp".env.LLAMA_BASE_URL`), else `LLAMA_BASE_URL`. Requests only go
//! to that URL. Loading unloads the router's other models first: they share
//! one GPU.

use crate::{err, AppResult, AppState};
use axum::{extract::State, http::StatusCode, Json};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

struct Router {
    url: String,
    key: Option<String>,
}

fn router(app: &AppState) -> Option<Router> {
    let cred = std::fs::read_to_string(app.agent_dir.join("auth.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.get("llama.cpp").cloned());
    let url = cred
        .as_ref()
        .and_then(|c| c.pointer("/env/LLAMA_BASE_URL"))
        .and_then(Value::as_str)
        .map(String::from)
        .or_else(|| std::env::var("LLAMA_BASE_URL").ok())
        .map(|u| u.trim().trim_end_matches('/').trim_end_matches("/v1").to_string())
        .filter(|u| u.starts_with("http://") || u.starts_with("https://"))?;
    let key = cred
        .as_ref()
        .and_then(|c| c.get("key"))
        .and_then(Value::as_str)
        .map(String::from)
        .filter(|k| !k.is_empty())
        .or_else(|| std::env::var("LLAMA_API_KEY").ok().filter(|k| !k.is_empty()));
    Some(Router { url, key })
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().timeout(Duration::from_secs(20)).build().expect("http client")
}

impl Router {
    fn req(&self, c: &reqwest::Client, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        let r = c.request(method, format!("{}{path}", self.url));
        match &self.key {
            Some(k) => r.bearer_auth(k),
            None => r,
        }
    }

    /// The router's models as `{id, status}`, status as llama.cpp reports
    /// it: loaded, loading, unloaded, sleeping, failed...
    async fn models(&self, c: &reqwest::Client) -> Result<Vec<Value>, String> {
        let v: Value = self
            .req(c, reqwest::Method::GET, "/models")
            .send()
            .await
            .map_err(|e| format!("llama.cpp router not reachable: {e}"))?
            .error_for_status()
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())
            .and_then(|t| serde_json::from_str(&t).map_err(|e| format!("llama.cpp router: {e}")))?;
        Ok(v["data"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|m| {
                        let id = m["id"].as_str()?;
                        // Decision models answer typed questions; they can't chat.
                        let decisions = m.pointer("/architecture/output_modalities").and_then(Value::as_array).is_some_and(|o| o.iter().any(|x| x == "decisions"));
                        (!decisions).then(|| json!({
                            "id": id,
                            "status": m.pointer("/status/value").and_then(Value::as_str).unwrap_or("unknown"),
                            "failed": m.pointer("/status/failed").and_then(Value::as_bool).unwrap_or(false),
                        }))
                    })
                    .collect()
            })
            .unwrap_or_default())
    }

    async fn post(&self, c: &reqwest::Client, path: &str, model: &str) -> Result<(), String> {
        self.req(c, reqwest::Method::POST, path)
            .header("content-type", "application/json")
            .body(json!({"model": model}).to_string())
            .send()
            .await
            .map_err(|e| e.to_string())?
            .error_for_status()
            .map_err(|e| format!("{path}: {e}"))?;
        Ok(())
    }
}

/// `GET /api/llama`: whether pi has a router, and its models with their state.
pub async fn list(State(app): State<Arc<AppState>>) -> Json<Value> {
    let Some(r) = router(&app) else {
        return Json(json!({"available": false}));
    };
    match r.models(&client()).await {
        Ok(models) => Json(json!({"available": true, "models": models})),
        Err(e) => Json(json!({"available": true, "error": e, "models": []})),
    }
}

#[derive(Deserialize)]
pub struct LoadReq {
    model: String,
}

fn is_active(status: &str) -> bool {
    matches!(status, "loaded" | "loading" | "sleeping")
}

/// `POST /api/llama/load`: unload the router's other models, load this one,
/// and answer once it's loaded (up to 5 minutes for a big model).
pub async fn load(State(app): State<Arc<AppState>>, Json(req): Json<LoadReq>) -> AppResult<Json<Value>> {
    let r = router(&app).ok_or_else(|| err(StatusCode::SERVICE_UNAVAILABLE, "pi has no llama.cpp router (/login llama.cpp in pi)"))?;
    let c = client();
    let bad = |e: String| err(StatusCode::BAD_GATEWAY, e);
    let models = r.models(&c).await.map_err(bad)?;
    let status = |ms: &[Value], id: &str| ms.iter().find(|m| m["id"] == id).and_then(|m| m["status"].as_str()).map(String::from);
    if status(&models, &req.model).is_none() {
        return Err(err(StatusCode::NOT_FOUND, format!("the router has no model {}", req.model)));
    }
    for m in &models {
        let id = m["id"].as_str().unwrap_or_default();
        if id != req.model && is_active(m["status"].as_str().unwrap_or("")) {
            r.post(&c, "/models/unload", id).await.map_err(bad)?;
        }
    }
    if status(&models, &req.model).as_deref() != Some("loaded") {
        r.post(&c, "/models/load", &req.model).await.map_err(bad)?;
    }
    let end = tokio::time::Instant::now() + Duration::from_secs(300);
    let mut seen_loading = false;
    loop {
        let ms = r.models(&c).await.map_err(bad)?;
        let failed = ms.iter().find(|m| m["id"] == req.model.as_str()).is_some_and(|m| m["failed"] == true);
        match status(&ms, &req.model).as_deref() {
            Some("loaded") | Some("sleeping") => return Ok(Json(json!({"loaded": req.model, "models": ms}))),
            Some("loading") => seen_loading = true,
            // Back to unloaded after loading: it failed (out of memory, a bad file).
            Some("unloaded") if seen_loading || failed => {
                return Err(bad(format!("{} failed to load on the router (out of GPU memory?)", req.model)));
            }
            Some("unloaded") => {}
            other => return Err(bad(format!("{} didn't load ({})", req.model, other.unwrap_or("gone")))),
        }
        if tokio::time::Instant::now() > end {
            return Err(err(StatusCode::GATEWAY_TIMEOUT, format!("{} is still loading after 5 minutes", req.model)));
        }
        tokio::time::sleep(Duration::from_millis(800)).await;
    }
}
