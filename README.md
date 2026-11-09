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
- **Auto review** (Settings › Safety; `src/safety.rs`): @mzwing/pi-permission-auto-review, pinned at 1.0.1, has a model answer the permission policy's asks, like Claude Code's auto mode, so they reach you only when its review fails. Install, turn on or off, and pick its rules (Codex or Claude Code), model, reasoning and follow-up reviews; the page lists its recent decisions with each deny's reason, read from the review log. Turning it on also adds `path_write` denies for pi's settings, packages and policies, so the model can't approve the agent rewriting them. Recommended: Claude Code rules on `opencode-go/claude-haiku-5-5` with follow-up reviews off (they fail through OpenCode Go)
- **push-review** (`extensions/push-review.ts`): pi's own `git push` is reviewed by `opencode-go/deepseek-v4-pro` first
- Model + thinking switcher, context ring, cost, compaction, steering while pi works or queueing a message until the turn ends (long-press or right-click send; Alt+Enter), `!cmd` / `!!cmd` shell commands (output into or kept out of the context) with a live card and Stop, a retry countdown with "Stop retrying", stop, image attachments, slash commands, extension dialogs
- Fork from an earlier message of yours (it comes back into the message box to edit and resend) and clone a chat; both carry on in a new session file, listed as "Forked from …"
- Session tree (pi's `/tree`): every branch of a chat with its labels, compactions and branch summaries; go back to any point in the same session file (a prompt comes back into the message box), optionally summarizing the branch you leave; label entries. Session info: file, id, parent, counts by role, cost per model
- **Titles and outline**: a new chat is named after its first exchange, then titled again after the 3rd and 10th prompt only if its topic changed (dsh's rules; the person's messages go in as a JSON array, never cut past 4 KiB, on a cheap tool-less `pi -p`). Renaming a chat pins its title for good (`title` in `~/.local/share/pocketpi/chats/<session>.json`). **Outline** (chat sheet on the web, title menu on iOS): one line per prompt of the active branch with the reply it got; tap one to jump to it (`GET /api/sessions/outline?path=`, `src/outline.rs`, cached by mtime + size)
- **Files panel** (`src/files.rs`; "Files" in the chat sheet on the web, side panel; title menu on iOS): the chat's folder as a tree with previews (text and code with line numbers, paged 5000 lines or 2 MiB at a time; markdown; images and PDFs; anything else downloads), never following a path or symlink out of the folder. **Changed**: the files each turn changed with their diffs, from git snapshots taken as each turn starts and settles in a private index and object store (`~/.local/share/pocketpi/snapshots`, the repository's objects as an alternate, so its index and objects are never written) and kept in the chat's `chats/<session>.json`; outside git, the paths pi's edit and write tools named. A "Changed N files" line closes each turn. Type `@` in the composer to pick a path (ranked like dsh, `target`/`node_modules`/… left out); only `@path` goes in and pi is told to read it before saying anything about it (`GET /api/files/{list,read,raw,search,changes}`)
- **Terminal** (web only; `src/term.rs`, `web/term.js`): "Terminal" in the chat sheet opens your `$SHELL` (a login shell, `/bin/sh` if unset) in the chat's folder, in the side panel, with tabs for up to 8 terminals. Terminals keep running when the panel closes or the page reloads: the open ones are remembered in the browser and reattach with the last 256 KiB of output; one with nothing attached for 2 h is closed. Typing while disconnected is dropped, never sent later. Closing a tab hangs up the shell's whole process group. It runs over `GET /api/term/ws?root=&id=` (a WebSocket), whose `root` must be a live chat's or a project's folder. xterm.js 5.5.0 and its fit addon (MIT) are vendored in `web/vendor/xterm/` and loaded on first open
- Export a chat as pi's HTML page (open or download; Quick Look and share on iOS) or download its session JSONL; compact with an optional "Focus the summary on…" (`src/exports.rs`, `web/chat-more.js`)
- **Long output** (`truncBlock` / `diffBlock` in `web/app.js`): tool output and diffs are a viewport over text already in memory — a hidden-size note, paged in bounded chunks (200k chars inline, then Save .txt), Copy and Save .txt; shell output starts at the tail so errors stay in view
- **Long chats** (`web/app.js`): the transcript opens at the last 8 turns (16 with a mouse) and pages older turns in on scroll, or from the button at the top, keeping scroll position and fold state — a 500-turn chat is never one DOM tree on the phone
- **Search** (`src/search.rs`): full-text search across every chat's messages (a derived SQLite FTS5 index, grouped by chat, filter by You / Pi / Tools / Summaries) beside the instant title filter in the drawer; `GET /api/sessions/search?q=&role=&limit=&offset=&hits=`
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
| `GET /api/pi/config/{file}` | `file` = `settings`, `auth`, `models`, `mcp`, `trust`, `permissions` (@gotgenes/pi-permission-system's policy), `stage-policy` (pocketpi's `~/.config/pocketpi/safety/stage-policy.json`), `auto-review` (@mzwing/pi-permission-auto-review's `extensions/pi-permission-auto-review/config.json`); `?cwd=<project>` for the project's `.pi/settings.json` / `.pi/mcp.json` / `.pi/extensions/pi-permission-system/config.json` | `{file, scope, path, exists, data, epoch}`; the two policies also `rules: {surface: [[pattern, action], ...]}` in file order |
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
| `GET /api/safety` | | the pinned permission package, the proposed policies (`extensions/safety/`), where the stage policy is and whether it's active; `auto_review: {package, link, recommended}` |
| `POST /api/safety/recommended` | `{"file": "permissions"\|"stage-policy"}` | writes the proposed policy's keys over that file (others stay), same shape as a config read |
| `POST /api/safety/auto-review` | `{"enabled": bool}` | puts `auto-review` in the chat policy's `authorizerChain` or takes it out (other links stay); on also writes the recommended auto-review config if there is none and adds the self-protecting `path_write` denies; `{permissions, config}` |
| `GET /api/safety/reviews?limit=30` | | `{reviews: [{id, at, outcome: allow\|deny\|defer, surface, command?, path?, reason?, then?: approved\|denied, durationMs, model, stage?, errorCategory?}], log}`, newest first, from the review log's last 2 MiB |
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
## Search (`src/search.rs`)

The drawer's search box filters chat titles locally as you type and, from two
characters on, asks the server for matches *inside* messages. The server keeps
a **derived** SQLite FTS5 index (`$XDG_DATA_HOME/pocketpi/search.sqlite`,
WAL) beside pi's session files and never writes to a session: delete the
database and it rebuilds on the next start. Files are reconciled by (mtime,
size), so a search parses only the sessions that changed since the last one
(the first one warms in the background at startup). What is indexed, per
`message` entry: `user`, `assistant` and `toolResult` text blocks (a tool
result keeps its tool name; thinking, tool-call arguments and images are left
out), plus `compactionSummary` / `branchSummary` summaries. The `system` prompt
is skipped, and each entry is capped at 40k characters: the index finds a
message, it doesn't serve it.

| Route | Query | Answer |
|---|---|---|
| `GET /api/sessions/search` | `q=` (required), `role=user,assistant,tool,summary`, `limit` (chats, ≤50), `offset` (chats), `hits` (per chat, ≤20), `archived=1` | `{q, total, took_ms, indexed: {files, entries, reindexed, removed}, results: [{path, id, title, name, cwd, modified, messages, chat, live, streaming, count, hits: [{entry, role, tool, ts, snippet}]}]}` |

Queries are AND of prefix terms (`foo bar` → `"foo"* AND "bar"*`) with an OR
fallback when the AND finds nothing; ranking is FTS5's `bm25`, results are
grouped by chat and ordered by their best match. Results span every project
(each hit names its own project) even when the drawer is scoped to one chat's
project. `snippet` marks matches with U+0001 / U+0002 — never HTML — and the
client escapes then highlights them. Archived chats are left out unless
`archived=1`; they and the workflow-stage sessions never consume a page slot,
so `offset`/`limit` and `total` count what the drawer can actually show. Known
limits: tokens and phrases, not arbitrary substrings (`entry` doesn't match
`entries`; a substring would need a trigram index), CJK text is one `unicode61`
token per run so short CJK queries need the full word, forked chats carry copies
of the pre-fork entries (both can match the same old message), and only the best
2000 matching messages are grouped per request — a very common word can stop
after roughly 600 chats at the default `hits=3`.

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

## Benchmark

`scripts/bench.sh` (run once per wave) builds release, starts a throwaway
pocketpi on a free port (scratch HOME/XDG dirs, `ios/fake-pi.py` as pi, model
keys unset), generates synthetic history (2000 pi session files across 20
projects, a few with 2000+ entries, and a 20k-file git repo), then measures:
cold and loaded latency (rps, p50/p90/p99, errors) of `/api/sessions`,
`/api/projects`, `/api/sessions/outline`, `/api/usage` and
`/api/files/{list,read,search}`; 50 SSE clients on one streaming chat; the
per-turn git snapshot (`agent_settled` to `pocketpi_turn_files`); memory per
terminal; and a soak that reports whether RSS or fds keep growing. RSS
(VmRSS/VmHWM), threads and fds come from `/proc`.

```sh
scripts/bench.sh            # ~3 min
scripts/bench.sh --quick    # under a minute, smaller data
scripts/bench.sh --sessions 5000 --soak 300 --duration 10 --concurrency 32
scripts/bench.sh --bin /path/to/pocketpi --out /tmp/ab   # A/B another build
```

The load generator is `oha` or `hey` when installed, else a built-in Python
one (stated in the output). Results go to `bench-results/<date>-<sha>.json`
(git-ignored) with a table and a delta against the latest run with the same
settings; p99 or RSS more than 20% worse is flagged. A busy machine makes the
numbers noisy (the load average is recorded): re-run before trusting a flag.

## Access model

Loopback only. Remote access is meant to go through `tailscale serve` (tailnet only, never Funnel):
requests must come from loopback and carry `Tailscale-User-Login` (or a localhost Host header),
Funnel requests are refused, and every POST needs `X-Pocketpi: 1` so other sites can't drive it.
The terminal's WebSocket upgrade is a GET, so instead its `Origin` must match `Host`.
Anyone allowed in can run pi, which has shell access as your user. Treat it like SSH.

## Icons

`scripts/icons.sh` renders `web/icon.svg` to the PNG icons (needs `rsvg-convert`).
