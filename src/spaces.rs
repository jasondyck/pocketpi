//! Spaces: project folders that group chats, like herdr's spaces.
//!
//! A space is a working directory. Every folder that has pi sessions shows up
//! automatically; pinning gives it a custom name and a fixed position, and
//! hiding removes an auto-discovered one from the rail.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::sessions::SessionInfo;

#[derive(Serialize, Deserialize, Default, Clone)]
pub struct Config {
    #[serde(default)]
    pub pinned: Vec<Pinned>,
    #[serde(default)]
    pub hidden: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Pinned {
    pub path: String,
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Serialize)]
pub struct Space {
    pub path: String,
    pub name: String,
    pub pinned: bool,
    pub chats: u32,
    pub live: u32,
    pub streaming: bool,
    pub modified: u64,
    pub exists: bool,
}

pub fn config_path(home: &Path) -> PathBuf {
    std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home.join(".config"))
        .join("pocketpi/spaces.json")
}

pub fn load(path: &Path) -> Config {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save(path: &Path, cfg: &Config) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(cfg)?)?;
    std::fs::rename(tmp, path)
}

fn basename(p: &str) -> String {
    p.trim_end_matches('/').rsplit('/').next().filter(|s| !s.is_empty()).unwrap_or("/").to_string()
}

pub fn build(cfg: &Config, sessions: &[SessionInfo], home: &str) -> Vec<Space> {
    let mut out: Vec<Space> = cfg
        .pinned
        .iter()
        .map(|p| Space {
            path: p.path.clone(),
            name: p.name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| basename(&p.path)),
            pinned: true,
            chats: 0,
            live: 0,
            streaming: false,
            modified: 0,
            exists: Path::new(&p.path).is_dir(),
        })
        .collect();
    // Sessions arrive newest first, so auto spaces are ordered by recent use.
    for s in sessions {
        if cfg.hidden.iter().any(|h| h == &s.cwd) && !cfg.pinned.iter().any(|p| p.path == s.cwd) {
            continue;
        }
        let idx = match out.iter().position(|sp| sp.path == s.cwd) {
            Some(i) => i,
            None => {
                out.push(Space {
                    path: s.cwd.clone(),
                    name: if s.cwd == home { "Home".into() } else { basename(&s.cwd) },
                    pinned: false,
                    chats: 0,
                    live: 0,
                    streaming: false,
                    modified: 0,
                    exists: Path::new(&s.cwd).is_dir(),
                });
                out.len() - 1
            }
        };
        let sp = &mut out[idx];
        sp.chats += 1;
        sp.modified = sp.modified.max(s.modified);
        if s.live {
            sp.live += 1;
        }
        sp.streaming |= s.streaming;
    }
    out
}
