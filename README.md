# pocketpi

A small, phone-first web UI for the [pi coding agent](https://github.com/earendil-works/pi).

- Rust (axum) server, one `pi --mode rpc` child process per open chat
- Streams pi's events to the browser over SSE; the page sends pi RPC commands back
- Chats are pi's own session files, so terminal and web chats are the same list
- **Projects**: chats grouped by project folder (auto-discovered from session folders, pin/rename/hide in `~/.config/pocketpi/projects.json`)
- **Workflows**: DAGs of agent / shell / review / approval stages, a git worktree + branch per run, loop-backs on failure, cost caps. Agent stages run pi with `--no-mcp` (no browser or docs servers, ~300 MB less per stage) unless the stage sets `mcp: true` or lists `codemode`/`mcp__*` in `tools`. Sensors: manual, chat, cron schedule, git commits/PRs/issues (polled), per-workflow webhook URLs. Created by asking pi in any chat (`extensions/pocketpi-workflows.ts`). Definitions in `~/.config/pocketpi/workflows/`, runs in `~/.local/share/pocketpi/`
- **Subagents** (`src/subagents.rs`): live progress for pi-subagents' runs, read from the extension's own `status.json` / `output-<n>.log` files (never scraped from model output). The chat's tool card gets a live agent line, a top-bar count shows what's running, and a Subagents sheet lists each run's steps, current tool, recent output, tokens, cost and log tail; a step's child session opens as a chat while it works. The iOS app has the same sheet from the chat title menu and a running line above the composer
- **Goal mode** (`extensions/pocketpi-goal.ts`): give a chat an objective ("Start a goal…" in the chat menu, or type `/goal <objective>`) and pi keeps taking rounds until it marks the goal complete, it's blocked, or it reaches the round or cost cap (30 rounds and $5 by default, set in `~/.config/pocketpi/features.json`). The goal is stored in the session and shown in a strip above the composer, with Pause/Resume and Clear. It never resumes by itself after a restart, fork or stop. You get one push when it finishes, not one per round. `POCKETPI_GOAL=0` turns it off
- **Web push** (VAPID, pure Rust): approvals, finished/failed runs, long chat replies finished while the phone is locked. iOS needs the app on the Home Screen
- **Plan mode** (`extensions/pocketpi-modes.ts`): `/plan [message]`, the chat menu or the composer chip; pi explores read-only (edits and mutating shell commands are blocked) and ends with `exit_plan_mode`, which asks you to Approve or Keep planning (with feedback) before anything changes
- **Todos**: pi keeps a task list with `todo_write`; a dock above the composer shows "3/7 · current step" and opens to the checklist. The list is kept per branch and cleared by your next prompt
- **Permission presets** per chat: Auto (default, today's behaviour), Ask (each edit, write and mutating command asks: Allow once / Allow for this chat / Deny with a reason) and Read-only. The safety rules still apply under every preset. The default for new chats is `modes.defaultPreset` in `~/.config/pocketpi/features.json`
- **push-review** (`extensions/push-review.ts`): pi's own `git push` is reviewed by `opencode-go/deepseek-v4-pro` first
- Model + thinking switcher, context ring, cost, compaction, steering while pi works or queueing a message until the turn ends (long-press or right-click send; Alt+Enter), `!cmd` / `!!cmd` shell commands (output into or kept out of the context) with a live card and Stop, a retry countdown with "Stop retrying", stop, image attachments, slash commands, extension dialogs
- Fork from an earlier message of yours (it comes back into the message box to edit and resend) and clone a chat; both carry on in a new session file, listed as "Forked from …"
- Session tree (pi's `/tree`): every branch of a chat with its labels, compactions and branch summaries; go back to any point in the same session file (a prompt comes back into the message box), optionally summarizing the branch you leave; label entries. Session info: file, id, parent, counts by role, cost per model
- **Titles and outline**: a new chat is named after its first exchange, then titled again after the 3rd and 10th prompt only if its topic changed (dsh's rules; the person's messages go in as a JSON array, never cut past 4 KiB, on a cheap tool-less `pi -p`). Renaming a chat pins its title for good (`title` in `~/.local/share/pocketpi/chats/<session>.json`). **Outline** (chat sheet on the web, title menu on iOS): one line per prompt of the active branch with the reply it got; tap one to jump to it (`GET /api/sessions/outline?path=`, `src/outline.rs`, cached by mtime + size)
- Export a chat as pi's HTML page (open or download; Quick Look and share on iOS) or download its session JSONL; compact with an optional "Focus the summary on…" (`src/exports.rs`, `web/chat-more.js`)
- **Settings › Usage** (`src/usage.rs`): cost and tokens per day, model, provider and project over 7/30/90 days, from every session file (cached by mtime + size); subscription costs (OAuth logins, Codex, Copilot) shown as the API-rate equivalent and kept out of "spent", OpenCode Go's pool on its own
- Vanilla JS/CSS embedded in the binary; Geist fonts (OFL, see `web/GEIST-OFL.txt`)
- **Chat tab** (iOS): plain conversations in `~/.local/share/pocketpi/chat`, where pi runs without built-in tools but with `codemode` (`--no-tools --tools +codemode`) so MCP tools such as Playwright stay reachable, plus a chat system prompt; these chats stay out of the projects and the Work list (`/api/sessions?chat=1` lists them)
- **llama.cpp router** (`src/llama.rs`): `/api/llama` lists the router pi is logged in to (`/login llama.cpp`) and `/api/llama/load` loads a model on it (unloading the others), so the app can pick local models (iOS and the web's model sheet, under *Local*)
- **iOS app** (`ios/`, early): native SwiftUI client for the same API; see `ios/README.md`
- **APNs** (`src/apns.rs`): the same notifications go to the iOS app when `~/.config/pocketpi/apns/AuthKey_<KEYID>.p8` exists (team/topic: `POCKETPI_APNS_TEAM`, `POCKETPI_APNS_TOPIC`)

## Run

```sh
cargo build --release
POCKETPI_PORT=3457 ./target/release/pocketpi
```

| Env | Default | Meaning |
|---|---|---|
| `POCKETPI_PORT` | `3457` | Listens on 127.0.0.1 only |
| `POCKETPI_PI` | `pi` | pi binary |
| `POCKETPI_ALLOWED_USERS` | unset | Comma-separated Tailscale logins allowed through Tailscale Serve |
| `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR` | pi defaults | Passed through to pi; also where sessions are listed from |
| `POCKETPI_CONTROL` | on | `0` starts chats without the `pocketpi-control` extension |

## pi's configuration (`src/pi_admin.rs`, `src/pi_cli.rs`)

pi's RPC can't change settings, credentials, packages or MCP servers, so
pocketpi edits pi's files and runs its CLI. pi only rereads its config when it
starts: every change bumps a **config epoch**, each running pi remembers the
epoch it started with, and a chat behind the current one shows "Restart to
apply" (`stale` in `pocketpi_hello`, `epoch` on live rows of `/api/sessions`
next to its `config_epoch`, and `{"type":"config_changed"}` on `/api/runs/events`).

| Route | Body / query | Answer |
|---|---|---|
| `GET /api/pi/config/{file}` | `file` = `settings`, `auth`, `models`, `mcp`, `trust`, `permissions` (@gotgenes/pi-permission-system's policy), `stage-policy` (pocketpi's `~/.config/pocketpi/safety/stage-policy.json`); `?cwd=<project>` for the project's `.pi/settings.json` / `.pi/mcp.json` / `.pi/extensions/pi-permission-system/config.json` | `{file, scope, path, exists, data, epoch}`; the two policies also `rules: {surface: [[pattern, action], ...]}` in file order |
| `POST /api/pi/config/{file}` | `{"set": {"a.b": value}, "unset": ["c"]}` (dotted paths, `\.` for a literal dot), same `?cwd=` | the file as it is now, same shape |
| `GET /api/pi/status` | | `{config_epoch, control, live: [{key, file, cwd, kind, streaming, epoch, stale}]}` |
| `POST /api/pi/reload` | `{"all": false}` | restarts idle chats behind the epoch (or all idle with `all`): `{restarted, busy, failed, config_epoch}` |
| `POST /api/s/{key}/restart` | | same key, new pi on the same session file: `{key, file, epoch}`; clients get `pocketpi_exit` with `restarting: true` and reconnect |
| `POST /api/s/{key}/control` | `{"command": "tools"\|"goto"\|"label", "args": {...}}`: `tools` `{active?}`; `goto` `{entryId, summarize?, instructions?}` (pi's navigateTree; answers `{cancelled, editorText, leafId}`, then every client gets `pocketpi_resync`; waits up to 10 min when summarizing); `label` `{entryId, label?}` (no label clears it) | `{success, data}` / `{success: false, error}` |
| `GET /api/s/{key}/header` | | the chat's session file and its header line: `{file, header: {type, version, id, timestamp, cwd, parentSession?}}` (`header` null until pi writes the file) |
| `POST /api/pi/jobs` | `{"action": "install"\|"remove"\|"list"\|"update"\|"mcp_list"\|"mcp_add"\|"mcp_remove"\|"mcp_logout"\|"auth_check"\|"version", ...}` | `{id}`; 409 while another job runs. `update` takes `cwd` (project packages too) and never updates pi itself through `source` |
| `GET /api/pi/jobs`, `GET /api/pi/jobs/{id}` | | `{jobs}` / `{job: {id, action, argv, status, code, output, started, ended}}`; output also streams on `/api/runs/events` as `{"type":"job","id","event":"start"\|"output"\|"end",...}` |
| `GET /api/pi/version`, `GET /api/pi/auth/{provider}`, `GET /api/pi/mcp[?cwd=]`, `GET /api/pi/packages[?cwd=]` | | quick CLI calls: `{code, stdout, stderr, json}` |
| `GET /api/pi/providers[?refresh=1]`, `POST /api/pi/providers/{id}/key` `{"key"}`, `POST /api/pi/providers/{id}/remove` | | every provider pi knows with `pi auth check`'s verdict (6 at a time, cached 30 s), its auth.json type/hasKey and env vars, plus the default and fallback models; key writes take literal keys only (no `!command`) and answer the re-checked row, never the key (`src/pi_providers.rs`) |
| `GET /api/pi/trust` | | each project's trust as pi resolves it (`src/pi_resources.rs`): `{path, default, entries, projects: [{path, canonical, decision, from, explicit, trusted, needsTrust, protected}]}`; change it with `POST /api/pi/config/trust` (key = canonical path, `.` escaped) |
| `GET /api/pi/resources[?cwd=]` | | extensions, skills and prompts pi would load, with `scope` (global/project/package/builtin/temporary), `enabled`, `loads`, `skipped`, `toggle`; packages from `pi list`; a live chat's `get_commands` marks `live` |
| `GET /api/pi/config/settings/raw[?cwd=]`, `POST` same `{"text"}` (or `{"text", "check": true}`) | | the raw settings.json editor (`src/pi_settings_raw.rs`): the file's text as on disk; a write is refused (422, the problems one per line) unless it's a JSON object that fits pi's `schemas/settings.schema.json` (`src/json_schema.rs`: the installed package's, else the bundled copy), then written as typed with backups; `check` only answers `{valid, problems: [{path, message}]}` |
| `GET /api/pi/context[?cwd=]` | | context and system prompt files (`src/pi_context.rs`): `{agentDir, cwd, maxBytes, trust, files: [{scope, name, path, exists, size, editable, kind, loaded}], loaded: {context, system, append}}`, with what pi loads in its order |
| `GET /api/pi/context/file?scope=&name=[&cwd=]`, `POST` same `{"content"}` / `{"delete": true}` | | one of a fixed list (global `~/.pi/agent/` and project `<cwd>/`: `AGENTS.md`, `AGENTS.override.md`; `<cwd>/.pi/` and global: `SYSTEM.md`, `APPEND_SYSTEM.md`; `CLAUDE.md`, `AGENTS.MD`, `CLAUDE.MD` read only); 256 KB cap, backups, bumps the epoch |
| `POST /api/pi/resources/toggle` | `{cwd?, kind, path, scope, state: "on"\|"off"\|"inherit", override?, package?: {source, scope, entry}}` | turns a resource on or off the way `pi config` does (`+`/`-` entries, a package's filter, a project override of a global resource; `src/pi_packages.rs` explains pi's precedence): `{enabled, key, scope, entries, epoch}` |
| `POST /api/pi/mcp/server` | `{name, cwd?, scope, enabled?, exposure?, override?, clear?}` | edits one server in mcp.json like pi's `/mcp` (defaults dropped, project overrides kept): the file's view |
| `POST /api/pi/mcp/signin` | `{name, action: "login"\|"logout"\|"reconnect", cwd?, key?}` | runs `/mcp <action> <name>` in a chat for the project (the given one, the open one, or a new one; restarted first when behind the config): `{key, cwd, file, done, notices, url, dialog}`; answer `dialog` with an `extension_ui_response` on `/api/s/{key}/cmd` |
| `GET /api/pi/gallery[?q=&from=]` | | npm packages with the `pi-package` keyword (cached 10 min; `POCKETPI_NPM_REGISTRY` overrides the registry): `{total, packages: [{name, version, description, publisher, date, npm, monthly, weekly, source}]}` |
| `GET /api/safety` | | the pinned permission package, the proposed policies (`extensions/safety/`), where the stage policy is and whether it's active |
| `POST /api/safety/recommended` | `{"file": "permissions"\|"stage-policy"}` | writes the proposed policy's keys over that file (others stay), same shape as a config read |
| `GET /api/manage/pages` | | the web Settings pages, `{pages: ["about", …]}`, each served at `/manage/<id>.js` (docs/pi-parity-plan.md §7) |

Writes go to a `.tmp` file renamed over the original, the previous version is
kept as `<file>.pocketpi.bak` (then `.bak.1`, `.bak.2`), and keys pocketpi
doesn't know are kept. Secrets never come back: `auth.json` reads as
`{providers: [{provider, type, hasKey}]}`, credential-looking values in
`models.json` / `mcp.json` read `"<redacted>"`, and writing that marker is
refused. CLI calls are a fixed allowlist, never go through a shell, and run
with stdin from `/dev/null`.

**pocketpi-control** (`extensions/pocketpi-control.ts`, embedded and written
to `$XDG_DATA_HOME/pocketpi/` at startup) is loaded with `-e` into normal chat
pis (not the Chat tab, not workflow stages). The server runs `/pp-<command>
<reqId> [json]` through `prompt`; the extension answers with a hidden custom
entry (`customType: "pocketpi-control"`) that pi reports as `entry_appended`,
which the server hands back to the waiting `/control` call and keeps off the
event stream. `/pp-*` commands are left out of the `get_commands` the server
relays, and clients can't send them as prompts.

The RPC allowlist also has `fork`, `clone`, `get_fork_messages`, `get_tree`,
`get_entries`, `export_html` (always written to
`$XDG_DATA_HOME/pocketpi/exports/`), `bash`, `abort_bash`,
`get_last_assistant_text` and the global setters (`set_auto_compaction`,
`set_auto_retry`, `set_steering_mode`, `set_follow_up_mode`, which bump the
epoch). After a fork or clone the server asks pi for its new session file and
broadcasts `{"type":"pocketpi_session","file":...}`. `cycle_model`,
`new_session` and `switch_session` are never allowed.

## Export and usage (`src/exports.rs`, `src/usage.rs`)

| Route | Body / query | Answer |
|---|---|---|
| `POST /api/s/{key}/export` | | pi writes the chat's HTML (`export_html`) to a path the server picks in `$XDG_DATA_HOME/pocketpi/exports/` (exports older than a day, or beyond 30, are pruned): `{name, url}` |
| `GET /api/exports/{name}` | `?download=1&title=` | the export, `text/html` with `Content-Security-Policy: sandbox` (its scripts can't call the API); only names the server made |
| `GET /api/sessions/file` | `?path=<session file>&title=` | the session JSONL as an attachment, streamed; only `.jsonl` files that resolve inside the sessions or Chat-tab folder |
| `GET /api/usage` | `?days=7\|30\|90&tz=<minutes east of UTC>` | `{totals, billing: {api, subscription, pool}, byDay, byModel, byProvider, byProject, files, ms}`; usage from assistant messages, `usage` entries and compaction / branch summaries, fork copies counted once |

## Subagents (`src/subagents.rs`)

pi-subagents (npm `pi-subagents`) keeps machine-readable run state in
`<tmpdir>/pi-subagents-<scope>/async-subagent-runs/<runId>/`: `status.json`
(what its TUI widget reads), `events.jsonl` and `output-<n>.log`. pocketpi
reads those files rather than scraping the model's tool output, so the web and
iOS views show the same steps, tools, output and usage as pi's own widget.

| Route | Answer |
|---|---|
| `GET /api/subagents[?session=<session file>][&all=1]` | `{at, total, runs}`: recent runs, live first. Without `session` (or with `all=1`), every chat's runs. A run has `runId`, `toolCallId` (pi's tool call), `mode` (single/chain/parallel/workflow), `state`, `active`, `sessionId`, `cwd`, timestamps, `tokens`, `cost` and `steps` |
| `GET /api/subagents/{runId}` | `{at, run, outputs: [{name, text}]}`: one run plus the bounded tails of its `output-<n>.log` files |

A step has `agent`, `label`, `status`, tokens, model, the child's
`sessionFile` (open it as a chat), `recentTools` (`read src/main.rs`) and
`recentOutput` (its last lines). A workflow root's steps carry their own
child's live detail, merged from the child run's `status.json`. Runs with a
parent workflow that is present are listed once, as its step. Artifacts are
capped (2 MB a file, 48 h old, 80 runs); pi-subagents deletes them itself after
a day. Set `POCKETPI_SUBAGENTS_DIR` to read a different root (the tested
fixtures use this). Project-scoped `.pi/subagents/` and nested async roots are
not read.

## Safety (`src/safety.rs`, `src/dialogs.rs`)

Settings › Safety installs [@gotgenes/pi-permission-system](https://www.npmjs.com/package/@gotgenes/pi-permission-system)
(pinned) with the proposed chat policy (`extensions/safety/chat-policy.json`),
edits its rule lists, sets each project to Off / Ask / Strict, and gives
workflow stages their own policy (`extensions/safety/stage-policy.json`,
copied to `~/.config/pocketpi/safety/stage-policy.json`). The chat policy is
pi's own file, so the terminal's pi uses it too. Stages read theirs through
an overlay agent dir, `~/.pi/agent.pocketpi-stage` (symlinks to the real one
except that file); docs/pi-parity-plan.md §6 says why. When a chat's pi asks
something (a permission prompt or any other dialog) and nobody has the chat
open, or it's still unanswered after 20 s, pocketpi sends a notification that
opens the chat with the question showing. Policy writes need no restart: the
extension rereads its file. Check the proposed files against the package's
schema with `node scripts/check-safety-policies.mjs <permissions.schema.json>`.

## Tests

`cargo test` (the server's unit tests; also the `Rust` GitHub workflow) and
`ios/test-linux.sh` (PocketPiKit against a scratch pocketpi with
`ios/fake-pi.py` as pi).

## Access model

Loopback only. Remote access is meant to go through `tailscale serve` (tailnet only, never Funnel):
requests must come from loopback and carry `Tailscale-User-Login` (or a localhost Host header),
Funnel requests are refused, and every POST needs `X-Pocketpi: 1` so other sites can't drive it.
Anyone allowed in can run pi, which has shell access as your user. Treat it like SSH.

## Icons

`scripts/icons.sh` renders `web/icon.svg` to the PNG icons (needs `rsvg-convert`).
