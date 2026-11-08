# Bringing pi's features into pocketpi: inventory and plan

This plan is based on pi v1.5.0 (`@earendil-works/pi-coding-agent`) and pocketpi master at b75e80b, as of 2026-11-08.

## 1. Constraints from pi that shape the design

- **RPC has 32 commands, and that is all of them.** RPC has no commands for:
  - moving around the session tree, or adding labels
  - listing or deleting sessions
  - logging in or out
  - reading or changing settings, or reloading
  - turning tools, extensions, packages, MCP servers or themes on or off

  Everything else has to come from one of three places:
  - (a) pocketpi reading and writing pi's files in `~/.pi/agent/*` or `<cwd>/.pi/*`
  - (b) pocketpi running the pi CLI (`pi install|list|remove|update|config`, `pi mcp …`, `pi auth check`)
  - (c) a **companion extension**, loaded into every chat pi with `-e`, that offers `/pp-*` commands. Only extensions can call `ctx.navigateTree`, `pi.setLabel`, `pi.setActiveTools`/`getAllTools`, `ctx.reload()` and `pi.getMcpServers`.
- **Built-in slash commands don't work over RPC.** If a client sends `/tree`, `/settings` or `/reload` through `prompt`, the text goes to the model. Only extension commands, prompt templates and `/skill:x` are carried out.
- **Some RPC setters change global `settings.json`:**
  - `set_steering_mode`, `set_follow_up_mode`, `set_auto_compaction` and `set_auto_retry`
  - `cycle_model`, which changes the default model

  The UI must show these as global settings, not per-chat toggles. pocketpi should never send `cycle_model`.
- **After editing files, pi has to restart (or run `ctx.reload()`).** This covers settings, `auth.json`, `models.json`, `mcp.json`, packages, skills and prompts. So pocketpi needs one "apply" mechanism: reload chat pis that are idle, and mark busy ones as stale.
- **Project trust:** RPC can't ask about trust. With `defaultProjectTrust:"ask"`, pi silently ignores a project's `.pi/` resources. pocketpi has to manage `~/.pi/agent/trust.json` itself.
- **OAuth logins (`/login`) need the TUI.** API-key providers can be set by writing `auth.json`. MCP OAuth works over RPC through `/mcp login <server>`, which shows a notify with the URL and then an input asking for the redirect URL.

## 2. Feature list: what pi has, what pocketpi has, what to build

Key: ✅ done · 🟡 partial · ❌ missing. P1 is the most valuable and the least risky; P3 is nice to have.

### A. Sessions and history

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| A1 | Fork from an earlier user message | `get_fork_messages`, `fork{entryId}` (returns the text to put back in the composer) | ❌ | P1 |
| A2 | Clone the current branch | `clone` | ❌ | P2 |
| A3 | Session tree viewer showing branches, labels and compaction points | `get_tree` / `get_entries{since}` | ❌ | P2 |
| A4 | Move to another point in the tree, with an optional branch summary | companion `/pp-goto <entryId> [--summarize]` → `ctx.navigateTree` | ❌ | P2 |
| A5 | Labels and bookmarks on entries | companion `/pp-label` → `pi.setLabel`; read them through `get_tree` | ❌ | P3 |
| A6 | Archive, unarchive, delete and rename from the list | pocketpi's `projects.json` and `remove_file` | 🟡 iOS has it, web doesn't | P1 |
| A7 | Export HTML (view it in the app, share it) | `export_html{outputPath}` saved to a tmp folder, served by pocketpi | ✅ (W3) | P2 |
| A8 | Export or download the JSONL | stream the session file | ✅ (W3) | P2 |
| A9 | Import a JSONL file | upload it into the sessions folder, then `/api/open` | ❌ | P3 |
| A10 | Share (gist) | runs on the host: `pi --export` + `gh gist create --secret` | ❌ | P3 |
| A11 | Session info: file path, id, parent session, counts by message type, cost per model | `get_session_stats` plus the header | 🟡 only tokens, cost and context % | P2 |
| A12 | Copy the last reply | `get_last_assistant_text` | 🟡 a Copy action on each message | — |
| A13 | Paged history for long chats | `get_entries{since}` cursor | ❌ | P3 |

### B. Prompting, the queue and running

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| B1 | Choose between steer and follow-up (queue after the turn) | `follow_up`, `prompt{streamingBehavior}` | 🟡 steer only | P1 |
| B2 | Run a shell command from the composer: `!cmd` goes into context, `!!cmd` stays out | `bash{command,excludeFromContext}`, `bash_execution_update`, `abort_bash` | ❌ | P1 |
| B3 | Delivery modes: all at once vs one at a time | `set_steering_mode`, `set_follow_up_mode` (global) | ❌ | P3 |
| B4 | Auto-retry: show a countdown and a "Stop retrying" button; global toggle | `auto_retry_*` events, `abort_retry`, `set_auto_retry` | 🟡 events shown, `abort_retry` never sent | P1 |
| B5 | Auto-compaction toggle and thresholds (global or per model) | `set_auto_compaction`, settings `compaction.*` | 🟡 manual compaction only | P2 |
| B6 | Compact with custom instructions | `compact{customInstructions}` | ✅ (W3) | P2 |
| B7 | Paste an image from the clipboard (web) | — | ❌ | P3 |

### C. Models and thinking

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| C1 | Set the default model and default thinking level for new chats | `settings.json` `defaultProvider`, `defaultModel`, `defaultThinkingLevel` | ❌ | P1 |
| C2 | Edit scoped/favourite models (`enabledModels`, including `:thinking` suffixes) | `settings.json` | 🟡 read-only (`/api/models/enabled`) | P1 |
| C3 | Thinking level per model | `modelThinkingLevels` | ❌ | P2 |
| C4 | Custom providers and models | `models.json`: form editor plus a raw JSON editor checked against `schemas/models.schema.json` | ❌ | P3 |
| C5 | Refresh the model catalogue | `pi update --models` | ❌ | P3 |
| C6 | Local llama.cpp models | pocketpi `/api/llama` | ✅ iOS · ✅ web (W3) | P2 (web) |
| C7 | Cache warming and the hide-thinking toggle | settings | ❌ | P3 |

### D. Providers and auth

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| D1 | Provider status: which providers are ready, missing or invalid | `pi auth check --provider X --json` for each known provider | ❌ | P1 |
| D2 | Add, replace or remove an API key | write `auth.json` (literal keys only; never send key values back to the client) | ❌ | P2 |
| D3 | OAuth login (xAI, Codex, Claude, …) | TUI only. Option: a server-side pty that runs `pi` and forwards the device-code or URL prompt | ❌ | P3 (spike) |
| D4 | Subscription fallback status (which chats fell back to which model) | `extensions/subscription-fallback.ts` writes a `custom` entry | ❌ | P3 |

### E. Settings

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| E1 | Settings screen: typed controls for the keys that matter in RPC (model, interaction, compaction, retry, images, tools, codemode, shell, network); TUI-only keys hidden | `~/.pi/agent/settings.json`, keep a `.bak` | ❌ | P1 |
| E2 | Project settings (`<cwd>/.pi/settings.json`) with a global vs project switch | file | ❌ | P2 |
| E3 | Raw JSON editor with schema checking (`schemas/settings.schema.json`) | file | ❌ | P2 |
| E4 | Apply changes: restart idle chat pis and mark busy ones "restart to apply" | pocketpi `/api/pi/reload` + `/api/s/{key}/restart` | ❌ | P1 (infra) |
| E5 | Project trust: list projects, trust or untrust them, set the default | `~/.pi/agent/trust.json`, `defaultProjectTrust` | ❌ | P1 |
| E6 | Context files: view and edit `AGENTS.md`, `SYSTEM.md`, `APPEND_SYSTEM.md` (global and project) | files | ❌ | P2 |

### F. Extensions, skills, prompts, packages, tools, MCP

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| F1 | Resource browser: extensions, skills and prompt templates with source and scope | `get_commands` (sourceInfo) plus a folder scan, plus `pi list` | 🟡 slash list only | P1 |
| F2 | Turn extensions, skills, prompts and built-ins (`builtin:mcp`, `codemode`, `tool-search`, `llama.cpp`) on or off | `settings.json` resource arrays with `+`/`-` prefixes | ❌ | P2 |
| F3 | Packages: list, install (npm, git or URL; global or project), remove, update | `pi install / remove / list / update` streamed as a job log | ❌ | P2 |
| F4 | Browse the package gallery | npm search for keyword `pi-package` | ❌ | P3 |
| F5 | Tools in the current chat: list them and turn them on or off | companion `/pp-tools` → `pi.getAllTools` / `setActiveTools` | ❌ | P2 |
| F6 | Default tools (`defaultTools`), codemode mode and budget | settings | ❌ | P2 |
| F7 | MCP servers: list them with state, tools and errors; add, remove, enable, change exposure | `pi mcp list --json`, `pi mcp add/remove`, edit `mcp.json` | ❌ | P2 |
| F8 | MCP login, logout and reconnect from the phone | `/mcp login <srv>` through `prompt` (the notify + input dialog already works) | 🟡 works if typed | P2 |
| F9 | Skill and prompt editor: create or edit `SKILL.md` and `prompts/*.md` | files | ❌ | P3 |
| F10 | Prompt template arguments: show the argument hint in slash completion | `get_commands` | 🟡 | P3 |

### G. Extension UI protocol gaps

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| G1 | `setStatus`: a status chip row above the composer | `extension_ui_request` | ❌ ignored | P1 |
| G2 | `setWidget`: lines above or below the composer | `extension_ui_request` | ❌ ignored | P1 |
| G3 | `setTitle` | `extension_ui_request` | ❌ | P2 |
| G4 | Dialog `timeout`: show a countdown and close the sheet when pi resolves it | `extension_ui_request` | ❌ | P1 |
| G5 | `extension_error`: a visible list of errors per chat | event | 🟡 shown as a toast | P3 |

### H. Usage

| # | Feature | pi mechanism | pocketpi now | Pri |
|---|---|---|---|---|
| H1 | Usage dashboard: cost and tokens per day, model, project and provider pool, across all sessions | aggregate `usage` from assistant messages and `usage` entries in session files, cached by (mtime, size) like `sessions::scan` | ✅ (W3, Settings › Usage) | P2 |
| H2 | pi version, update available, self-update | `pi --version`, `pi update --self`, CHANGELOG | ❌ | P3 |

### Parity between pocketpi's two clients (from the inventory)

These are separate from pi's features.

- The web lacks: archive and delete, the Chat tab, the approvals inbox, `enabledModels` favourites, llama, and the active-runs line.
- iOS lacks: suggested replies, an explicit way to stop pi, a quick thinking chip, notification settings, webhook management, the DAG view, "open stage chat", worktree cleanup, approval notes, live runs over SSE, and adding projects by path.

These go in phase 5. They don't block anything else.

## 3. Architecture

1. **`src/pi_admin.rs` (new):** an atomic JSON read-modify-write of pi's files with a `.bak` rotation, using the same `.tmp` + rename pattern as `projects.rs`.
   - Files covered: `settings.json` (global and project), `auth.json`, `models.json`, `mcp.json` and `trust.json`.
   - Writes are patch-based (`{set:{path:value}, unset:[path]}`), so keys pocketpi doesn't know about are kept.
   - Reads of `auth.json` only return `{provider, type, hasKey}`, never the secrets.
2. **`src/pi_cli.rs` (new):** a job runner for `pi install|remove|list|update|mcp …|auth check` with `stdin </dev/null`.
   - Output goes over the existing runs SSE as `job` events.
   - One job runs at a time.
   - Arguments are a fixed allowlist and are never passed through a shell.
3. **Restart and reload (`main.rs`):**
   - `POST /api/s/{key}/restart` closes the pi and respawns it with `--session <file>`. The key stays the same; clients reconnect on `pocketpi_exit` with a `restarting:true` flag.
   - `POST /api/pi/reload` restarts every idle chat pi and returns which busy ones still need a restart.
   - A `config_epoch` counter increases on every admin write; each `Live` records the epoch it started with, and clients use that to show a "Restart to apply" chip.
4. **Companion extension `extensions/pocketpi-control.ts`:**
   - Always added with `-e` in `spawn_pi_with`, but not for Chat-tab or workflow stages.
   - Commands: `/pp-tree` (only if `get_tree` turns out not to be enough), `/pp-goto <id> [summarize] [instructions]`, `/pp-label <id> [text]`, `/pp-tools [json]`, `/pp-reload`, `/pp-mcp`.
   - It replies through a hidden custom entry (`customType:"pocketpi-control"`, `{reqId, ok, data}`), which clients receive as `entry_appended`. pocketpi turns that into an awaited response, so the client sees an ordinary `cmd` call.
   - The server hides `/pp-*` from the `get_commands` it relays.
   - **Phase 0 checks this end to end before anything depends on it.**
5. **RPC allowlist:** add `fork, get_fork_messages, clone, get_tree, get_entries, export_html, bash, abort_bash, follow_up, get_last_assistant_text, set_auto_compaction, set_auto_retry, set_steering_mode, set_follow_up_mode`.
   - Never allow `cycle_model`, `new_session` or `switch_session`. pocketpi's identity is the session file, so a session switch inside a pi would break the live-key mapping. A fork changes `sessionFile`, so after a fork the server re-reads `get_state` and broadcasts `pocketpi_session{file}`.
6. **Web:** new screens go in a new `web/manage.js`, embedded like `app.js` and loaded on demand. This keeps the 1900-line `app.js` from becoming a merge hotspot. Chat-level features (fork, bash, widgets) still go in `app.js`.
7. **iOS:**
   - All logic goes in PocketPiKit: `Admin.swift` for settings/auth/packages/MCP/trust, and `Tree.swift` for tree building and the fork list. Both are unit-testable on Linux.
   - Views go in a new **Settings** tab (or a sheet from the server menu).
   - New chat features extend `ChatSession` and `Transcript`.
8. **Tests:**
   - `fake-pi.py` learns every new RPC command and the `/pp-*` commands.
   - The integration tests cover each route.
   - New Rust unit tests cover `pi_admin` (patch merge, keeping unknown keys, never reading secrets back).
   - Add a `cargo test` job to `ios.yml`, or a new `rust.yml`.

## 4. Running it with subagents

Each wave launches agents with `isolation: "worktree"` on branches `pp/<feature>`. Every brief names the files the agent owns, the tests it must add, and "don't touch X". The orchestrator (this session) merges each branch, runs `cargo test` + `ios/test-linux.sh`, fixes conflicts, and only then starts the next wave. No wave runs more than 4 agents at once.

### Wave 0: foundations (1 agent, run on its own because everything later depends on it)

- **W0-core:** `pi_admin.rs` (read and patch, backups, secret redaction), `pi_cli.rs` job runner, restart/reload endpoints, `config_epoch`, the allowlist additions, `pocketpi_session` after fork, and a skeleton of `pocketpi-control.ts` with the reply-through-custom-entry mechanism checked against **real pi**.
  - Also: `fake-pi.py` stubs for every new command; PocketPiKit `Client` methods plus models for the new routes; Rust unit tests; a CI `cargo test` job.
  - Gate: one round-trip `/pp-tools` call through real pi 1.5.0 works and is written up in this file.

### Wave 1: chat-level P1 (3 agents in parallel)

| Agent | Scope | Owns |
|---|---|---|
| W1-fork | A1, A2: a "Fork from here" action on user messages (web and iOS) with the text put back in the composer; the server follows the session-file change | `app.js` message actions, `Transcript`/`ChatSession` fork, `MessageViews.swift` |
| W1-composer | B1 steer vs follow-up (long-press on send / a menu), B2 `!`/`!!` bash with a streaming card and abort, B4 retry countdown + Stop retrying | `app.js` composer, `ChatView` composer, `Transcript` bash |
| W1-extui | G1–G4: status chips, widgets, title, dialog timeouts | `app.js` `extensionUI`, `Transcript.extensionRequest`, `ExtensionSheet` |

Conflict risk: all three touch `app.js` and `Transcript.swift`. Merge them in this order: extui, then composer, then fork. Each brief says "add new functions; edit `onEvent`/`apply` only with single-line dispatch calls".

### Wave 2: management P1 (3 agents in parallel)

| Agent | Scope |
|---|---|
| W2-settings | E1 settings screen (typed fields from a hand-written spec of RPC-relevant keys), E4 "Restart to apply" UI, C1 defaults, C2 `enabledModels` editor, B3/B4/B5 global toggles. Web goes in `manage.js`; iOS gets a Settings tab. |
| W2-trust-resources | E5 trust manager; F1 resource browser (extensions, skills and prompts from a folder scan plus `get_commands` sourceInfo plus `pi list`) |
| W2-providers | D1 provider status (`pi auth check`), D2 API-key add and remove (redacted), with a warning that OAuth providers need the terminal |

### Wave 3: P2 depth (up to 4 agents in parallel)

| Agent | Scope |
|---|---|
| W3-tree | A3 tree viewer, A4 navigate with a summary prompt, A5 labels (through `pocketpi-control`), A11 session info |
| W3-packages-mcp | F2 enable/disable, F3 package jobs, F7 MCP manager, F8 MCP login helper button |
| W3-tools-context | F5 per-chat tools, F6 default tools and codemode, E6 context-file editor, E2/E3 project settings and raw editor |
| W3-export-usage | A7 HTML export viewer, A8 JSONL download, H1 usage dashboard (`src/usage.rs`, cached scan), B6 compact with instructions, C3 thinking per model, C6 llama on the web |

### Wave 4: P3 and spikes (only if wanted)

A9 import, A10 gist share, A13 paging, C4 `models.json` editor, C5/H2 updates, D3 OAuth through a pty (a research spike: write up what's feasible first, then decide), D4, F4 gallery, F9 skill/prompt editor, G5.

### Wave 5: web ↔ iOS parity

Two agents: "web catches up to iOS" and "iOS catches up to web", using the gap lists in §2.

### What every agent brief includes

- The goal and the feature IDs from this document, and the files the agent owns and must not touch.
- How pocketpi works:
  - Identity is the session file path; live keys are temporary.
  - Every POST needs `X-Pocketpi: 1`.
  - `kill_on_drop` and the reaper.
  - Session files must be written as compact JSON, because `sessions::scan` matches on substrings.
- Rules:
  - Never send secrets to clients.
  - Never send `cycle_model`, `new_session` or `switch_session`.
  - Settings writes are patches.
- Definition of done:
  - `cargo build --release` and `cargo test` pass.
  - `ios/test-linux.sh` passes, with new integration tests.
  - `fake-pi.py` is updated.
  - Web is checked by hand with Playwright screenshots (chromium is preinstalled), at phone size.
  - iOS views compile. Real compilation needs the manual `ios.yml` macOS run, which the orchestrator triggers once per wave rather than each agent.
- Commit style: short imperatives, prefixed `iOS:` where it fits. Don't push; the orchestrator merges.

### Risks

- **Global settings side effects.** RPC toggles change `settings.json`, which also affects the terminal TUI and workflow stages. The UI labels them "Global", and `pi_admin` keeps backups.
- **Restarting a pi mid-chat** loses in-flight state, so reload only touches idle processes.
- **Whether the `pocketpi-control` reply channel works isn't confirmed yet.** If `entry_appended` doesn't fire for a custom entry made inside a command, fall back to the extension POSTing to pocketpi over HTTP, as `pocketpi-workflows.ts` already does. *(Confirmed in Wave 0; see §5. No fallback needed.)*
- **OAuth through a pty** is fragile, so it's held back to Wave 4 as a spike.
- **iOS SwiftUI can't be compiled on Linux**, so view errors only show up in the macOS CI run. Keep views thin.

## 5. Wave 0 findings

Checked on 2026-11-08 against real pi 1.5.0 (`~/.local/bin/pi`), each time in a
scratch `HOME` / `PI_CODING_AGENT_DIR` from `mktemp` with `PI_OFFLINE=1` and no
credentials (no model call was needed). Two ways: driving `pi --mode rpc -e
extensions/pocketpi-control.ts` directly from a script, and through a scratch
pocketpi built from `pp/w0-core` (`POCKETPI_PI=~/.local/bin/pi`, its own port)
with curl.

### The reply channel works (the gate)

- `prompt` with `"/pp-tools r1"` runs the extension command with no model and
  no credentials. pi prints
  `{"type":"entry_appended","entry":{"type":"custom","customType":"pocketpi-control","data":{"reqId":"r1","ok":true,"data":{...}},"id":…,"parentId":…,"timestamp":…}}`
  and **then** the prompt's response, `{"success":true,"data":{"disposition":"handled"}}`.
  So the server must register its waiter before sending (it does).
- `pi.getAllTools()`, `pi.getActiveTools()` and `pi.setActiveTools()` all work
  from a command handler; the change shows in the next `/pp-tools`. A fresh
  scratch pi has 10 tools, 4 active (`read`, `bash`, `edit`, `write`).
- A thrown error comes back as `{ok:false, error}` (e.g. `unknown tools: nope`).
- Through pocketpi: `POST /api/s/{key}/control {"command":"tools"}` →
  `{success:true, data:{tools, active}}`; with `args:{active:["read","bash"]}`
  the set changes; after `POST /api/s/{key}/restart` the same key answers
  again and the tools are back to pi's defaults (active tools are per process).
- `get_commands` lists `pp-tools` with `source:"extension"`,
  `sourceInfo.source:"cli"`; pocketpi filters it out of what it relays.
- The extension loads from an absolute `.ts` path with `-e` when it only uses
  `import type` (pocketpi writes it to `$XDG_DATA_HOME/pocketpi/` at startup).

### Things later waves need to know

- **Reply entries are persisted.** In a chat with history the custom entry is
  appended to the session `.jsonl` (a `/pp-tools` reply is ~5–10 KB because it
  carries tool descriptions). In a new chat with no messages yet, pi keeps it
  in memory and does **not** create the session file, so a control call never
  creates a chat. pocketpi drops these entries from relayed `get_entries` and
  keeps them off the SSE stream; `get_tree` still contains them, so the tree
  viewer (W3-tree) must skip `customType:"pocketpi-control"` nodes. Commands
  with big answers should keep their payloads lean.
- **fork** `{entryId}` answers `{text, cancelled:false}` (the forked user
  message's text, for the composer); the pi then writes to a new file in the
  same folder as the original, holding the entries before that message
  (`messageCount` 4 → 2). **clone** answers `{cancelled:false}` and also moves
  to a new file. pocketpi re-reads `get_state`, updates the live chat's file and
  broadcasts `pocketpi_session{file}`; checked through the server.
- **export_html** honours `outputPath`; pocketpi always overrides it with a
  file in `$XDG_DATA_HOME/pocketpi/exports/` so a client can't write elsewhere.
- **Restart** through pocketpi on a session with history: same key, same file,
  `get_messages` still has all 4 messages.
- **CLI:** `pi --version` prints `1.5.0`. `pi auth check --provider openai --json`
  exits 1 with `{"status":"not_ready","provider":"openai","reason":"credentials_not_configured"}`
  (unknown provider: `reason:"provider_not_found"`). `pi mcp list --json` prints
  `{servers, errors}` and exits 1 when any enabled server fails (its entry has
  `state:"failed"`, `error`), so exit codes are information, not failure.
  `pi mcp add demo -- echo hi` / `pi mcp remove demo` write `mcp.json`
  (2-space JSON); `pi install <local dir>` adds a *relative* path to
  `settings.json` `packages`; `pi list` is text only. pi creates `auth.json`
  as 0600.
- **Not verified:** running a `/pp-*` command while the agent is streaming (it
  needs a model). pi's docs say extension commands run immediately even then.

### What W0-core built, and where it differs from §3

- Routes are listed in README.md ("pi's configuration"). Quick read-only CLI
  calls are GETs (`/api/pi/version`, `/api/pi/auth/{provider}`, `/api/pi/mcp`,
  `/api/pi/packages`); everything else is a job (`POST /api/pi/jobs`).
- `pi_admin` also redacts credential-looking values in `models.json` and
  `mcp.json` (keys containing key/token/secret/password/authorization/
  headers/env/credential) and refuses to store the `<redacted>` marker, so a
  raw editor can't overwrite a secret with it. Dotted paths escape a literal
  dot as `\.` (model ids). A file that isn't valid JSON is never overwritten
  (422). Symlinked files are written through.
- `/api/pi/reload` restarts only chats behind the epoch unless `{"all":true}`;
  it includes Chat-tab chats, never workflow stages. `/restart` refuses (409) a
  chat that is streaming.
- The four global RPC setters bump the epoch too (they rewrite settings.json);
  the pi that made the change keeps its epoch current.
- Clients can't send `/pp-*` as a prompt (400). Before a pi's first control
  call the server checks `get_commands` for the command, so a failed extension
  load can't turn `/pp-tools …` into a prompt for the model.
- `POCKETPI_CONTROL=0` turns the extension off.
- Every live pi now has a `kind` (`chat`, `chat_tab`, `stage`), in
  `/api/pi/status` and `pocketpi_hello`.
- PocketPiKit: `Admin.swift` (config, status, reload, restart, control/tools,
  jobs, CLI helpers); `Transcript` emits `.restarting` and
  `.sessionFileChanged`; `ChatSession` keeps its key across a restart, follows
  a fork's new file, exposes `needsRestart` and `restart()`.

## 6. Safety wave (S): use existing packages, build only the glue

Below is what four packages do once pocketpi has stripped the TUI away. It comes from reading their source on 2026-11-08 (`npm pack --ignore-scripts`, not executed), so it still needs checking under `pi --mode rpc`:

| Package | Over RPC | With no answer / `cancelled` | Notes |
|---|---|---|---|
| `@gotgenes/pi-permission-system` v42 | ✅ When `mode !== "tui"` it switches from its inline TUI prompt to plain `ui.select`/`ui.input` (`permission-prompt-component.ts` `chooseDecisionSurface`). Those are dialogs pocketpi already renders | Denies. Has a `promptTimeoutMs` | Allow/ask/deny rules for tools, bash patterns, paths, external dirs, MCP and skills. Most used of the four (~48K/mo) |
| `pi-permission-modes` v2.7 | ✅ Uses `ui.select`/`ui.confirm` | Denies when there's no UI | Default/Plan/Build/YOLO modes. Bash runs in bwrap (bwrap, socat and rg are installed here). Network allowlist |
| `pi-sandbox` v0.8 | 🟡 Bash still runs in bwrap, but access prompts use a widget plus raw key input. When `mode !== "tui"` they return "aborted" | Denies anything outside the static policy | Use as a fixed sandbox only, with `~/.pi/agent/sandbox.json` set up ahead of time. You can't approve exceptions from the phone |
| `pi-bouncer` v0.7 | ✅ `ui.select`/`ui.input` | — | Smaller. Model-judge mode |

Nothing needs to be built for the policy engine or the bash sandbox. pocketpi supplies the glue:

- **S1:** Install and check `@gotgenes/pi-permission-system`, plus either `pi-sandbox` or `pi-permission-modes` for bwrap, in a scratch agent dir under `--mode rpc`. Record which `extension_ui_request` each one sends, and confirm that cancel and timeout both deny. Pick one combination. Workflow stages already answer `cancelled:true`, so they deny by default. Give them a separate rules file (via `PI_CODING_AGENT_DIR` or project config) with an allowlist suited to unattended worktree runs.
- **S2:** Push a notification for a **pending dialog** (any `extension_ui_request` confirm, select, input or editor) when no client is watching or the phone is locked. Tapping it deep-links to the chat. Show a countdown when the dialog has a `timeout`. This overlaps with G4.
- **S3:** Add a safety page to Settings (the `pi_admin` editor) for the chosen packages' config files: global and project rules, sandbox allowlist, mode. Include a clear "Off / Ask / Strict" summary per project.
- **S4 (optional, the strongest layer, not offered by any package):** run each pi process inside bubblewrap, wrapped where `spawn_pi_with` starts it. The project or worktree is writable, `~/.pi/agent` is mounted, and `~/.ssh` and the rest of `$HOME` are hidden. Turn it on per project in `projects.json`. Workflow runs never get push or `gh` credentials; the server does the push and PR step itself.

It goes after Wave 0, because it needs `pi_admin` and restart-to-apply, and runs alongside Wave 2.

### S1 results (2026-11-08, real pi 1.5.0 `--mode rpc`, deepseek-v4.1-flash, script in ~/pi-safety-test)

| | gotgenes v42 (rules: `rm *` ask, `~/.ssh/*` deny, `*.env` ask, external ask, timeout 20s) | pi-permission-modes v2.7 (`--perm build`) | pi-sandbox v0.8 (defaults) |
|---|---|---|---|
| Ask over RPC | ✅ `select` "Permission Required" with options Yes / Yes for session / No / No with reason | ✅ `select` with options Allow once / for session / Deny | ❌ no prompts at all, fixed policy only |
| Approve and deny | ✅ both work | ✅ both work | — |
| No answer | ✅ denied after `promptTimeoutMs`; the model is told nobody answered | not tested | — |
| `cancelled:true` | the model never ran the command in this case, so not tested | ✅ network prompt cancelled → denied | — |
| Read `~/.ssh` | ✅ hard deny, through bash and the read tool | ✅ asks (outside the project) | ❌ read allowed |
| Writes outside the project | ✅ asks | ✅ asks | ❌ `touch ~/outside.txt` allowed |
| Network | not restricted | ✅ asks per host; denied → blocked by the sandbox | ✅ blocked (not in allowedDomains) |
| `rm -rf` inside the project | asks (per rule) | allowed in Build mode (by design) | allowed |
| `git add -A` | ✅ | ❌ the sandbox masks dotfiles with /dev/null device nodes, so `git add -A` fails | ❌ same problem, and it left a `.env` character device in the project |
| Status line | setStatus | setStatus with ANSI codes (now stripped, G1) | setStatus |

**Decision:**
- **Phone chats:** adopt `@gotgenes/pi-permission-system`, installed globally.
  - Pair it with S2: a push notification for a pending dialog, plus a long `promptTimeoutMs` such as 10 min, so a forgotten prompt ends as a deny.
- **OS sandbox:** offer `pi-permission-modes` as an optional per-project "Strict" mode, not the default.
  - Its prompts and network gate work over RPC.
  - The dotfile masking breaks `git add -A` inside the agent. pocketpi's engine commits stages itself, outside the sandbox, but chats that commit would hit it.
  - Running both packages together hasn't been tested yet; check it before offering both at once.
- **Drop `pi-sandbox`:** nothing in it can be approved from the phone, and its defaults allow reads of `~/.ssh` and writes outside the project.
- **Workflow stages:** dialogs are auto-cancelled, so every "ask" becomes a deny. Stages need their own gotgenes config (allow the usual build commands, deny the dangerous list), loaded through a stage-specific agent dir or a project config. S3 builds the UI for this.

### S2 / S3 and the stage policy (built on `pp/safety`)

**How gotgenes finds its config** (read from its v42 source): the global
policy is `getAgentDir()/extensions/pi-permission-system/config.json`
(`getAgentDir()` is `$PI_CODING_AGENT_DIR` or `~/.pi/agent`); no env var or
flag names the file itself. On top of it, later wins: the project's
`<cwd>/.pi/extensions/pi-permission-system/config.json` (only when pi trusts
the project), then per-agent frontmatter in `<agent dir>/agents/<name>.md` and
`<cwd>/.pi/agents/<name>.md`, picked by an `<active_agent name="…">` tag in the
system prompt. Rule maps shallow-merge (a key in both keeps the global's
position), so the upper layers can only patch the global policy, not replace
it.

**Mechanism chosen: an overlay agent dir for stages** (`src/safety.rs`). When
`~/.config/pocketpi/safety/stage-policy.json` exists, a stage's pi is started
with `PI_CODING_AGENT_DIR=~/.pi/agent.pocketpi-stage`, a folder next to the
real agent dir in which every entry is a symlink to the real one, except
`extensions/` (a real folder of symlinks) whose `pi-permission-system/` holds
`config.json` → the stage policy and its own `logs/`. It is rebuilt (cheaply,
under a lock) at each stage start, so new packages, extensions and logins
show up. Why this one:

- It is the only way to give stages an **independent** policy. A project or
  agent layer merges over the chat policy, so an "ask" there stays an ask
  (= deny in a stage) unless every key is overridden; the project layer also
  needs project trust for each worktree and would be committed into the
  worktree; the agent layer needs a file in the person's `agents/` folder
  (which subagent packages list) and a system-prompt tag, and its YAML
  frontmatter can't hold quoted patterns reliably.
- Stages still see the person's auth, settings, models, packages, trust and
  MCP config: pi writes through the symlinks (`writeFileSync` follows them;
  checked for `auth.json`/`settings.json`). pi's own files that don't exist
  yet (`auth.json`, `trust.json`, …) are linked dangling, so pi creates them
  in the real dir.
- Being a sibling of the real dir keeps relative paths in `settings.json`
  (`packages`, `extensions`) resolving to the same places (pi resolves them
  lexically from the agent dir).
- Session files go to the real sessions folder (`--session-dir` with pi's
  per-cwd folder, unless `PI_CODING_AGENT_SESSION_DIR` is set), so stage
  chats are listed and reopened like before.
- Without the stage policy file nothing changes (stages use the chat policy
  and asks are denied).

Limits: `proper-lockfile` locks (`auth.json.lock`) are per path, so a chat and
a stage refreshing the same OAuth token at the same moment aren't serialised.
The policy is a speed bump, not a sandbox: a stage can still reach git
credentials (S4 bubblewrap is the real boundary).

Checked with real pi 1.5.0 and gotgenes 42 in a scratch `HOME` (no model
needed): a workflow stage logged `config.loaded {yoloMode: true, debugLog: true}`
from the stage policy into the overlay's `logs/`, a chat pi loaded the chat
policy (`yoloMode: false`) from the real dir, neither logged a validation
warning, and the stage's session file landed in the real sessions folder.

**Proposed policies** (`extensions/safety/`, embedded in the server, written
only when the person taps "Install with recommended policy" / "Use the
recommended … policy"; `node scripts/check-safety-policies.mjs <schema>`
checks them against the package's `schemas/permissions.schema.json`):

- `chat-policy.json`: allow by default; `bash` asks for `rm`, `rmdir`,
  `shred`, `dd`, forced pushes (`-f`, `--force*`, `+ref`), `git reset --hard`,
  `git clean`, `git branch -D`, `git checkout --`, `git stash drop/clear`,
  `npm/cargo publish`, and a bare `sh`/`bash`/`zsh` (what `curl … | sh` runs;
  gotgenes matches each command of a pipe separately); denies `sudo`, `doas`,
  `su`, `pkexec`, `mkfs`. `path` hard-denies `~/.ssh`, `~/.aws`, `~/.gnupg`,
  `~/.config/gh/hosts.yml`, `~/.pi/agent/auth.json`,
  `~/.config/pocketpi/apns/*`, `*.env` and `*.env.*` (but allows
  `*.env.example`). `external_directory` asks, except `/tmp`,
  `~/.cargo/registry`, `~/.cargo/git`, `~/.rustup`, `~/.npm`.
  `promptTimeoutMs` 10 min (`forwardingTimeoutMs` 11 min, it must be
  larger). gotgenes already floors `bash -c`, `eval`, `sudo`, `env cmd`,
  `xargs`, `find -exec` to "ask".
- `stage-policy.json`: the same hard denies; `yoloMode: true` so nothing
  asks (gotgenes' wrapper floors would otherwise deny `env X=1 cmd`,
  `xargs`, `find -exec` in a stage), with explicit denies for `git push`
  forced or to main/master (a stage may push its own branch and `gh pr create`: clipt-fix-pr's open-pr stage does), `gh pr merge`, `gh release`,
  `gh repo`, publishing, piping into a shell, root, `mkfs`; reads outside the
  worktree are allowed, writes outside it are denied except `/tmp` and the
  package caches.

**S2 (pending dialogs)**, `src/dialogs.rs`: a chat's (not a stage's) confirm /
select / input / editor dialog is remembered per pi; if no client has the
chat's event stream open it notifies at once (web push + APNs, deep link
`/?s=<session file>`, tag `dialog-<key>`), otherwise after 20 s unanswered.
Once per dialog id; forgotten when a client answers, when its own `timeout`
passes, at `agent_settled`, or when the pi exits; a dialog that closes itself
within 10 s isn't notified. A gotgenes prompt reads as "Permission Required ·
<project>" / "pi wants to run: rm -rf junk" (or read/write/edit a path, "(outside
the project)"). The same notice goes on the runs stream as
`{"type":"dialog_pending", key, id, title, body, url}`, and
`pocketpi_hello` carries the open dialogs as `dialogs`, which both clients
show, so the chat a notification opens has the question up. Both clients now
show a multi-line dialog title as a heading plus the detail lines (gotgenes
puts everything in the title).

**S3 (Settings › Safety, order 50)**: installed or not (settings `packages`),
"Install with recommended policy" (the pinned `pi install` job, then the
chat policy through `pi_admin`), the chat policy's `bash`, `path` and
`external_directory` lists (and the directional ones when a file uses them),
each project's Off / Ask / Strict, and the stage policy. pi_admin knows two
more files: `permissions` (global and `?cwd=`) and `stage-policy`. Their rule
maps come back as ordered `rules` and go in as `[[pattern, action], …]`
(serde_json now keeps key order everywhere); bad actions are refused; writes
don't bump the config epoch because gotgenes rereads its policy when the file
changes. Project modes write only their own keys: **Off** = `yoloMode: true`
(asks become allows, explicit denies still deny), **Strict** = `bash."*"`,
`write`, `edit` set to ask (the global's named allows and denies still win
for their patterns), **Ask** = neither. Each project row says when pi doesn't
trust the project, since gotgenes then ignores its file.

## 7. Settings hub contract

W2-shell built an empty Settings hub so the Wave 2 agents can each add pages
without touching the same lines. On both clients a page is **one new file plus
one line**; nothing else in the hub, `app.js`, `index.html` or the app's tabs
changes.

### Web

A page is `web/manage-<id>.js` plus one line in `MANAGE_PAGES` in `src/main.rs`:

```rust
const MANAGE_PAGES: &[(&str, &[u8])] = &[
    manage_page!("about"),
    manage_page!("<id>"),   // ← the only Rust line a page adds (append at the end)
];
```

`manage_page!` embeds the file, serves it at `/manage/<id>.js` and lists it in
`GET /api/manage/pages`; `web/manage.js` loads every listed page the first time
Settings opens. `cargo test` checks that each listed file calls
`ppManage.register` with its own id. The file:

```js
ppManage.register({
  id: "<id>",            // [a-z0-9-]+, same as the file name; URL ?m=<id>
  title: "Providers",
  subtitle: "API keys",  // optional (string or () => string)
  icon: "<svg …>",       // optional, 24×24 stroke like app.js ICON.*
  order: 30,             // hub position, ascending
  async render(el, ctx) { /* fill el; return a cleanup function if needed */ },
});
```

`ctx`: `api(path, body?)` (app.js's helper: GET, or POST JSON with
`X-Pocketpi: 1`), `toast(msg, error?)`, `openSheet(build)` / `closeSheet()`,
`navigate(id)` (`""` = hub), `rerender()`, `needsRestart()` (call after a
config write or a job that changed files: refetches `/api/pi/status` and shows
"Restart to apply"; returns the status), `status()`, `project` (the drawer's
selected project path, for `?cwd=`), `home`, `style(css)` (page CSS injected
once; scope it under `.mp-<id>`, which `el` carries, so nobody edits
`app.css`), `el`, `esc`, `ICON`. Reuse app.js's classes: `.wf-section`,
`.wf-card`, `.opt` rows, `.switch`, `.chip`, `.btn`/`.btn-row`, `.field`,
`.errbox`, `.list-empty`.

Ways in: `?m=` (hub) / `?m=<id>`, the gear at the bottom of the drawer's rail,
and a "Settings" row in the chat sheet, the new-chat sheet and the project
menu. app.js only has one-line hooks (`window.ppManage?.…` in `showView`,
`pocketpi_hello`, `config_changed`, the sheets and boot).

### iOS

A page is `ios/PocketPi/Sources/Settings<Name>Page.swift` plus one line in
`SettingsPages.all` (`SettingsTab.swift`):

```swift
extension SettingsPage {
    static let providers = SettingsPage(id: "providers", title: "Providers", subtitle: "API keys",
                                        systemImage: "key", order: 30) { ProvidersPage() }
}
// SettingsTab.swift:  static let all: [SettingsPage] = [ .about, .providers, ]
```

The page view reads `@Environment(SettingsHub.self) private var hub`, calls the
server with `hub.client` (`Admin.swift`: `config`, `patchConfig`, `startJob`,
`authCheck`, …) and calls `await hub.changed()` after a write. Logic goes in
PocketPiKit (tested on Linux); the view stays thin. Settings is the third tab.

### Restart to apply (both clients)

`SettingsHub` (Kit) / `manage.js` keep `/api/pi/status`: the web refetches it on
`config_changed` (runs SSE), on each chat's `pocketpi_hello` and on
`ctx.needsRestart()`; iOS polls it every 8 s while connected and on
`hub.changed()`. A chat's pi is behind when its epoch (the newer of the status
and its hello) is below the config epoch (the newer of both). The banner shows
in Settings when any chat (not a workflow stage) is behind, and on a chat when
that chat is. Its button is `POST /api/pi/reload` (web, both places; iOS
Settings) or `POST /api/s/{key}/restart` (iOS chat); busy chats are reported
("N busy chats left") and keep the banner until they're idle and it's pressed
again.

### Suggested ids and order

| order | id | owner |
|---|---|---|
| 10 | `settings` (general, models, global toggles) | W2-settings |
| 20 | `providers` | W2-providers |
| 30 | `trust` | W2-trust-resources |
| 40 | `resources` | W2-trust-resources |
| 50 | `safety` | S3 |
| 60 | `usage` | W3-export-usage |
| 1000 | `about` | W2-shell |

Use the same id and order on web and iOS.
