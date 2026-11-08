//! The raw settings.json editor (docs/pi-parity-plan.md E3): the file's text
//! as it is on disk, and a whole-file write that is checked first.
//!
//! | Route | Answer |
//! |---|---|
//! | `GET /api/pi/config/settings/raw[?cwd=]` | `{file, scope, path, exists, text, schema, epoch}` (`text` even when the file isn't valid JSON, so it can be fixed) |
//! | `POST /api/pi/config/settings/raw[?cwd=]` | `{"text": "…"}` → the file like `GET /api/pi/config/settings`; 422 with the problems (one per line) when it isn't a JSON object or doesn't fit pi's schema. `{"text", "check": true}` only checks: `{valid, problems: [{path, message}], schema}` |
//!
//! The schema is pi's `schemas/settings.schema.json` (src/json_schema.rs).
//! Only `settings` can be edited this way: the other files hold secrets
//! that clients never see. The text is written as typed (with the usual
//! `.pocketpi.bak` backups, `pi_admin::Admin::replace`), and bumps the
//! config epoch.

use crate::{AppState, json_schema, pi_admin};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

pub fn router() -> Router<Arc<AppState>> {
    Router::new().route("/api/pi/config/{file}/raw", get(read_raw).post(write_raw))
}

#[derive(Deserialize)]
struct CwdQuery {
    #[serde(default)]
    cwd: Option<String>,
}

fn raw_file(name: &str) -> crate::AppResult<pi_admin::File> {
    match pi_admin::File::parse(name) {
        Some(f) if f.raw_editable() => Ok(f),
        Some(_) => Err(crate::err(StatusCode::FORBIDDEN, format!("{name} can't be edited as text"))),
        None => Err(crate::err(StatusCode::NOT_FOUND, format!("unknown config file: {name}"))),
    }
}

async fn read_raw(State(app): State<Arc<AppState>>, Path(file): Path<String>, Query(q): Query<CwdQuery>) -> crate::AppResult<Json<Value>> {
    let f = raw_file(&file)?;
    let cwd = q.cwd.as_deref().filter(|c| !c.is_empty());
    let (path, text) = app.admin.read_text(f, cwd).map_err(crate::admin_err)?;
    let (_, schema) = json_schema::settings_schema(&app.pi_bin);
    Ok(Json(json!({
        "file": file, "scope": if cwd.is_some() { "project" } else { "global" }, "path": path,
        "exists": text.is_some(), "text": text.unwrap_or_default(), "schema": schema, "epoch": app.admin.epoch(),
    })))
}

#[derive(Deserialize)]
struct RawBody {
    text: String,
    #[serde(default)]
    check: bool,
}

/// What's wrong with `text` as pi's settings: not JSON, not an object, or
/// not what the schema allows. Empty when it's fine.
pub fn problems(schema: &Value, text: &str) -> Vec<json_schema::Problem> {
    let doc: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(e) => {
            return vec![json_schema::Problem {
                path: String::new(),
                message: format!("not valid JSON (line {}, column {}): {}", e.line(), e.column(), strip_position(&e.to_string())),
            }];
        }
    };
    if !doc.is_object() {
        return vec![json_schema::Problem { path: String::new(), message: "settings.json must be a JSON object ({…})".into() }];
    }
    json_schema::validate(schema, &doc)
}

/// serde_json's message without its own " at line X column Y".
fn strip_position(s: &str) -> &str {
    s.find(" at line ").map(|i| &s[..i]).unwrap_or(s)
}

async fn write_raw(
    State(app): State<Arc<AppState>>,
    Path(file): Path<String>,
    Query(q): Query<CwdQuery>,
    Json(body): Json<RawBody>,
) -> crate::AppResult<Json<Value>> {
    let f = raw_file(&file)?;
    let cwd = q.cwd.as_deref().filter(|c| !c.is_empty());
    let (schema, from) = json_schema::settings_schema(&app.pi_bin);
    let found = problems(&schema, &body.text);
    if body.check {
        let list: Vec<Value> = found.iter().map(|p| json!({"path": p.path, "message": p.message})).collect();
        return Ok(Json(json!({ "valid": found.is_empty(), "problems": list, "schema": from })));
    }
    if !found.is_empty() {
        let lines: Vec<String> = found.iter().map(|p| format!("- {p}")).collect();
        return Err(crate::err(
            StatusCode::UNPROCESSABLE_ENTITY,
            format!("settings.json wasn't saved:\n{}", lines.join("\n")),
        ));
    }
    let v = app.admin.replace(f, cwd, &body.text).map_err(crate::admin_err)?;
    crate::config_changed(&app);
    Ok(Json(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn problems_name_the_line_or_the_key() {
        let s: Value = serde_json::from_str(json_schema::BUNDLED_SETTINGS_SCHEMA).unwrap();
        assert!(problems(&s, r#"{"retry": {"maxRetries": 2}}"#).is_empty());
        let p = problems(&s, "{\n  \"a\": 1,\n}");
        assert_eq!(p.len(), 1);
        assert!(p[0].message.starts_with("not valid JSON (line 3, column 1)"), "{}", p[0].message);
        assert!(problems(&s, "[1]")[0].message.contains("JSON object"));
        let p = problems(&s, r#"{"steeringMode": "sometimes"}"#);
        assert_eq!(p[0].path, "steeringMode");
    }
}
