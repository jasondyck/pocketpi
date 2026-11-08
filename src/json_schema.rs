//! A small JSON Schema checker for the raw settings editor (Settings › pi
//! settings › Edit settings.json; docs/pi-parity-plan.md E3).
//!
//! It covers the keywords pi's generated `schemas/settings.schema.json`
//! uses, nothing more: `type` (one or a list), `properties`,
//! `additionalProperties`, `patternProperties` (only the match-everything
//! `^.*$` / `.*`; other patterns aren't checked), `required`, `items`,
//! `minItems` / `maxItems`, `const`, `enum`, `anyOf` / `oneOf` / `allOf`,
//! `minimum` / `maximum` / `exclusiveMinimum` / `exclusiveMaximum`,
//! `minLength` / `maxLength`, and local `$ref`s (`#/$defs/X`,
//! `#/definitions/X`). Unknown keywords are ignored, so a newer schema
//! only checks less, never refuses a valid file.
//!
//! The schema is pi's own, read from the installed package next to the pi
//! binary when it can be found, else the copy pocketpi was built with
//! (`src/pi-settings.schema.json`, pi 1.5.0).

use serde_json::Value;
use std::path::{Path, PathBuf};

/// pi's settings schema as of the pi pocketpi was built against.
pub const BUNDLED_SETTINGS_SCHEMA: &str = include_str!("pi-settings.schema.json");

/// One thing wrong with a document: where (`retry.maxRetries`,
/// `enabledModels[2]`, `` for the top) and what.
#[derive(Debug, Clone, PartialEq)]
pub struct Problem {
    pub path: String,
    pub message: String,
}

impl std::fmt::Display for Problem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.path.is_empty() { f.write_str(&self.message) } else { write!(f, "{}: {}", self.path, self.message) }
    }
}

/// Checks `doc` against `schema`; empty when it fits.
pub fn validate(schema: &Value, doc: &Value) -> Vec<Problem> {
    let mut out = Vec::new();
    check(schema, schema, doc, "", &mut out);
    out
}

/// pi's settings schema: the installed package's (found from the pi
/// binary), else the bundled copy. Also says which one.
pub fn settings_schema(pi_bin: &str) -> (Value, String) {
    if let Some(p) = package_schema(pi_bin, "settings.schema.json")
        && let Some(v) = std::fs::read_to_string(&p).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok())
        && v.is_object()
    {
        return (v, p.to_string_lossy().into_owned());
    }
    (serde_json::from_str(BUNDLED_SETTINGS_SCHEMA).expect("bundled schema"), "bundled".into())
}

/// `<package>/schemas/<name>` for the pi binary: on PATH when it's a bare
/// name, symlinks followed (`~/.local/bin/pi` -> `…/dist/bundle/cli.js`),
/// then up the folders to one with a `schemas/<name>`.
fn package_schema(pi_bin: &str, name: &str) -> Option<PathBuf> {
    let bin = if pi_bin.contains('/') {
        PathBuf::from(pi_bin)
    } else {
        std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(pi_bin)).find(|p| p.is_file())?
    };
    let real = std::fs::canonicalize(bin).ok()?;
    let mut cur: Option<&Path> = real.parent();
    for _ in 0..6 {
        let d = cur?;
        let p = d.join("schemas").join(name);
        if p.is_file() && d.join("package.json").is_file() {
            return Some(p);
        }
        cur = d.parent();
    }
    None
}

fn resolve<'a>(root: &'a Value, r: &str) -> Option<&'a Value> {
    let ptr = r.strip_prefix('#')?;
    root.pointer(ptr)
}

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(n) if n.is_i64() || n.is_u64() || n.as_f64().is_some_and(|f| f.fract() == 0.0) => "integer",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn is_type(v: &Value, t: &str) -> bool {
    let actual = type_name(v);
    actual == t || (t == "number" && actual == "integer")
}

fn child(path: &str, key: &str) -> String {
    if path.is_empty() { key.to_string() } else { format!("{path}.{key}") }
}

fn short(v: &Value) -> String {
    let s = v.to_string();
    if s.chars().count() > 40 { format!("{}…", s.chars().take(40).collect::<String>()) } else { s }
}

fn check(root: &Value, schema: &Value, v: &Value, path: &str, out: &mut Vec<Problem>) {
    let Some(s) = schema.as_object() else {
        // `false` refuses everything; `true` (or anything else) allows it.
        if schema == &Value::Bool(false) {
            out.push(Problem { path: path.into(), message: "is not allowed".into() });
        }
        return;
    };
    macro_rules! bad {
        ($m:expr) => {
            out.push(Problem { path: path.into(), message: $m })
        };
    }

    if let Some(r) = s.get("$ref").and_then(Value::as_str) {
        match resolve(root, r) {
            Some(target) => check(root, target, v, path, out),
            None => return,
        }
        return;
    }

    if let Some(t) = s.get("type") {
        let ok = match t {
            Value::String(t) => is_type(v, t),
            Value::Array(ts) => ts.iter().filter_map(Value::as_str).any(|t| is_type(v, t)),
            _ => true,
        };
        if !ok {
            let want = match t {
                Value::Array(ts) => ts.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" or "),
                t => t.as_str().unwrap_or("?").to_string(),
            };
            bad!(format!("should be {} {want}, not {}", if want.starts_with(['a', 'i', 'o']) { "an" } else { "a" }, type_name(v)));
            return;
        }
    }

    if let Some(c) = s.get("const")
        && c != v
    {
        bad!(format!("should be {}", short(c)));
        return;
    }
    if let Some(e) = s.get("enum").and_then(Value::as_array)
        && !e.contains(v)
    {
        bad!(format!("should be one of {}", e.iter().map(short).collect::<Vec<_>>().join(", ")));
        return;
    }

    for (key, any) in [("anyOf", true), ("oneOf", false)] {
        let Some(list) = s.get(key).and_then(Value::as_array) else { continue };
        let fits = list
            .iter()
            .filter(|alt| {
                let mut tmp = Vec::new();
                check(root, alt, v, path, &mut tmp);
                tmp.is_empty()
            })
            .count();
        if fits == 0 || (!any && fits > 1) {
            // Alternatives that are all constants read best as a list.
            let consts: Option<Vec<String>> = list
                .iter()
                .map(|alt| {
                    let alt = alt.get("$ref").and_then(Value::as_str).and_then(|r| resolve(root, r)).unwrap_or(alt);
                    alt.get("const").map(short)
                })
                .collect();
            match consts {
                Some(c) if fits == 0 => bad!(format!("should be one of {}", c.join(", "))),
                _ if fits == 0 => {
                    // Show what the closest alternative (fewest problems) wants.
                    let best = list
                        .iter()
                        .map(|alt| {
                            let mut tmp = Vec::new();
                            check(root, alt, v, path, &mut tmp);
                            tmp
                        })
                        .min_by_key(Vec::len)
                        .unwrap_or_default();
                    if best.is_empty() {
                        bad!("doesn't match any allowed form".into());
                    } else {
                        out.extend(best);
                    }
                }
                _ => bad!("matches more than one allowed form".into()),
            }
            return;
        }
    }
    if let Some(list) = s.get("allOf").and_then(Value::as_array) {
        for alt in list {
            check(root, alt, v, path, out);
        }
    }

    match v {
        Value::Number(n) => {
            let f = n.as_f64().unwrap_or(0.0);
            let num = |k: &str| s.get(k).and_then(Value::as_f64);
            if let Some(m) = num("minimum")
                && f < m
            {
                bad!(format!("should be at least {}", fmt_num(m)));
            }
            if let Some(m) = num("maximum")
                && f > m
            {
                bad!(format!("should be at most {}", fmt_num(m)));
            }
            if let Some(m) = num("exclusiveMinimum")
                && f <= m
            {
                bad!(format!("should be more than {}", fmt_num(m)));
            }
            if let Some(m) = num("exclusiveMaximum")
                && f >= m
            {
                bad!(format!("should be less than {}", fmt_num(m)));
            }
        }
        Value::String(t) => {
            let n = t.chars().count() as u64;
            if let Some(m) = s.get("minLength").and_then(Value::as_u64)
                && n < m
            {
                bad!(format!("should be at least {m} characters"));
            }
            if let Some(m) = s.get("maxLength").and_then(Value::as_u64)
                && n > m
            {
                bad!(format!("should be at most {m} characters"));
            }
        }
        Value::Array(a) => {
            if let Some(m) = s.get("minItems").and_then(Value::as_u64)
                && (a.len() as u64) < m
            {
                bad!(format!("should have at least {m} item{}", if m == 1 { "" } else { "s" }));
            }
            if let Some(m) = s.get("maxItems").and_then(Value::as_u64)
                && (a.len() as u64) > m
            {
                bad!(format!("should have at most {m} items"));
            }
            if let Some(items) = s.get("items").filter(|i| i.is_object() || i.is_boolean()) {
                for (i, item) in a.iter().enumerate() {
                    check(root, items, item, &format!("{path}[{i}]"), out);
                }
            }
        }
        Value::Object(o) => {
            if let Some(req) = s.get("required").and_then(Value::as_array) {
                for k in req.iter().filter_map(Value::as_str) {
                    if !o.contains_key(k) {
                        out.push(Problem { path: path.into(), message: format!("needs {k}") });
                    }
                }
            }
            let props = s.get("properties").and_then(Value::as_object);
            let patterns = s.get("patternProperties").and_then(Value::as_object);
            for (k, val) in o {
                let p = child(path, k);
                if let Some(ps) = props.and_then(|ps| ps.get(k)) {
                    check(root, ps, val, &p, out);
                    continue;
                }
                let mut matched = false;
                if let Some(pp) = patterns {
                    for (pat, ps) in pp {
                        if pat == "^.*$" || pat == ".*" || pat == "^.*" || pat.is_empty() {
                            matched = true;
                            check(root, ps, val, &p, out);
                        } else {
                            // Other patterns aren't checked: treat as a match
                            // so a key isn't refused for want of a regex engine.
                            matched = true;
                        }
                    }
                }
                if matched {
                    continue;
                }
                match s.get("additionalProperties") {
                    Some(Value::Bool(false)) => out.push(Problem { path: p, message: "is not a known setting".into() }),
                    Some(ap @ Value::Object(_)) => check(root, ap, val, &p, out),
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

fn fmt_num(f: f64) -> String {
    if f.fract() == 0.0 { format!("{}", f as i64) } else { format!("{f}") }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pi() -> Value {
        serde_json::from_str(BUNDLED_SETTINGS_SCHEMA).unwrap()
    }

    fn msgs(doc: Value) -> Vec<String> {
        validate(&pi(), &doc).iter().map(ToString::to_string).collect()
    }

    #[test]
    fn valid_settings_pass() {
        let doc = json!({
            "defaultProvider": "anthropic", "defaultModel": "claude", "defaultThinkingLevel": "high",
            "enabledModels": ["a/*", "b:high"], "compaction": {"enabled": false, "reserveTokens": 100},
            "retry": {"maxRetries": 3}, "modelThinkingLevels": {"x/y": "low"},
            "defaultTools": ["+codemode", "-bash"], "codemode": {"mode": "only", "inlineBudget": 0},
            "somethingNew": {"pi": "adds keys"}
        });
        assert_eq!(msgs(doc), Vec::<String>::new());
    }

    #[test]
    fn wrong_types_consts_and_ranges_are_named() {
        let m = msgs(json!({
            "defaultTools": "read",
            "codemode": {"mode": "sometimes", "inlineBudget": -1},
            "compaction": {"enabled": "yes"},
            "enabledModels": ["ok", 3],
            "modelThinkingLevels": {"x/y": "hot"}
        }));
        assert!(m.contains(&"defaultTools: should be an array, not string".to_string()), "{m:?}");
        assert!(m.contains(&r#"codemode.mode: should be one of "on", "only""#.to_string()), "{m:?}");
        assert!(m.contains(&"codemode.inlineBudget: should be at least 0".to_string()), "{m:?}");
        assert!(m.contains(&"compaction.enabled: should be a boolean, not string".to_string()), "{m:?}");
        assert!(m.contains(&"enabledModels[1]: should be a string, not integer".to_string()), "{m:?}");
        assert!(m.iter().any(|s| s.starts_with("modelThinkingLevels.x/y: should be one of")), "{m:?}");
    }

    #[test]
    fn keywords_on_their_own() {
        let s = json!({"type": "object", "additionalProperties": false, "required": ["a"],
            "properties": {"a": {"type": "integer", "maximum": 3}, "b": {"oneOf": [{"type": "string"}, {"type": "number"}]}}});
        assert!(validate(&s, &json!({"a": 2, "b": "x"})).is_empty());
        let m: Vec<String> = validate(&s, &json!({"a": 2.5, "c": 1})).iter().map(ToString::to_string).collect();
        assert_eq!(m, ["a: should be an integer, not number", "c: is not a known setting"]);
        let m: Vec<String> = validate(&s, &json!({"b": true})).iter().map(ToString::to_string).collect();
        assert!(m.contains(&"needs a".to_string()), "{m:?}");
        assert!(m.iter().any(|x| x.starts_with("b: ")), "{m:?}");
        assert_eq!(validate(&s, &json!({"a": 9}))[0].message, "should be at most 3");
    }

    #[test]
    fn finds_the_package_schema_next_to_the_binary() {
        let d = std::env::temp_dir().join(format!("pocketpi-schema-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("pkg/dist/bundle")).unwrap();
        std::fs::create_dir_all(d.join("pkg/schemas")).unwrap();
        std::fs::create_dir_all(d.join("bin")).unwrap();
        std::fs::write(d.join("pkg/package.json"), "{}").unwrap();
        std::fs::write(d.join("pkg/schemas/settings.schema.json"), r#"{"type":"object","properties":{"x":{"type":"string"}}}"#).unwrap();
        std::fs::write(d.join("pkg/dist/bundle/cli.js"), "").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(d.join("pkg/dist/bundle/cli.js"), d.join("bin/pi")).unwrap();
        let (s, from) = settings_schema(d.join("bin/pi").to_str().unwrap());
        assert!(from.ends_with("pkg/schemas/settings.schema.json"), "{from}");
        assert_eq!(validate(&s, &json!({"x": 1})).len(), 1);
        // No package: the bundled copy.
        let (_, from) = settings_schema(d.join("nope/pi").to_str().unwrap());
        assert_eq!(from, "bundled");
        std::fs::remove_dir_all(d).unwrap();
    }
}
