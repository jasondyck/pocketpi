# DeepSeek Harness features in pocketpi: plan

This plan is based on dsh 0.2.1-rc.3 (`@deepseek-ai/dsh`, installed on arlo) and pocketpi master at 34363f8, as of 2026-11-09. It covers seven features:

1. goal mode
2. plan mode with a todo list
3. per-chat permission presets
4. a worktree per chat
5. a files panel
6. a terminal panel
7. better titles and a turn outline

Voice input was considered and dropped (2026-11-09): iOS keyboard dictation covers it, and arlo has no speech-to-text service.

## 1. What we take from dsh, and what we change

dsh stores each chat's state as events in the session log and gives clients a view built from them. pi has the same building blocks:
- `pi.appendEntry` for state that stays out of the model's context;
- `session_start` to restore that state;
- tool-result `details` for state that has to follow branches.

So every per-chat mode below is a pi extension that keeps its state in the session file. Fork, clone, resume and server restarts then keep it with no extra store. That fixes a gap the research found: `restart_live` (main.rs:959) respawns with no extra args, so any per-chat flag kept in the server would be lost.

**Adopted from dsh:**
- **Goals are driven by tools, and the model reports completion.** The model calls `goal_update{action:"complete"}`; there is no separate judge. A round cap is the hard stop. Marking a goal blocked is refused before 3 rounds. Every update carries a revision number and is compare-and-set.
- **Never resume a goal on its own.** After a resume, fork, restart or abort, the goal stays paused until a person resumes it.
- **Keep the tool list the same in plan mode.** That keeps pi's prompt cache warm. Unlike dsh, pocketpi also blocks mutating tool calls in a `tool_call` handler, which doesn't change the tool list. dsh relies on its sandbox for this, and pocketpi has no sandbox.
- **`exit_plan_mode` is the only way out of plan mode.** It asks "Approve / Keep planning", and Keep planning can carry feedback.
- **Todos follow pi's `examples/extensions/todo.ts`.** The full list goes in on every call and is stored in the tool result's `details`, so branching keeps it correct.
- **Changed files are tracked per turn with git snapshots** in a private index and object store, so the user's repo is never touched. Unlike dsh, pocketpi saves the snapshots, so they survive a restart.
- **@-mentions insert a path only.** The model reads the file itself.
- **Titles are generated off the main path and can be cancelled.** A rename by the user pins the title.
- **File reads are paged and capped,** and return explicit `too-large` / `not-text` errors instead of truncating.

**Added beyond dsh** (gaps in dsh): merging and discarding a worktree, a cost cap on goals, saved changed-file history, and a goal-finished push notification.

## 2. Shared groundwork (Wave 0, done alone before anything runs in parallel)

These are the hotspots every feature touches. Doing them first stops parallel work from colliding.

- **Extensions:**
  - Add `extensions/pocketpi-goal.ts` and `extensions/pocketpi-modes.ts` as stubs.
  - Embed them like `pocketpi-control.ts` (`include_str!` and install at startup).
  - Pass them with `-e` for `Kind::Chat` only. Chat-tab chats and workflow stages don't get them.
  - `POCKETPI_GOAL=0` and `POCKETPI_MODES=0` turn them off.
- **Control channel:**
  - Extend `CONTROL_COMMANDS` (main.rs:116) with `goal`, `mode`, `plan` and `todo`.
  - Each extension replies through the same `pocketpi-control` entry convention as the existing commands.
  - Filter the new `pocketpi-*` custom entries out of `get_entries`, as happens today.
- **Chat state in hello:** extensions publish their state with `ctx.ui.setStatus("pp-goal", json)` and similar calls. These are already replayed in `pocketpi_hello.ui`, so clients get the current goal, mode and todos on connect.
  - Clients that know a `pp-*` key draw it natively.
  - Unknown keys keep the generic chip, so older apps still show something.
- **Web layout:** add a side-panel slot to `index.html`. It sits beside `#main` on wide screens and opens as a full-height sheet on phones. Add one composer chip row.
  - Hooks: `window.ppPanel.open(id, el)` and `window.ppComposerChips.set(key, el)`.
- **iOS:**
  - a `ChatAccessory` area above the composer for goal and todo strips;
  - a composer chip slot;
  - title-menu entries for Goal, Plan, Files and Outline, each a placeholder until its wave lands.
- **Server state helper:** `src/chat_state.rs` keeps per-session JSON under `~/.local/share/pocketpi/chats/<session-id>.json`. Only server-side features use it: snapshots, the title pin and worktree metadata.

## 3. Features

### 3.1 Goal mode (`extensions/pocketpi-goal.ts`)

**State:** `pocketpi-goal` entries holding the full snapshot:
`{id, revision, objective, phase: active|paused|blocked|complete, rounds, maxRounds, maxCost, costAtStart, blockedReason?}`.
- The last entry wins.
- A cleared goal leaves a tombstone.
- `armed` is kept in memory only and is false after `session_start`.

**Model tools** (dsh's shapes):
- `goal_get()`
- `goal_create{objective, maxRounds?}`
- `goal_update{goalId, revision, action: edit|pause|resume|complete|blocked, objective?, blockedReason?}`

Create, edit, pause and resume need a user message in the current turn. Complete and blocked are also allowed from an automatic round. Blocked is refused until 3 rounds have passed.

**Driver:** on `agent_settled`, continue only when all of these hold:
- the run wasn't aborted;
- the last turn didn't end in an error, which leaves `subscription-fallback.ts` to handle it;
- the goal is active and armed;
- rounds < maxRounds;
- the cost since the start is below maxCost (summed from assistant `usage.cost` in the branch).

When they do, `pi.sendUserMessage(<goal_round> prompt)` runs. It is dsh's prompt with "Round N/M". Before sending, the driver bumps `rounds` with a new snapshot.

**Defaults:** maxRounds 30, maxCost $5. Both can be changed per goal and in Settings.

**Wrap-up:** completing or blocking a goal from an automatic round adds dsh's `<goal_complete>`/`<goal_blocked>` instruction: summarise with evidence and call no more tools.

**User control:** `/control goal {action, …}` from the client, plus a typed `/goal …` that the extension handles as an `input` transform. A user's goal command re-arms the goal.

**Server changes:**
- While a goal is running, the server holds back the "long turn finished" push for each round. It sends one push when the goal completes, is blocked, or hits the cap.
- `auto_title` runs on the objective.

**Clients:**
- a goal strip above the composer showing the objective, the phase, rounds N/M and $ spent, with Pause/Resume, Edit and Clear;
- "Start a goal…" in the chat menu;
- web and iOS.

**Tests:**
- extension unit tests with a fake `pi`, covering the driver conditions, compare-and-set and re-arming;
- a scripted RPC test with `ios/fake-pi.py` if practical.

### 3.2 Plan mode and todos (`extensions/pocketpi-modes.ts`, part 1)

**Plan mode:**
- `pocketpi-mode` entries `{plan: bool}`.
- While plan mode is on:
  - a `before_agent_start` section adds dsh's plan policy: plan only, the plan must be decision-complete, and `exit_plan_mode` is the final call;
  - a `tool_call` gate blocks `edit`/`write` and bash commands outside a read-only allowlist, with the reason "plan mode: read-only".
- `exit_plan_mode{plan}`:
  - The plan is markdown starting with `# `.
  - The tool calls `ctx.ui.select("Approve this plan?", ["Approve", "Keep planning"])`. That is pocketpi's dialog path, so it push-notifies when the chat isn't open.
  - Keep planning is followed by `ctx.ui.input("What should change?")` and returns a tool error with the feedback.
  - Approve turns plan mode off and returns "Plan approved; carry it out."
- Entry points: `/control plan {on|off}` and `/plan [msg]`.
- Clients:
  - a "Plan" composer chip; tapping it turns plan mode off;
  - the `exit_plan_mode` tool card renders the plan as markdown;
  - the approval dialog shows the plan.

**Todos:**
- `todo_write{todos:[{content, status: pending|in_progress|completed}]}` (dsh's validation: unique, non-empty, at most one in progress).
- State is kept in `details`, and `setStatus("pp-todo", json)` mirrors it.
- The list is cleared when the next user prompt starts, as in dsh.
- Clients show a todo dock above the composer with a collapsed "3/7 done" line.

### 3.3 Permission presets (`extensions/pocketpi-modes.ts`, part 2)

**Presets:**

| Preset | Edits and writes | Bash | Notes |
|---|---|---|---|
| **Read-only** | blocked | read-only allowlist only | the same gate as plan mode |
| **Ask** | each one asks: Allow once / Allow for this chat / Deny with reason | each command outside the allowlist asks the same way | "Allow for this chat" is saved as an entry; dsh only offers allow-once, and pocketpi already has per-session allow in gotgenes |
| **Auto** (default) | no extra gate | no extra gate | today's behaviour |

- gotgenes' denies and asks (`rm`, sudo, secrets) stay in force under every preset. An extension can add blocks, not remove them. The UI says so.
- **State:** `pocketpi-mode` `{preset}`. A new chat's default comes from Settings (`~/.config/pocketpi/settings.json`).
- **Changing preset:**
  - adds a `before_agent_start` line telling the model the current policy, worded like dsh's per-step text;
  - sends a one-line steer message: "Permission preset changed from Auto to Read-only by the user."
- **Ordering check:** confirm whether the `-e` extension's `tool_call` runs before gotgenes' handler. If it runs after, a gotgenes ask could pop before our block. That's harmless, but note it.
- **Clients:** a preset chip in the composer opening a 3-option picker. Read-only shows as a lock. Switching to Auto from the others needs no confirmation, because Auto is today's normal behaviour.

### 3.4 Worktree per chat (server: `src/chat_worktrees.rs`, Wave 3, alone)

**Creating:** "New chat in a worktree" on a git project.
- Path: `~/.local/share/pocketpi/chat-worktrees/<repo-name>/<slug>`. This directory is separate from the workflows' `worktrees/`, so the list filter at main.rs:1259 stays correct for runs.
- Command: `git worktree add -b pp/chat/<slug> <path> <base>`. The base is the project's current branch.
- The record `{repo, path, branch, base, baseCommit}` goes in `chat_state`.
- The new path inherits the repo's pi trust entry.

**Fixes needed:**
- **Listing:** sessions whose cwd is a chat worktree are grouped under the parent repo's project, with a branch badge.
- **`pocketpi-workflows.ts:28`:** keep its guard on `/pocketpi/worktrees/` only.
- **Opening after removal:** `open_session` currently refuses a missing cwd. Instead, open the transcript read-only with a note: "worktree removed — branch `pp/chat/x` kept" or "discarded".

**Actions** (chat menu, web and iOS):
- **Merge into `<base>`:**
  1. `commit_all` in the worktree, with a commit message from `one_shot` and the cheap model.
  2. In the main checkout, require a clean tree on `<base>`. Otherwise say why and stop.
  3. Run `git merge --no-ff pp/chat/<slug>`. On a conflict, run `git merge --abort` and offer "Ask pi to resolve". That rebases inside the worktree from the chat and then retries.
  4. On success, remove the worktree and delete the branch.
- **Open PR:** push the branch and run `gh pr create` when the repo has a GitHub remote. Reuses the workflow stage code.
- **Keep branch, remove worktree.**
- **Discard:** confirm, then remove the worktree and delete the branch.

**Tests:** git integration tests in a temp repo covering create, merge (clean and conflict), discard and listing.

### 3.5 Files panel (server: `src/files.rs`)

**Endpoints**, all rooted at a live chat's cwd or a project cwd:
- `GET /api/files/list?root=&dir=`
  - directories first, then natural sort;
  - dotfiles shown;
  - capped at 2000 entries, with `truncated` set when cut;
  - each entry has `{name, kind, size, mtime}`.
- `GET /api/files/read?root=&path=&from=&lines=`
  - text pages of up to 5000 lines or 2 MiB;
  - a `version` field (mtime + size);
  - `not-text` for invalid UTF-8 or NUL bytes.
- `GET /api/files/raw?root=&path=`
  - images and PDFs, up to 32 MiB;
  - served with `Content-Security-Policy: sandbox` and `X-Content-Type-Options: nosniff`, so SVG and HTML never run as the app's origin.
- `GET /api/files/search?root=&q=`
  - for @-mentions;
  - a bounded index of 50k entries;
  - dsh's excluded directories plus `target`;
  - ranking: exact, then prefix, then substring, then subsequence;
  - rebuilt lazily after edits.
- `GET /api/files/changes?key=`, the changed files:
  - Per turn: on `agent_start` and `agent_settled`, run `git add -A` into a private `GIT_INDEX_FILE`, then `write-tree`, using a private `GIT_OBJECT_DIRECTORY` with the repo's objects as an alternate.
  - Tree ids are saved in `chat_state`, per turn and since the chat opened.
  - Returns `{turn, files:[{path, +, -}]}`, plus a diff per file on request.
  - For a non-git cwd, fall back to the paths seen in edit/write tool calls.

**Path safety:**
- `lstat` every path, canonicalize it, and require it to stay under the root.
- Refuse a final symlink when reading a file.
- Listing never follows directory symlinks outside the root.
- Reuse the canonicalize-and-`starts_with` pattern from `exports::session_file_in`.

**Web** (`web/files.js`):
- a tree in the side panel;
- previews:
  - text and code with line numbers, loading more pages on scroll;
  - markdown through the existing renderer;
  - images;
  - PDFs in an `<iframe>` of the raw URL;
  - anything else as a download;
- a "Changed" tab with per-turn diffs through `diffBlock`;
- a "changed files" line at the end of each turn;
- `@` in the composer opens the search picker and inserts `@path`.

**Model hint:** a `before_agent_start` snippet in `pocketpi-control.ts` with dsh's @-path rule ("read it before claiming to have inspected it").

**iOS:**
- a Files screen from the title menu: a list, then a preview using QuickLook for images and PDFs and a text view for code;
- a Changed list with diffs;
- an `@` picker in the composer.

### 3.6 Terminal panel (web; server `src/term.rs`)

**Server:**
- the `portable-pty` crate;
- axum's `ws` feature;
- `GET /api/term/ws?root=&id=`:
  - passes `guard`;
  - requires `Origin` to match `Host`, because a WebSocket upgrade is a GET and skips the `X-Pocketpi` check;
  - text frames carry `{type:"input"|"resize"}`, binary frames carry output;
- limits: at most 8 terminals, an output replay ring of 256 KiB for reattach, terminals closed after 2 h idle with nothing attached;
- the shell is the user's `$SHELL`, started in the project folder.

**Web** (`web/term.js`):
- vendored xterm.js and its fit addon (MIT), embedded and loaded lazily on first open;
- terminal tabs in the side panel;
- the terminal id is saved in `localStorage` so a reload reattaches;
- typed input is never replayed after a reconnect.

**iOS:** not in this plan. SwiftTerm could add it later on the same endpoint.

### 3.7 Titles and turn outline

**Titles:** `auto_title` already names a chat after its first reply. Add:
- **Re-titling:** check again after the 3rd and 10th user prompts, sending the current title with dsh's "return it unchanged unless the topic changed" rules.
  - Only chats whose title pocketpi made are re-titled. A user rename sets `titlePinned` in `chat_state`, and the iOS and web rename paths set it.
- Send the input as a JSON array (dsh's framing), and refuse rather than truncate input over 4 KiB.

**Outline:** `GET /api/sessions/outline?path=` returns `[{entryId, prompt (50 chars), response (120 chars)}]` for the active branch. It is read from the session file and cached by mtime + size like `read_meta`.
- Web: an Outline sheet from the title button. Tapping a turn scrolls to it, and with paging it loads that turn.
- iOS: the same, from the title menu.

## 4. Order of work

Each wave runs its parallel parts in separate git worktrees, as `pp/d*` branches, and they don't share files. Each part brings its own tests and both clients. A wave is finished only when all of these pass:
- `cargo test`;
- `node --check web/*.js`;
- `ios/test-linux.sh`;
- a code review;
- a merge into master;
- one iOS CI run.

| Wave | Parallel parts | Main files |
|---|---|---|
| D0 | shared groundwork (§2), done alone | main.rs, index.html, app.js, ChatView.swift, PocketPiKit |
| D1 | **a** goal mode · **b** plan, todos and presets · **c** titles and outline | a: pocketpi-goal.ts, goal.js, GoalViews.swift · b: pocketpi-modes.ts, modes.js, ModesViews.swift · c: main.rs title code, outline.rs, outline.js, OutlineView.swift |
| D2 | **d** files panel · **e** terminal | d: files.rs, files.js, FilesViews.swift · e: term.rs, term.js, vendored xterm |
| D3 | **g** worktree per chat, done alone because it touches listing, projects and opening chats | chat_worktrees.rs, main.rs, projects.rs, sessions.rs, both clients' list code |

D1 comes first because it gives the most value with the least new infrastructure: everything is extensions plus UI. D3 comes last because it changes how chats are listed and opened.

## 5. Decisions (confirmed 2026-11-09)

- **Goal defaults:** 30 rounds and $5 per goal, changeable per goal and in Settings.
- **Default preset for new chats:** Auto, which is today's behaviour.
- **Worktree Merge** does a local `--no-ff` merge into the branch the worktree came from, with Open PR as a separate action.
- **Voice input:** dropped.
