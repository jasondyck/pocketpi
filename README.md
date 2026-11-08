# pocketpi

A small, phone-first web UI for the [pi coding agent](https://github.com/earendil-works/pi).

- Rust (axum) server, one `pi --mode rpc` child process per open chat
- Streams pi's events to the browser over SSE; the page sends pi RPC commands back
- Chats are pi's own session files, so terminal and web chats are the same list
- **Projects**: chats grouped by project folder (auto-discovered from session folders, pin/rename/hide in `~/.config/pocketpi/projects.json`)
- **Workflows**: DAGs of agent / shell / review / approval stages, a git worktree + branch per run, loop-backs on failure, cost caps. Sensors: manual, chat, cron schedule, git commits/PRs/issues (polled), per-workflow webhook URLs. Created by asking pi in any chat (`extensions/pocketpi-workflows.ts`). Definitions in `~/.config/pocketpi/workflows/`, runs in `~/.local/share/pocketpi/`
- **Web push** (VAPID, pure Rust): approvals, finished/failed runs, long chat replies finished while the phone is locked. iOS needs the app on the Home Screen
- **push-review** (`extensions/push-review.ts`): pi's own `git push` is reviewed by `opencode-go/deepseek-v4-pro` first
- Model + thinking switcher, context ring, cost, compaction, steering while pi works or queueing a message until the turn ends (long-press or right-click send; Alt+Enter), `!cmd` / `!!cmd` shell commands (output into or kept out of the context) with a live card and Stop, a retry countdown with "Stop retrying", stop, image attachments, slash commands, extension dialogs
- Fork from an earlier message of yours (it comes back into the message box to edit and resend) and clone a chat; both carry on in a new session file, listed as "Forked from …"
- Vanilla JS/CSS embedded in the binary; Geist fonts (OFL, see `web/GEIST-OFL.txt`)
- **Chat tab** (iOS): plain conversations in `~/.local/share/pocketpi/chat`, where pi runs with `--no-tools` and a chat system prompt; these chats stay out of the projects and the Work list (`/api/sessions?chat=1` lists them)
- **llama.cpp router** (`src/llama.rs`): `/api/llama` lists the router pi is logged in to (`/login llama.cpp`) and `/api/llama/load` loads a model on it (unloading the others), so the app can pick local models
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
| `GET /api/pi/config/{file}` | `file` = `settings`, `auth`, `models`, `mcp`, `trust`; `?cwd=<project>` for the project's `.pi/settings.json` / `.pi/mcp.json` | `{file, scope, path, exists, data, epoch}` |
| `POST /api/pi/config/{file}` | `{"set": {"a.b": value}, "unset": ["c"]}` (dotted paths, `\.` for a literal dot), same `?cwd=` | the file as it is now, same shape |
| `GET /api/pi/status` | | `{config_epoch, control, live: [{key, file, cwd, kind, streaming, epoch, stale}]}` |
| `POST /api/pi/reload` | `{"all": false}` | restarts idle chats behind the epoch (or all idle with `all`): `{restarted, busy, failed, config_epoch}` |
| `POST /api/s/{key}/restart` | | same key, new pi on the same session file: `{key, file, epoch}`; clients get `pocketpi_exit` with `restarting: true` and reconnect |
| `POST /api/s/{key}/control` | `{"command": "tools", "args": {...}}` | `{success, data}` / `{success: false, error}` |
| `POST /api/pi/jobs` | `{"action": "install"\|"remove"\|"list"\|"update"\|"mcp_list"\|"mcp_add"\|"mcp_remove"\|"auth_check"\|"version", ...}` | `{id}`; 409 while another job runs |
| `GET /api/pi/jobs`, `GET /api/pi/jobs/{id}` | | `{jobs}` / `{job: {id, action, argv, status, code, output, started, ended}}`; output also streams on `/api/runs/events` as `{"type":"job","id","event":"start"\|"output"\|"end",...}` |
| `GET /api/pi/version`, `GET /api/pi/auth/{provider}`, `GET /api/pi/mcp[?cwd=]`, `GET /api/pi/packages[?cwd=]` | | quick CLI calls: `{code, stdout, stderr, json}` |
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
