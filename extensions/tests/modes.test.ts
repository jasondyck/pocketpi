// Tests for extensions/pocketpi-modes.ts with a fake pi (no model, no pi
// process). Run: node --test extensions/tests/
import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import modes, { isReadOnlyBash, prefixesToAllow, validateTodos, todosFromBranch, defaultPreset, PLAN_BLOCK, READ_ONLY_BLOCK } from "../pocketpi-modes.ts";
import { fakePi } from "./modes-fake.ts";

let cfg: string;
const oldXdg = process.env.XDG_CONFIG_HOME;
beforeEach(() => { cfg = mkdtempSync(join(tmpdir(), "pp-modes-")); process.env.XDG_CONFIG_HOME = cfg; });
afterEach(() => { rmSync(cfg, { recursive: true, force: true }); if (oldXdg === undefined) delete process.env.XDG_CONFIG_HOME; else process.env.XDG_CONFIG_HOME = oldXdg; });
const writeFeatures = (text: string) => { mkdirSync(join(cfg, "pocketpi"), { recursive: true }); writeFileSync(join(cfg, "pocketpi", "features.json"), text); };

async function start(setup?: (f: ReturnType<typeof fakePi>) => void) {
  const f = fakePi();
  modes(f.pi);
  setup?.(f);
  await f.emit("session_start", { reason: "startup" });
  return f;
}

describe("read-only bash allowlist", () => {
  const allowed = [
    "ls -la", "cat src/main.rs", "grep -rn foo src | head -20", "rg 'a|b' web", "git status", "git log --oneline -5",
    "git diff HEAD~1 -- src", "git -C ios show HEAD", "git branch", "git branch -a", "find . -name '*.ts'", "wc -l a b",
    "cd web && ls", "sed -n '1,20p' file", "head -5 a; tail -5 b", "ls 2>/dev/null", "grep x y 2>&1 | sort | uniq -c",
    "LC_ALL=C sort file", "jq .name package.json", "node --version", "echo 'a > b'", "npm ls", "git config --get user.name",
    "cat <file", "# a comment",
  ];
  const blocked = [
    "rm -rf x", "echo hi > file", "cat a >> b", "ls | tee out", "touch x", "mv a b", "git commit -m x", "git push",
    "git branch newbranch", "git branch -D old", "git -c core.pager=sh log", "find . -delete", "find . -exec rm {} ;",
    "sed -i s/a/b/ f", "sed -n '1w out' f", "sort -o out in", "npm install", "cargo build", "ls $(rm x)", "ls `rm x`",
    "echo \"$(rm x)\"", "cat <(ls)", "(cd x; rm y)", "./script.sh", "/bin/rm x", "env rm x", "GIT_PAGER=sh git log",
    "cat <<EOF\nx\nEOF", "ls && rm x", "ls || touch y", "ls & rm z", "xargs rm", "awk '{print > \"f\"}' x",
    "python3 -c 'import os'", "curl -o x http://e", "git stash", "uniq a b",
  ];
  for (const c of allowed) test(`allows ${JSON.stringify(c)}`, () => assert.equal(isReadOnlyBash(c), true));
  for (const c of blocked) test(`blocks ${JSON.stringify(c)}`, () => assert.equal(isReadOnlyBash(c), false));

  test("prefixes for 'Allow for this chat'", () => {
    assert.deepEqual(prefixesToAllow("npm install left-pad"), ["npm install"]);
    assert.deepEqual(prefixesToAllow("cd x && npm test && rm -rf dist"), ["npm test", "rm"]);
    assert.deepEqual(prefixesToAllow("FOO=1 cargo build --release | tail"), ["cargo build"]);
    assert.deepEqual(prefixesToAllow("echo hi > notes.txt"), ["echo"]);
    assert.equal(prefixesToAllow("ls $(rm x)"), null);
  });
});

describe("gate", () => {
  test("auto adds no gate", async () => {
    const f = await start();
    assert.equal(await f.toolCall("edit", { path: "a" }), undefined);
    assert.equal(await f.toolCall("bash", { command: "rm -rf x" }), undefined);
    assert.equal(f.dialogs.length, 0);
  });

  test("read-only blocks edits, writes and mutating bash, lets reads through", async () => {
    const f = await start();
    await f.control("mode", { preset: "read-only" });
    for (const [tool, input] of [["edit", { path: "a" }], ["write", { path: "b", content: "" }], ["bash", { command: "echo x > y" }], ["powershell", { command: "ls" }]] as const) {
      assert.deepEqual(await f.toolCall(tool, input), { block: true, reason: READ_ONLY_BLOCK });
    }
    assert.equal(await f.toolCall("bash", { command: "git log | head" }), undefined);
    assert.equal(await f.toolCall("read", { path: "a" }), undefined);
    assert.equal(f.dialogs.length, 0);
  });

  test("plan mode blocks like read-only with its own reason, under any preset, and blocks todo_write", async () => {
    const f = await start();
    await f.control("mode", { preset: "ask" });
    await f.control("plan", { on: true });
    assert.deepEqual(await f.toolCall("write", { path: "x" }), { block: true, reason: PLAN_BLOCK });
    assert.deepEqual(await f.toolCall("bash", { command: "npm install" }), { block: true, reason: PLAN_BLOCK });
    assert.equal(await f.toolCall("bash", { command: "ls" }), undefined);
    assert.equal((await f.toolCall("todo_write", { todos: [] }))?.block, true);
    assert.equal(f.dialogs.length, 0, "plan mode never asks");
  });

  test("ask: allow once, deny with a reason, dismiss", async () => {
    const f = await start();
    await f.control("mode", { preset: "ask" });
    f.answers.push("Allow once");
    assert.equal(await f.toolCall("edit", { path: "src/a.ts" }), undefined);
    assert.match(f.dialogs[0].title, /^Allow this edit\?\ntool : edit\npath : src\/a\.ts/);
    assert.deepEqual(f.dialogs[0].options, ["Allow once", "Allow for this chat", "Deny"]);
    f.answers.push("Allow once");
    assert.equal(await f.toolCall("edit", { path: "src/a.ts" }), undefined);
    assert.equal(f.dialogs.length, 2, "allow once asks again next time");

    f.answers.push("Deny", "use the existing helper");
    assert.deepEqual(await f.toolCall("bash", { command: "npm install x" }), { block: true, reason: "Denied by the user: use the existing helper" });
    assert.equal(f.dialogs.at(-1)!.method, "input");
    f.answers.push("Deny", "");
    assert.deepEqual(await f.toolCall("bash", { command: "npm install x" }), { block: true, reason: "Denied by the user." });

    f.answers.push(undefined);
    const r = await f.toolCall("write", { path: "b" });
    assert.equal(r.block, true);
    assert.equal(r.terminate, true);
    // Read-only commands never ask.
    const before = f.dialogs.length;
    assert.equal(await f.toolCall("bash", { command: "git diff" }), undefined);
    assert.equal(f.dialogs.length, before);
  });

  test("ask: commands it can't split only offer Allow once / Deny", async () => {
    const f = await start();
    await f.control("mode", { preset: "ask" });
    f.answers.push("Allow once");
    await f.toolCall("bash", { command: "echo $(date) > log" });
    assert.deepEqual(f.dialogs[0].options, ["Allow once", "Deny"]);
  });

  test("ask: 'Allow for this chat' persists per tool and per command prefix, and survives a restart", async () => {
    const f = await start();
    await f.control("mode", { preset: "ask" });
    f.answers.push("Allow for this chat");
    assert.equal(await f.toolCall("edit", { path: "a" }), undefined);
    assert.equal(await f.toolCall("edit", { path: "other" }), undefined);
    assert.equal(f.dialogs.length, 1);
    f.answers.push("Allow once");
    await f.toolCall("write", { path: "a" });
    assert.equal(f.dialogs.length, 2, "edit's allowance doesn't cover write");

    f.answers.push("Allow for this chat");
    assert.equal(await f.toolCall("bash", { command: "npm install a" }), undefined);
    assert.match(f.dialogs.at(-1)!.title, /`npm install`/);
    assert.equal(await f.toolCall("bash", { command: "npm install b && ls" }), undefined);
    assert.equal(f.dialogs.length, 3);
    f.answers.push("Allow once");
    await f.toolCall("bash", { command: "npm publish" });
    assert.equal(f.dialogs.length, 4, "another subcommand asks");

    assert.deepEqual(f.statusJSON("pp-mode").allow, { tools: ["edit"], bash: ["npm install"] });
    // A new pi on the same session file.
    const g = fakePi(); modes(g.pi); g.entries.push(...f.entries);
    await g.emit("session_start", { reason: "resume" });
    assert.equal(await g.toolCall("bash", { command: "npm install c" }), undefined);
    assert.equal(await g.toolCall("edit", { path: "z" }), undefined);
    assert.equal(g.dialogs.length, 0);
    // Clearing the allowances asks again.
    await g.control("mode", { clearAllow: true });
    g.answers.push("Allow once");
    await g.toolCall("edit", { path: "z" });
    assert.equal(g.dialogs.length, 1);
  });
});

describe("exit_plan_mode", () => {
  const plan = "# Add a flag\n\n- change a\n- test b";

  test("errors outside plan mode and for a plan without a title", async () => {
    const f = await start();
    let r = await f.runTool("exit_plan_mode", { plan });
    assert.equal(r.isError, true);
    assert.match(r.content[0].text, /Not in plan mode/);
    await f.control("plan", { on: true });
    r = await f.runTool("exit_plan_mode", { plan: "no title" });
    assert.equal(r.isError, true);
    assert.equal(f.dialogs.length, 0);
  });

  test("approve turns plan mode off", async () => {
    const f = await start();
    await f.control("plan", { on: true });
    f.answers.push("Approve");
    const r = await f.runTool("exit_plan_mode", { plan });
    assert.equal(r.isError, undefined);
    assert.equal(r.content[0].text, "Plan approved — plan mode exited; carry out the plan starting with your next step.");
    assert.equal(f.dialogs[0].title, `Approve this plan?\n\n${plan}`);
    assert.deepEqual(f.dialogs[0].options, ["Approve", "Keep planning"]);
    assert.equal(f.statusJSON("pp-mode").plan, false);
    assert.equal(f.modeEntries().at(-1)!.data.plan, false);
    assert.equal(await f.toolCall("edit", { path: "a" }), undefined);
  });

  test("keep planning returns the feedback as an error and stays in plan mode", async () => {
    const f = await start();
    await f.control("plan", { on: true });
    f.answers.push("Keep planning", "also cover iOS");
    const r = await f.runTool("exit_plan_mode", { plan });
    assert.equal(r.isError, true);
    assert.equal(r.terminate, undefined);
    assert.equal(r.content[0].text, "The user chose to keep planning; their feedback: also cover iOS");
    assert.equal(f.dialogs[1].title, "What should change?");
    assert.equal(f.statusJSON("pp-mode").plan, true);
  });

  test("a dismissed dialog keeps plan mode and ends the turn", async () => {
    const f = await start();
    await f.control("plan", { on: true });
    f.answers.push(undefined);
    const r = await f.runTool("exit_plan_mode", { plan });
    assert.equal(r.isError, true);
    assert.equal(r.terminate, true);
    assert.equal(f.statusJSON("pp-mode").plan, true);
  });
});

describe("plan mode entry points and prompts", () => {
  test("/plan, /plan <msg>, /plan off", async () => {
    const f = await start();
    await f.commands.plan.handler("", f.ctx);
    assert.equal(f.statusJSON("pp-mode").plan, true);
    assert.equal(f.userMessages.length, 0);
    await f.commands.plan.handler("off", f.ctx);
    assert.equal(f.statusJSON("pp-mode").plan, false);
    f.setIdle(false);
    await f.commands.plan.handler("add dark mode", f.ctx);
    assert.equal(f.statusJSON("pp-mode").plan, true);
    assert.deepEqual(f.userMessages, [{ text: "add dark mode", options: { deliverAs: "followUp" } }]);
  });

  test("pp-plan control with a message sends it", async () => {
    const f = await start();
    assert.deepEqual(await f.control("plan", { on: true, message: "plan the refactor" }), { preset: "auto", plan: true });
    assert.equal(f.userMessages[0].text, "plan the refactor");
    await assert.rejects(f.control("plan", {}), /on/);
    await assert.rejects(f.control("plan", { on: false, message: "x" }), /on: true/);
  });

  test("system prompt sections follow the mode", async () => {
    const f = await start();
    let s = await f.startPrompt();
    assert.deepEqual(s, {});
    await f.control("plan", { on: true });
    await f.control("mode", { preset: "read-only" });
    s = await f.startPrompt();
    assert.match(s.pocketpi_plan_mode, /exit_plan_mode/);
    assert.match(s.pocketpi_plan_mode, /decision-complete/);
    assert.equal(s.pocketpi_permissions, "Permission preset: read-only. Edits, writes and mutating shell commands are blocked; don't try to work around this.");
  });

  test("changing the preset steers the model once", async () => {
    const f = await start();
    await f.control("mode", { preset: "read-only" });
    await f.control("mode", { preset: "read-only" });
    await f.control("mode", { preset: "auto" });
    const notes = f.sent.map((s) => s.message.content);
    assert.deepEqual(notes, ["Permission preset changed from Auto to Read-only by the user.", "Permission preset changed from Read-only to Auto by the user."]);
    assert.ok(f.sent.every((s) => s.options.deliverAs === "steer"));
    await assert.rejects(f.control("mode", { preset: "yolo" }), /preset must be/);
  });
});

describe("todos", () => {
  test("validation", () => {
    assert.deepEqual(validateTodos({ todos: [{ content: "  a ", status: "pending" }] }), [{ content: "a", status: "pending" }]);
    assert.deepEqual(validateTodos({ todos: [] }), []);
    assert.throws(() => validateTodos({ todos: [{ content: " ", status: "pending" }] }), /non-empty/);
    assert.throws(() => validateTodos({ todos: [{ content: "a", status: "pending" }, { content: "a ", status: "completed" }] }), /Duplicate/);
    assert.throws(() => validateTodos({ todos: [{ content: "a", status: "in_progress" }, { content: "b", status: "in_progress" }] }), /one todo/);
    assert.throws(() => validateTodos({ todos: [{ content: "a", status: "done" }] }), /status/);
    assert.throws(() => validateTodos({ todos: [{ content: "a", status: "pending", id: 1 }] }), /unknown field/);
    assert.throws(() => validateTodos({ todos: [], extra: 1 }), /Unknown field/);
    assert.throws(() => validateTodos({}), /array/);
  });

  test("todo_write replaces the list, publishes it, and errors keep the old one", async () => {
    const f = await start();
    let r = await f.runTool("todo_write", { todos: [{ content: "a", status: "completed" }, { content: "b", status: "in_progress" }, { content: "c", status: "pending" }] });
    assert.equal(r.content[0].text, "Updated todo list: 1 pending, 1 in progress, 1 completed.");
    assert.deepEqual(f.statusJSON("pp-todo"), { todos: r.details.todos, done: 1, total: 3 });
    r = await f.runTool("todo_write", { todos: [{ content: "x", status: "in_progress" }, { content: "y", status: "in_progress" }] });
    assert.equal(r.isError, true);
    assert.equal(f.statusJSON("pp-todo").total, 3);
    assert.deepEqual(await f.control("todo"), { todos: f.statusJSON("pp-todo").todos, done: 1, total: 3 });
  });

  test("the next prompt clears the list, and a restart agrees", async () => {
    const f = await start();
    await f.runTool("todo_write", { todos: [{ content: "a", status: "pending" }] });
    await f.startPrompt();
    assert.equal(f.status.has("pp-todo"), false);
    const g = fakePi(); modes(g.pi); g.entries.push(...f.entries);
    await g.emit("session_start", { reason: "resume" });
    assert.equal(g.status.has("pp-todo"), false);
  });

  test("rebuilt from the branch on session_start and after tree navigation", async () => {
    const f = await start();
    await f.runTool("todo_write", { todos: [{ content: "one", status: "pending" }] });
    const afterFirst = [...f.entries];
    await f.runTool("todo_write", { todos: [{ content: "one", status: "completed" }, { content: "two", status: "in_progress" }] });
    assert.equal(f.statusJSON("pp-todo").total, 2);
    f.setBranch(afterFirst);
    await f.emit("session_tree", {});
    assert.deepEqual(f.statusJSON("pp-todo").todos, [{ content: "one", status: "pending" }]);
    f.setBranch([]);
    await f.emit("session_tree", {});
    assert.equal(f.status.has("pp-todo"), false);

    const g = fakePi(); modes(g.pi); g.entries.push(...f.entries); g.setBranch(afterFirst);
    await g.emit("session_start", { reason: "resume" });
    assert.equal(g.statusJSON("pp-todo").total, 1);
    assert.deepEqual(todosFromBranch(f.entries).map((t) => t.content), ["one", "two"]);
  });
});

describe("state and defaults", () => {
  test("restored on session_start: the last mode entry wins", async () => {
    const f = await start((f) => {
      f.pi.appendEntry("pocketpi-mode", { preset: "ask", plan: true, allow: { tools: [], bash: [] } });
      f.pi.appendEntry("pocketpi-mode", { preset: "read-only", plan: false, allow: { tools: ["edit"], bash: [] } });
    });
    assert.deepEqual(f.statusJSON("pp-mode"), { preset: "read-only", plan: false, allow: { tools: ["edit"], bash: [] } });
    assert.equal((await f.control("mode")).isDefault, false);
  });

  test("default preset from features.json", async () => {
    assert.equal(defaultPreset(), "auto", "missing file");
    writeFeatures("{not json");
    assert.equal(defaultPreset(), "auto", "invalid JSON");
    writeFeatures(JSON.stringify({ modes: { defaultPreset: "yolo" } }));
    assert.equal(defaultPreset(), "auto", "unknown preset");
    writeFeatures(JSON.stringify({ goal: {} }));
    assert.equal(defaultPreset(), "auto", "no modes key");
    writeFeatures(JSON.stringify({ modes: { defaultPreset: "ask" } }));
    assert.equal(defaultPreset(), "ask");

    const f = await start();
    assert.equal(f.statusJSON("pp-mode").preset, "ask");
    assert.equal((await f.control("mode")).isDefault, true);
    assert.equal(f.modeEntries().length, 0);
    // The first prompt pins it, so changing the default later leaves this chat alone.
    await f.startPrompt();
    assert.equal(f.modeEntries().at(-1)!.data.preset, "ask");
    writeFeatures(JSON.stringify({ modes: { defaultPreset: "auto" } }));
    const g = fakePi(); modes(g.pi); g.entries.push(...f.entries);
    await g.emit("session_start", { reason: "resume" });
    assert.equal(g.statusJSON("pp-mode").preset, "ask");
    // A chat with an entry ignores the default.
    writeFeatures(JSON.stringify({ modes: { defaultPreset: "read-only" } }));
    const h = await start((h) => h.pi.appendEntry("pocketpi-mode", { preset: "auto", plan: false }));
    assert.equal(h.statusJSON("pp-mode").preset, "auto");
  });
});
