// pocketpi-modes.ts: plan mode, the todo list and permission presets.
//
// pocketpi loads this into every normal chat pi with `-e`, after
// pocketpi-control.ts (src/main.rs FEATURE_EXTENSIONS; POCKETPI_MODES=0 turns it off).
// Plan: docs/dsh-features-plan.md §3.2 and §3.3.
//
// Conventions shared with pocketpi-control.ts:
// - Clients run commands through `POST /api/s/{key}/control {command, args}`;
//   the server sends "/pp-<command> <reqId> [json]" and waits for the reply
//   entry {type:"custom", customType:"pocketpi-control", data:{reqId, ok, data|error}}.
//   Add a command name to CONTROL_COMMANDS in src/main.rs to allow it.
// - State the chat must keep goes in custom entries (`pi.appendEntry`) named
//   "pocketpi-*" and is rebuilt on `session_start`, so a restart, resume or
//   fork keeps it. The server hides "pocketpi-*" entries from get_entries.
// - Clients learn the state through `ctx.ui.setStatus("pp-<key>", JSON)`: it
//   is replayed in pocketpi_hello, and clients that know the key draw it
//   natively (web: pp.status[key]; iOS: ExtensionUIState.status).
//
// What lives where:
// - "pocketpi-mode" entries hold the whole mode snapshot {preset, plan, allow};
//   the last one in the session file wins (a mode belongs to the chat, not to
//   a branch, so moving around the tree doesn't change it). A chat without one
//   takes `modes.defaultPreset` from ~/.config/pocketpi/features.json, and the
//   first prompt writes that down so a later change of the default doesn't
//   loosen a chat that already ran under a stricter one.
// - The todo list lives in todo_write's result `details`, so it follows the
//   branch (pi's examples/extensions/todo.ts). A "pocketpi-todo" entry
//   {cleared:true} marks where a new prompt emptied it.
// - The tool list never changes between modes (pi's prompt cache stays warm):
//   exit_plan_mode and todo_write are always registered, and the gate below
//   blocks what a mode doesn't allow.
//
// Gate ordering: pi loads `-e` extensions before the globally configured
// ones (resource-loader.js: mergePaths(cliExtensions, configured)) and
// ExtensionRunner.emitToolCall stops at the first handler that blocks. So
// this gate runs BEFORE @gotgenes/pi-permission-system's: a call this gate
// blocks never reaches gotgenes (no gotgenes prompt pops first), and a call
// this gate lets through (Auto, or "Allow once"/"Allow for this chat" under
// Ask) still goes through gotgenes, whose asks and denies stay in force.
// Under Ask that can mean two questions for one command (ours, then a
// gotgenes rule's); harmless, and only for commands gotgenes asks about.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const REPLY = "pocketpi-control";
const MODE_ENTRY = "pocketpi-mode";
const TODO_ENTRY = "pocketpi-todo";
const NOTE = "pocketpi-mode-note";

export type Preset = "auto" | "ask" | "read-only";
export const PRESETS: Preset[] = ["auto", "ask", "read-only"];
const LABEL: Record<Preset, string> = { auto: "Auto", ask: "Ask", "read-only": "Read-only" };

export type Allow = { tools: string[]; bash: string[] };
export type ModeState = { preset: Preset; plan: boolean; allow: Allow };
export type TodoStatus = "pending" | "in_progress" | "completed";
export type Todo = { content: string; status: TodoStatus };

export const PLAN_BLOCK = "plan mode: read-only (approve a plan with exit_plan_mode first)";
export const READ_ONLY_BLOCK =
  "permission preset read-only: edits, writes and mutating shell commands are blocked; don't try to work around this";

type Handler = (args: any, ctx: any) => Promise<unknown> | unknown;

// ---------------------------------------------------------------- defaults

/** `modes.defaultPreset` from features.json (src/features.rs); "auto" when
 *  the file, the key or the value is missing or not valid. */
export function defaultPreset(): Preset {
  try {
    const dir = process.env.XDG_CONFIG_HOME || join(homedir(), ".config");
    const all = JSON.parse(readFileSync(join(dir, "pocketpi", "features.json"), "utf8"));
    const p = all?.modes?.defaultPreset;
    return PRESETS.includes(p) ? p : "auto";
  } catch {
    return "auto";
  }
}

// ---------------------------------------------------------------- shell parsing

/** One command of a pipeline or list: its words, quotes removed. */
export type ShellParse = {
  segments: string[][];
  /** Output redirections and their targets (">" "out.txt", ">>" "&2"). */
  redirects: { op: string; target: string }[];
  /** Something that runs code we can't see: $( ), backticks, <( ), ( ), here-docs. */
  opaque: boolean;
};

/** A small POSIX-ish lexer: enough to split `a | b && c; d`, see redirections
 *  and spot command substitution. Anything it doesn't follow is `opaque`. */
export function parseShell(src: string): ShellParse {
  const segments: string[][] = [];
  const redirects: { op: string; target: string }[] = [];
  let opaque = false;
  let words: string[] = [];
  let buf = "";
  let inWord = false;
  let quoted = false;
  let pendingRedirect: string | null = null; // op waiting for its target word
  let pendingInput = false; // "<" target: just skip it

  const endWord = () => {
    if (!inWord) return;
    if (pendingRedirect) { redirects.push({ op: pendingRedirect, target: buf }); pendingRedirect = null; }
    else if (pendingInput) pendingInput = false;
    else words.push(buf);
    buf = ""; inWord = false; quoted = false;
  };
  const endSegment = () => {
    endWord();
    if (pendingRedirect) { redirects.push({ op: pendingRedirect, target: "" }); pendingRedirect = null; }
    if (words.length) segments.push(words);
    words = [];
  };

  let i = 0;
  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];
    if (c === "\\") {
      if (n === "\n") { i += 2; continue; }
      buf += n ?? ""; inWord = true; i += 2; continue;
    }
    if (c === "'") {
      const j = src.indexOf("'", i + 1);
      if (j < 0) { opaque = true; buf += src.slice(i + 1); inWord = true; break; }
      buf += src.slice(i + 1, j); inWord = true; quoted = true; i = j + 1; continue;
    }
    if (c === '"') {
      let j = i + 1;
      while (j < src.length && src[j] !== '"') {
        if (src[j] === "\\" && j + 1 < src.length) { buf += src[j + 1]; j += 2; continue; }
        if (src[j] === "`" || (src[j] === "$" && src[j + 1] === "(")) opaque = true;
        buf += src[j]; j++;
      }
      if (j >= src.length) opaque = true;
      inWord = true; quoted = true; i = j + 1; continue;
    }
    if (c === "`") { opaque = true; i++; continue; }
    if (c === "$" && n === "(") { opaque = true; i += 2; continue; }
    if (c === "#" && !inWord) {
      while (i < src.length && src[i] !== "\n") i++;
      continue;
    }
    if (c === " " || c === "\t") { endWord(); i++; continue; }
    if (c === "\n" || c === ";") { endSegment(); i++; continue; }
    if (c === "|") { endSegment(); i += n === "|" || n === "&" ? 2 : 1; continue; }
    if (c === "&") {
      if (n === "&") { endSegment(); i += 2; continue; }
      if (n === ">") { // &> and &>> : both streams to a file
        endWord();
        const op = src[i + 2] === ">" ? "&>>" : "&>";
        pendingRedirect = op; i += op.length; continue;
      }
      endSegment(); i++; continue; // background
    }
    if (c === "(" || c === ")" || c === "{" && !inWord && (n === " " || n === "\n")) { opaque = true; endSegment(); i++; continue; }
    if (c === ">" || c === "<") {
      // "2>" / "0<": a bare number right before is the fd, not a word.
      if (inWord && !quoted && /^\d+$/.test(buf)) { buf = ""; inWord = false; }
      else endWord();
      if (n === "(") { opaque = true; i += 2; continue; } // process substitution
      if (c === "<") {
        if (n === "<") { opaque = true; i += src[i + 2] === "<" ? 3 : 2; continue; } // here-doc / here-string
        if (n === "&") { pendingInput = true; i += 2; continue; }
        pendingInput = true; i++; continue;
      }
      let op = ">";
      if (n === ">") op = ">>";
      else if (n === "|") op = ">|";
      i += op.length;
      if (src[i] === "&") { // >&2, >&-
        let t = "&"; i++;
        while (i < src.length && /[0-9-]/.test(src[i])) t += src[i++];
        redirects.push({ op, target: t });
        continue;
      }
      pendingRedirect = op;
      continue;
    }
    buf += c; inWord = true; i++;
  }
  endSegment();
  if (pendingInput) pendingInput = false;
  return { segments, redirects, opaque };
}

const HARMLESS_TARGET = /^(\/dev\/null|\/dev\/stdout|\/dev\/stderr|&[0-9]*-?)$/;
const ENV_OK = /^(LC_[A-Z]+|LANG|LANGUAGE|TZ|NO_COLOR|CLICOLOR|COLUMNS|TERM|FORCE_COLOR)=/;
const ASSIGN = /^[A-Za-z_][A-Za-z0-9_]*=/;

type Check = (args: string[]) => boolean;
const ANY: Check = () => true;
const NONE: Check = (a) => a.length === 0;
/** No argument matches `bad`. */
const without = (bad: RegExp): Check => (a) => !a.some((x) => bad.test(x));
const positional = (a: string[]) => a.filter((x) => !x.startsWith("-"));

const GIT_READ: Record<string, Check> = {
  status: ANY, log: without(/^--output/), diff: without(/^--output/), show: without(/^--output/),
  "rev-parse": ANY, "ls-files": ANY, "ls-tree": ANY, "ls-remote": ANY, blame: ANY, grep: without(/^(-O|--open-files-in-pager)/),
  describe: ANY, shortlog: ANY, "cat-file": ANY, "merge-base": ANY, "name-rev": ANY, "rev-list": ANY,
  "for-each-ref": ANY, "count-objects": ANY, whatchanged: ANY, "show-ref": ANY, "check-ignore": ANY, version: ANY, help: ANY,
  branch: (a) => !a.some((x) => /^(-[dDmMcCfu]|--(delete|move|copy|force|set-upstream|unset-upstream|edit-description))/.test(x))
    && (positional(a).length === 0 || a.some((x) => /^(--list|-l|--contains|--no-contains|--merged|--no-merged|--points-at)$/.test(x))),
  tag: (a) => positional(a).length === 0 || a.some((x) => /^(-l|--list|--contains|--points-at|--merged|--no-merged)$/.test(x)),
  remote: (a) => a.length === 0 || a.every((x) => x === "-v" || x === "--verbose") || ["show", "get-url"].includes(a[0]),
  config: (a) => a.some((x) => /^(--get|--get-all|--get-regexp|--list|-l)$/.test(x)),
  stash: (a) => a[0] === "list" || a[0] === "show",
  worktree: (a) => a[0] === "list",
  reflog: (a) => a.length === 0 || a[0] === "show" || a[0].startsWith("-"),
};

function gitReadOnly(args: string[]): boolean {
  let i = 0;
  // Global options: -C <dir> and --no-pager only (-c could set a pager or hook to run).
  while (i < args.length && args[i].startsWith("-")) {
    if (args[i] === "-C") i += 2;
    else if (args[i] === "--no-pager" || args[i] === "--no-optional-locks") i += 1;
    else if (args[i] === "--version" || args[i] === "--help") return true;
    else return false;
  }
  const sub = args[i];
  const check = sub ? GIT_READ[sub] : undefined;
  return !!check && check(args.slice(i + 1));
}

const SAFE: Record<string, Check> = {
  cat: ANY, head: ANY, tail: ANY, nl: ANY, wc: ANY, cut: ANY, tr: ANY, column: ANY, rev: ANY, fold: ANY, expand: ANY,
  grep: ANY, egrep: ANY, fgrep: ANY, rg: without(/^--pre/), ag: ANY,
  ls: ANY, pwd: ANY, echo: ANY, printf: ANY, true: ANY, false: ANY, test: ANY, "[": ANY, cd: ANY,
  tree: without(/^(-o|--output)/), sort: without(/^(-o|--output)/), uniq: (a) => positional(a).length <= 1,
  diff: ANY, cmp: ANY, comm: ANY, file: ANY, stat: ANY, du: ANY, df: ANY,
  which: ANY, whereis: ANY, type: ANY, command: (a) => a[0] === "-v" || a[0] === "-V",
  printenv: ANY, env: NONE, uname: ANY, whoami: ANY, id: ANY, groups: ANY, hostname: NONE, nproc: ANY, uptime: ANY, free: ANY, ps: ANY,
  date: without(/^(-s|--set)/), basename: ANY, dirname: ANY, realpath: ANY, readlink: ANY,
  md5sum: ANY, sha1sum: ANY, sha256sum: ANY, sha512sum: ANY, cksum: ANY, b2sum: ANY, od: ANY, hexdump: ANY, strings: ANY,
  jq: ANY,
  find: without(/^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/),
  fd: without(/^(-x|--exec|-X|--exec-batch)$/),
  // sed prints unless -i, or a w/W/e command in the script, writes or runs something.
  sed: (a) => !a.some((x) => /^-[a-zA-Z]*i/.test(x) || x.startsWith("--in-place") || (!x.startsWith("-") && /(^|[;{}\s\d\/$!])[wWe](\s|$)|\/w\s/.test(x))),
  git: gitReadOnly,
  npm: (a) => ["ls", "list", "view", "info", "outdated", "explain", "why", "help", "--version", "-v"].includes(a[0]) || (a[0] === "config" && (a[1] === "get" || a[1] === "list")),
  cargo: (a) => ["tree", "metadata", "--version", "-V", "help"].includes(a[0]),
};

/** True when one command of a pipeline only reads. */
function segmentReadOnly(words: string[]): boolean {
  let i = 0;
  while (i < words.length && ASSIGN.test(words[i])) {
    if (!ENV_OK.test(words[i])) return false;
    i++;
  }
  const cmd = words[i];
  if (cmd === undefined) return true; // only harmless assignments
  if (cmd.includes("/") || cmd.includes("$")) return false;
  const args = words.slice(i + 1);
  const check = SAFE[cmd];
  if (check) return check(args);
  // `anything --version` asks a program on PATH for its version.
  return args.length === 1 && (args[0] === "--version" || args[0] === "-V");
}

/** The read-only allowlist plan mode and the read-only preset allow. */
export function isReadOnlyBash(command: string): boolean {
  const p = parseShell(command);
  if (p.opaque) return false;
  if (p.redirects.some((r) => !HARMLESS_TARGET.test(r.target))) return false;
  return p.segments.every(segmentReadOnly);
}

// Tools whose second word picks what they do ("git push", "npm install").
const SUBCOMMAND_TOOLS = new Set([
  "git", "npm", "pnpm", "yarn", "bun", "deno", "npx", "cargo", "go", "docker", "podman", "kubectl", "pip", "pip3",
  "uv", "poetry", "make", "just", "gh", "brew", "apt", "apt-get", "systemctl", "journalctl", "swift", "xcodebuild",
  "dotnet", "mvn", "gradle", "rustup", "terraform", "helm", "pi",
]);

/** What "Allow for this chat" remembers for one command: its program, plus
 *  the subcommand for tools that have them ("npm install", "rm"). */
export function commandPrefix(words: string[]): string {
  let i = 0;
  while (i < words.length && ASSIGN.test(words[i])) i++;
  const cmd = words[i] ?? "";
  const sub = words[i + 1];
  if (SUBCOMMAND_TOOLS.has(cmd) && sub && /^[A-Za-z][\w:.-]*$/.test(sub)) return `${cmd} ${sub}`;
  return cmd;
}

/** The prefixes of the commands in `command` that aren't read-only and so
 *  need a yes; null when the command can't be split (substitutions,
 *  here-docs): those are only ever allowed once. */
export function prefixesToAllow(command: string): string[] | null {
  const p = parseShell(command);
  if (p.opaque) return null;
  const out: string[] = [];
  for (const s of p.segments) {
    if (segmentReadOnly(s)) continue;
    const pre = commandPrefix(s);
    if (pre && !out.includes(pre)) out.push(pre);
  }
  // `echo x > file` is all read-only programs writing a file: ask about the
  // first program, so "Allow for this chat" means something.
  if (!out.length && p.redirects.some((r) => !HARMLESS_TARGET.test(r.target)) && p.segments[0]) out.push(commandPrefix(p.segments[0]));
  return out;
}

// ---------------------------------------------------------------- todos

const TODO_STATUS: TodoStatus[] = ["pending", "in_progress", "completed"];

/** dsh's rules: the full list, trimmed non-empty unique content, at most one
 *  in progress, nothing but content and status. Throws with what's wrong. */
export function validateTodos(input: unknown): Todo[] {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new Error("Expected {todos: [...]}");
  const extra = Object.keys(input).filter((k) => k !== "todos");
  if (extra.length) throw new Error(`Unknown field(s): ${extra.join(", ")}`);
  const list = (input as any).todos;
  if (!Array.isArray(list)) throw new Error("todos must be an array");
  const seen = new Set<string>();
  const out: Todo[] = [];
  list.forEach((t: any, i: number) => {
    if (!t || typeof t !== "object" || Array.isArray(t)) throw new Error(`todos[${i}] must be an object`);
    const bad = Object.keys(t).filter((k) => k !== "content" && k !== "status");
    if (bad.length) throw new Error(`todos[${i}] has unknown field(s): ${bad.join(", ")}`);
    if (typeof t.content !== "string" || !t.content.trim()) throw new Error(`todos[${i}].content must be non-empty text`);
    const content = t.content.trim();
    if (!TODO_STATUS.includes(t.status)) throw new Error(`todos[${i}].status must be pending, in_progress or completed`);
    if (seen.has(content)) throw new Error(`Duplicate todo: "${content}"`);
    seen.add(content);
    out.push({ content, status: t.status });
  });
  if (out.filter((t) => t.status === "in_progress").length > 1) throw new Error("At most one todo can be in_progress");
  return out;
}

export function todoSummary(todos: Todo[]): string {
  const n = (s: TodoStatus) => todos.filter((t) => t.status === s).length;
  return `Updated todo list: ${n("pending")} pending, ${n("in_progress")} in progress, ${n("completed")} completed.`;
}

/** The list at the end of a branch: the last todo_write result, unless a
 *  later "pocketpi-todo" entry cleared it. */
export function todosFromBranch(branch: any[]): Todo[] {
  let todos: Todo[] = [];
  for (const e of branch) {
    if (e?.type === "custom" && e.customType === TODO_ENTRY && e.data?.cleared) todos = [];
    else if (e?.type === "message" && e.message?.role === "toolResult" && e.message.toolName === "todo_write" && !e.message.isError) {
      const d = e.message.details;
      if (d && Array.isArray(d.todos)) todos = d.todos;
    }
  }
  return todos;
}

// ---------------------------------------------------------------- prompts

const PLAN_POLICY = `Plan mode is on: you plan, you don't change anything.
- Stay in plan mode until exit_plan_mode succeeds. Only the user's approval in that tool's dialog ends it.
- A request to "implement X" means "plan implementing X".
- Agreement in conversation ("sounds good", "go ahead") approves nothing; only exit_plan_mode can.
- Explore with non-mutating reads only: read files, search, list, and run read-only shell commands. No edits, no writes, no formatters, no installs, no commits. Mutating calls are blocked.
- Don't use todo_write while planning; put the steps in the plan.
- The plan must be decision-complete: the goal, success criteria, the changes per subsystem (files and functions), edge cases, tests, and the assumptions you made. Someone should be able to carry it out without asking you anything.
- When the plan is ready, call exit_plan_mode with it as markdown starting with "# <title>". Make that call your only and final tool call of the turn. Never ask "should I proceed?" in prose.`;

const PRESET_LINE: Record<Preset, string> = {
  auto: "",
  ask: "Permission preset: ask. Each edit, write and mutating shell command needs the user's approval in a dialog; if the user denies one, respect it and adjust (the denial may carry a reason).",
  "read-only": "Permission preset: read-only. Edits, writes and mutating shell commands are blocked; don't try to work around this.",
};

const TODO_DESCRIPTION =
  "Record and update a task list to plan multi-step work and show progress; skip it for trivial single-step tasks. Add one todo per concrete step before you start. While work remains, keep exactly one todo in_progress. Mark each todo completed as soon as it is done.";

// ---------------------------------------------------------------- extension

export default function (pi: ExtensionAPI) {
  let mode: ModeState = { preset: "auto", plan: false, allow: { tools: [], bash: [] } };
  /** Whether the chat has written a mode entry yet (else it follows the default). */
  let hasEntry = false;
  let todos: Todo[] = [];
  let ui: any = null; // the latest ctx.ui, for status updates from commands

  // Every /pp-* command parses "<reqId> [json]" and always replies, even when
  // it throws, so the server is never left waiting until its timeout.
  const command = (name: string, description: string, run: Handler) => {
    pi.registerCommand(name, {
      description: `pocketpi: ${description}`,
      handler: async (raw: string, ctx: any) => {
        const text = (raw || "").trim();
        const sp = text.indexOf(" ");
        const reqId = sp < 0 ? text : text.slice(0, sp);
        const rest = sp < 0 ? "" : text.slice(sp + 1).trim();
        try {
          const args = rest ? JSON.parse(rest) : undefined;
          const data = await run(args, ctx);
          pi.appendEntry(REPLY, { reqId, ok: true, data: data ?? null });
        } catch (e: any) {
          pi.appendEntry(REPLY, { reqId, ok: false, error: String(e?.message ?? e) });
        }
      },
    });
  };

  const publish = (ctx?: any) => {
    const u = ctx?.ui ?? ui;
    if (ctx?.ui) ui = ctx.ui;
    if (!u) return;
    u.setStatus("pp-mode", JSON.stringify({ preset: mode.preset, plan: mode.plan, allow: mode.allow }));
    const done = todos.filter((t) => t.status === "completed").length;
    u.setStatus("pp-todo", todos.length ? JSON.stringify({ todos, done, total: todos.length }) : undefined);
  };

  const save = () => {
    pi.appendEntry(MODE_ENTRY, { preset: mode.preset, plan: mode.plan, allow: mode.allow });
    hasEntry = true;
  };

  const note = (content: string, ctx?: any) => {
    // A steer reaches a running turn before its next model call; when idle it
    // waits in the context for the next prompt.
    pi.sendMessage({ customType: NOTE, content, display: true }, { deliverAs: "steer" });
  };

  const setPreset = (preset: Preset, ctx?: any) => {
    if (!PRESETS.includes(preset)) throw new Error(`preset must be one of ${PRESETS.join(", ")}`);
    const old = mode.preset;
    if (old === preset && hasEntry) return;
    mode = { ...mode, preset };
    save();
    if (old !== preset) note(`Permission preset changed from ${LABEL[old]} to ${LABEL[preset]} by the user.`, ctx);
    publish(ctx);
  };

  const setPlan = (on: boolean, ctx?: any, tell = true) => {
    if (mode.plan === on) return;
    mode = { ...mode, plan: on };
    save();
    if (tell) note(on ? "Plan mode turned on by the user." : "Plan mode turned off by the user.", ctx);
    publish(ctx);
  };

  const sendPrompt = (text: string, ctx: any) => {
    const idle = typeof ctx?.isIdle === "function" ? ctx.isIdle() : true;
    pi.sendUserMessage(text, idle ? undefined : { deliverAs: "followUp" });
  };

  const restore = (ctx: any) => {
    const entries: any[] = ctx.sessionManager.getEntries();
    const last = [...entries].reverse().find((e) => e?.type === "custom" && e.customType === MODE_ENTRY);
    const d = last?.data;
    hasEntry = !!d;
    mode = {
      preset: d && PRESETS.includes(d.preset) ? d.preset : defaultPreset(),
      plan: !!d?.plan,
      allow: {
        tools: Array.isArray(d?.allow?.tools) ? d.allow.tools.filter((x: unknown) => typeof x === "string") : [],
        bash: Array.isArray(d?.allow?.bash) ? d.allow.bash.filter((x: unknown) => typeof x === "string") : [],
      },
    };
    todos = todosFromBranch(ctx.sessionManager.getBranch());
    publish(ctx);
  };

  pi.on("session_start", async (_e: any, ctx: any) => restore(ctx));
  pi.on("session_tree", async (_e: any, ctx: any) => {
    todos = todosFromBranch(ctx.sessionManager.getBranch());
    publish(ctx);
  });

  pi.on("before_agent_start", async (event: any, ctx: any) => {
    if (event.messageType === "user") {
      // The chat runs under its default from now on, even if the default changes.
      if (!hasEntry) save();
      if (todos.length) {
        todos = [];
        pi.appendEntry(TODO_ENTRY, { cleared: true });
      }
    }
    const sections = event.systemPromptOptions?.sections;
    if (sections) {
      if (mode.plan) sections.pocketpi_plan_mode = PLAN_POLICY;
      else delete sections.pocketpi_plan_mode;
      if (PRESET_LINE[mode.preset]) sections.pocketpi_permissions = PRESET_LINE[mode.preset];
      else delete sections.pocketpi_permissions;
    }
    publish(ctx);
  });

  // ------------------------------------------------------------ the gate

  const ask = async (ctx: any, title: string, canRemember: boolean) => {
    if (!ctx.hasUI) return { block: true, reason: "permission preset ask: no one to ask (no UI)" };
    const options = canRemember ? ["Allow once", "Allow for this chat", "Deny"] : ["Allow once", "Deny"];
    const choice = await ctx.ui.select(title, options);
    if (choice === "Allow once" || choice === "Allow for this chat") return { allow: choice };
    if (choice === "Deny") {
      const why = (await ctx.ui.input("Why not? (optional)", "A reason for pi"))?.trim();
      return { block: true, reason: why ? `Denied by the user: ${why}` : "Denied by the user." };
    }
    // Dismissed: nobody is answering, so stop the turn instead of retrying.
    return { block: true, reason: "Denied: the user dismissed the permission dialog.", terminate: true };
  };

  pi.on("tool_call", async (event: any, ctx: any) => {
    const name = event.toolName;
    if (mode.plan && name === "todo_write") {
      return { block: true, reason: "plan mode: don't keep a todo list while planning; put the steps in the plan" };
    }
    const strict = mode.plan || mode.preset === "read-only";
    if (!strict && mode.preset !== "ask") return undefined;
    const reason = mode.plan ? PLAN_BLOCK : READ_ONLY_BLOCK;

    if (name === "edit" || name === "write") {
      if (strict) return { block: true, reason };
      if (mode.allow.tools.includes(name)) return undefined;
      const path = String(event.input?.path ?? event.input?.file_path ?? "");
      const r: any = await ask(ctx, `Allow this ${name === "edit" ? "edit" : "write"}?\ntool : ${name}\npath : ${path}\nscope : "Allow for this chat" allows every ${name} in this chat`, true);
      if (r.block) return r;
      if (r.allow === "Allow for this chat") {
        mode = { ...mode, allow: { ...mode.allow, tools: [...mode.allow.tools, name] } };
        save(); publish(ctx);
      }
      return undefined;
    }

    if (name === "bash" || name === "powershell") {
      const cmd = String(event.input?.command ?? "");
      if (name === "bash" && isReadOnlyBash(cmd)) return undefined;
      if (strict) return { block: true, reason };
      const prefixes = name === "bash" ? prefixesToAllow(cmd) : null;
      if (prefixes && prefixes.length && prefixes.every((p) => mode.allow.bash.includes(p))) return undefined;
      const missing = prefixes ? prefixes.filter((p) => !mode.allow.bash.includes(p)) : null;
      const scope = missing && missing.length
        ? `\nscope : "Allow for this chat" allows every ${missing.map((p) => `\`${p}\``).join(", ")} command in this chat`
        : "";
      const r: any = await ask(ctx, `Allow this command?\ntool : ${name}\ncommand : ${cmd}${scope}`, !!(missing && missing.length));
      if (r.block) return r;
      if (r.allow === "Allow for this chat" && missing) {
        mode = { ...mode, allow: { ...mode.allow, bash: [...mode.allow.bash, ...missing] } };
        save(); publish(ctx);
      }
      return undefined;
    }
    return undefined;
  });

  // ------------------------------------------------------------ tools

  pi.registerTool({
    name: "exit_plan_mode",
    label: "Exit plan mode",
    description:
      "Present your finished plan for the user's approval and leave plan mode. Only works in plan mode. The plan is markdown starting with \"# <title>\": goal, success criteria, changes per subsystem, edge cases, tests, assumptions. Make this your only and final tool call of the turn.",
    // Plain JSON Schema: pi validates any JSON Schema (pi-ai validateToolArguments).
    parameters: {
      type: "object",
      properties: { plan: { type: "string", description: "The plan, markdown starting with \"# \"" } },
      required: ["plan"],
      additionalProperties: false,
    } as any,
    async execute(_id: string, params: any, _signal: any, _onUpdate: any, ctx: any) {
      const err = (text: string) => ({ content: [{ type: "text", text }], details: { plan: String(params?.plan ?? ""), outcome: "error" }, isError: true });
      if (!mode.plan) return err("Not in plan mode: there is nothing to exit. Carry on with the task.");
      const plan = String(params?.plan ?? "").trim();
      if (!plan.startsWith("# ")) return err("The plan must be markdown starting with a \"# <title>\" line.");
      if (!ctx.hasUI) return err("No one can approve the plan here (no UI). Stay in plan mode.");
      const choice = await ctx.ui.select(`Approve this plan?\n\n${plan}`, ["Approve", "Keep planning"]);
      if (choice === "Approve") {
        mode = { ...mode, plan: false };
        save(); publish(ctx);
        return {
          content: [{ type: "text", text: "Plan approved — plan mode exited; carry out the plan starting with your next step." }],
          details: { plan, outcome: "approved" },
        };
      }
      if (choice === "Keep planning") {
        const feedback = (await ctx.ui.input("What should change?", "Your feedback on the plan"))?.trim();
        return {
          content: [{ type: "text", text: `The user chose to keep planning; their feedback: ${feedback || "(none given)"}` }],
          details: { plan, outcome: "keep-planning", feedback: feedback || "" },
          isError: true,
        };
      }
      // Dismissed or cancelled: plan mode stays on and the turn ends.
      return {
        content: [{ type: "text", text: "The approval dialog was dismissed; plan mode stays on. Stop here and wait for the user." }],
        details: { plan, outcome: "dismissed" },
        isError: true,
        terminate: true,
      };
    },
  } as any);

  const todoItem = {
    type: "object",
    properties: {
      content: { type: "string", description: "One concrete step" },
      status: { type: "string", enum: TODO_STATUS },
    },
    required: ["content", "status"],
    additionalProperties: false,
  };
  pi.registerTool({
    name: "todo_write",
    label: "Todos",
    description: TODO_DESCRIPTION,
    parameters: {
      type: "object",
      properties: { todos: { type: "array", items: todoItem, description: "The full list; it replaces the previous one" } },
      required: ["todos"],
      additionalProperties: false,
    } as any,
    async execute(_id: string, params: any, _signal: any, _onUpdate: any, ctx: any) {
      let list: Todo[];
      try {
        list = validateTodos(params);
      } catch (e: any) {
        return { content: [{ type: "text", text: `Todo list not updated: ${e.message}` }], details: { todos, error: e.message }, isError: true };
      }
      todos = list;
      publish(ctx);
      return { content: [{ type: "text", text: todoSummary(list) }], details: { todos: list } };
    },
  } as any);

  // ------------------------------------------------------------ commands

  // Typed /plan: on; /plan <message>: on and send it; /plan off: off.
  pi.registerCommand("plan", {
    description: "Plan mode: /plan, /plan <message>, /plan off",
    handler: async (raw: string, ctx: any) => {
      const text = (raw || "").trim();
      if (text === "off") { setPlan(false, ctx); ctx.ui?.notify?.("Plan mode off"); return; }
      setPlan(true, ctx);
      if (text) sendPrompt(text, ctx);
      else ctx.ui?.notify?.("Plan mode on: pi plans and asks you to approve before changing anything");
    },
  });

  command("pp-mode", "read or set this chat's permission preset", (args, ctx) => {
    if (args?.preset !== undefined) setPreset(args.preset, ctx);
    if (args?.clearAllow) {
      mode = { ...mode, allow: { tools: [], bash: [] } };
      save(); publish(ctx);
    }
    publish(ctx);
    return { preset: mode.preset, plan: mode.plan, allow: mode.allow, isDefault: !hasEntry };
  });

  command("pp-plan", "turn plan mode on or off", (args, ctx) => {
    if (typeof args?.on !== "boolean") throw new Error("on (true or false) is required");
    const message = typeof args.message === "string" ? args.message.trim() : "";
    if (message && !args.on) throw new Error("a message can only go with on: true");
    setPlan(args.on, ctx);
    if (message) sendPrompt(message, ctx);
    return { preset: mode.preset, plan: mode.plan };
  });

  command("pp-todo", "read this chat's todo list", () => {
    const done = todos.filter((t) => t.status === "completed").length;
    return { todos, done, total: todos.length };
  });
}
