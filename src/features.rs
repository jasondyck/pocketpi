//! Defaults for the per-chat features (docs/dsh-features-plan.md), in
//! `~/.config/pocketpi/features.json`: one top-level object per feature,
//! e.g. `{"goal": {"maxRounds": 30, "maxCost": 5}, "modes": {"defaultPreset": "auto"}}`.
//!
//! The feature extensions read this file themselves when they need a default
//! (same path: `$XDG_CONFIG_HOME` or `~/.config`, then `pocketpi/features.json`),
//! so a change applies to the next goal or chat without a restart. Clients
//! read and change it through `GET /api/features` and
//! `POST /api/features {key, value}` (a null value removes the key).

use axum::{extract::State, http::StatusCode, Json};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::{err, AppResult, AppState};

/// The features that keep defaults here.
const KEYS: &[&str] = &["goal", "modes"];

pub fn path(home: &Path) -> PathBuf {
    std::env::var("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|_| home.join(".config")).join("pocketpi/features.json")
}

fn load(path: &Path) -> Map<String, Value> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| match v {
            Value::Object(m) => Some(m),
            _ => None,
        })
        .unwrap_or_default()
}

/// Sets (or with Null removes) one feature's defaults; returns the whole file.
fn set(path: &Path, key: &str, value: Value) -> Result<Map<String, Value>, String> {
    if !KEYS.contains(&key) {
        return Err(format!("unknown feature: {key}"));
    }
    if !(value.is_object() || value.is_null()) {
        return Err("value must be an object or null".into());
    }
    let mut all = load(path);
    if value.is_null() {
        all.remove(key);
    } else {
        all.insert(key.to_string(), value);
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(&Value::Object(all.clone())).unwrap()).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())?;
    Ok(all)
}

pub async fn get_features(State(app): State<Arc<AppState>>) -> Json<Value> {
    Json(Value::Object(load(&path(&app.home))))
}

#[derive(Deserialize)]
pub struct SetReq {
    key: String,
    #[serde(default)]
    value: Value,
}

pub async fn set_features(State(app): State<Arc<AppState>>, Json(req): Json<SetReq>) -> AppResult<Json<Value>> {
    let _g = app.features_lock.lock().await;
    set(&path(&app.home), &req.key, req.value).map(|m| Json(json!(m))).map_err(|e| err(StatusCode::BAD_REQUEST, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_and_remove_keys() {
        let d = std::env::temp_dir().join(format!("pp-features-{}", std::process::id()));
        let p = d.join("pocketpi/features.json");
        assert!(load(&p).is_empty());
        set(&p, "goal", json!({"maxRounds": 10})).unwrap();
        let all = set(&p, "modes", json!({"defaultPreset": "ask"})).unwrap();
        assert_eq!(all["goal"]["maxRounds"], 10);
        assert_eq!(load(&p)["modes"]["defaultPreset"], "ask");
        set(&p, "goal", Value::Null).unwrap();
        assert!(!load(&p).contains_key("goal"));
        assert!(set(&p, "other", json!({})).is_err());
        assert!(set(&p, "goal", json!(3)).is_err());
        let _ = std::fs::remove_dir_all(d);
    }
}
