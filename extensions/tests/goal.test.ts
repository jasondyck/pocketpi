// pocketpi-goal.ts with a fake pi: node --test extensions/tests/
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import goalExt, { costSince, goalFromEntries, readDefaults, roundPrompt } from "../pocketpi-goal.ts";
import { makeFake, type Fake } from "./goal-fake.ts";

// Defaults come from a private features.json.
const cfg = mkdtempSync(join(tmpdir(), "pp-goal-test-"));
process.env.XDG_CONFIG_HOME = cfg;
const setDefaults = (goal: any) => {
  mkdirSync(join(cfg, "pocketpi"), { recursive: true });
  writeFileSync(join(cfg, "pocketpi/features.json"), JSON.stringify(goal === undefined ? {} : { goal }));
};

let f: Fake;
async function start(): Promise<Fake> {
  const x = makeFake();
  goalExt(x.pi);
  await x.emit("session_start", { reason: "startup" });
  return x;
}
/** A message from the person (the input event pocketpi's prompt fires). */
const userSays = (text = "hello") => f.emit("input", { text, source: "rpc" });
/** A run that settles; costs are its assistant messages. */
async function settle(opts: { aborted?: boolean; stop?: string; cost?: number } = {}) {
  f.addAssistant(opts.cost ?? 0, opts.stop ?? "stop");
  await f.emit("message_end", { message: { role: "assistant", stopReason: opts.stop ?? "stop" } });
  f.idle = true;
  await f.emit("agent_settled", { aborted: !!opts.aborted });
}
/** The model's goal_update with the current id and revision. */
const update = (action: string, extra: any = {}) => {
  const s = f.status();
  return f.tool("goal_update", { goalId: s.id, revision: s.revision, action, ...extra });
};

beforeEach(async () => {
  setDefaults(undefined);
  f = await start();
});

test("defaults: 30 rounds and $5, overridden by features.json", () => {
  assert.deepEqual(readDefaults(), { maxRounds: 30, maxCost: 5 });
  setDefaults({ maxRounds: 4, maxCost: 1.5 });
  assert.deepEqual(readDefaults(), { maxRounds: 4, maxCost: 1.5 });
  setDefaults({ maxRounds: "x", maxCost: -1 });
  assert.deepEqual(readDefaults(), { maxRounds: 30, maxCost: 5 });
});

test("control: create, get, defaults, pause, resume, clear", async () => {
  setDefaults({ maxRounds: 7 });
  assert.deepEqual(await f.control("goal", { action: "get" }), { goal: null });
  assert.deepEqual(await f.control("goal", { action: "defaults" }), { maxRounds: 7, maxCost: 5 });
  const { goal } = await f.control("goal", { action: "create", objective: "  ship it  ", maxCost: 2 });
  assert.equal(goal.objective, "ship it");
  assert.equal(goal.phase, "active");
  assert.equal(goal.maxRounds, 7);
  assert.equal(goal.maxCost, 2);
  assert.equal(goal.armed, true);
  await f.tick();
  assert.equal(f.sent.length, 1, "create starts round 1 when idle");
  assert.match(f.sent[0], /^<goal_round>\nObjective: "ship it"\nRound: 1\/7\n/);
  assert.equal(f.status().rounds, 1);

  const p = await f.control("goal", { action: "pause" });
  assert.equal(p.goal.phase, "paused");
  assert.equal(p.goal.armed, false);
  const r = await f.control("goal", { action: "resume" });
  assert.equal(r.goal.phase, "active");
  assert.equal(r.goal.armed, true);
  await f.control("goal", { action: "clear" });
  assert.equal(f.status(), null);
  assert.equal(f.statuses[f.statuses.length - 1], undefined);
  assert.deepEqual(f.entries("pocketpi-goal").pop().data.cleared, true);
  await assert.rejects(f.control("goal", { action: "pause" }), /no goal/);
  await assert.rejects(f.control("goal", { action: "create", objective: " " }), /objective is required/);
  await assert.rejects(f.control("goal", { action: "bogus" }), /unknown action/);
});

test("control: edit changes objective and caps, checks a given revision", async () => {
  f.idle = false; // no round kicked
  await f.control("goal", { action: "create", objective: "a" });
  const rev = f.status().revision;
  const { goal } = await f.control("goal", { action: "edit", objective: "b", maxRounds: 3, maxCost: "0.5", revision: rev });
  assert.equal(goal.objective, "b");
  assert.equal(goal.maxRounds, 3);
  assert.equal(goal.maxCost, 0.5);
  assert.equal(goal.revision, rev + 1);
  await assert.rejects(f.control("goal", { action: "edit", objective: "c", revision: rev }), /stale revision/);
});

test("goal_update is compare-and-set on goalId and revision", async () => {
  await userSays("make the tests pass");
  await f.tool("goal_create", { objective: "tests pass" });
  const s = f.status();
  await assert.rejects(f.tool("goal_update", { goalId: "nope", revision: s.revision, action: "pause" }), /goalId doesn't match/);
  await assert.rejects(f.tool("goal_update", { goalId: s.id, revision: s.revision - 1, action: "pause" }), /stale revision/);
  await f.tool("goal_update", { goalId: s.id, revision: s.revision, action: "edit", objective: "all tests pass" });
  assert.equal(f.status().revision, s.revision + 1);
  // The same (now stale) revision is refused the second time.
  await assert.rejects(f.tool("goal_update", { goalId: s.id, revision: s.revision, action: "edit", objective: "x" }), /stale revision/);
  assert.equal(f.status().objective, "all tests pass");
});

test("authority: create, edit, pause, resume need a person's message this run", async () => {
  // No user input yet: like an automatic round.
  await assert.rejects(f.tool("goal_create", { objective: "x" }), /needs a message from the user/);
  await userSays();
  const c = await f.tool("goal_create", { objective: "x", maxRounds: 5 });
  assert.equal(c.details.goal.maxRounds, 5);
  assert.equal(c.details.goal.armed, true);
  await assert.rejects(f.tool("goal_create", { objective: "y" }), /already has a goal/);
  await settle(); // drives round 1; the run is automatic from here
  assert.equal(f.sent.length, 1);
  await f.emit("input", { text: f.sent[0], source: "extension" });
  for (const a of ["edit", "pause", "resume"]) await assert.rejects(update(a, { objective: "z" }), /needs a message from the user/);
  // A person's steer during the run grants it again.
  await userSays("please pause");
  await update("pause");
  assert.equal(f.status().phase, "paused");
});

test("complete is allowed from an automatic round and asks for a wrap-up", async () => {
  await f.control("goal", { action: "create", objective: "x" });
  await f.tick();
  await f.emit("input", { text: f.sent[0], source: "extension" });
  const r = await update("complete");
  assert.equal(f.status().phase, "complete");
  assert.equal(f.status().armed, false);
  assert.match(r.content[0].text, /<goal_complete>[\s\S]*Do not call any more tools/);
  await settle();
  assert.equal(f.sent.length, 1, "no round after complete");
});

test("complete in a person's turn has no wrap-up instruction", async () => {
  await userSays();
  await f.tool("goal_create", { objective: "x" });
  const r = await update("complete");
  assert.doesNotMatch(r.content[0].text, /goal_complete/);
});

test("blocked is refused before 3 rounds, then allowed with a reason", async () => {
  f.idle = false;
  await f.control("goal", { action: "create", objective: "x" });
  await f.tick(); // the create kick finds pi busy
  await settle(); // round 1
  await assert.rejects(update("blocked", { blockedReason: "no access" }), /refused before 3 goal rounds/);
  await settle(); // round 2
  await settle(); // round 3
  assert.equal(f.status().rounds, 3);
  await assert.rejects(update("blocked"), /needs a blockedReason/);
  const r = await update("blocked", { blockedReason: "no access" });
  assert.equal(f.status().phase, "blocked");
  assert.equal(f.status().blockedReason, "no access");
  assert.match(r.content[0].text, /<goal_blocked>/);
});

test("driver: runs only when active, armed, settled cleanly and not paused", async () => {
  f.idle = false;
  await f.control("goal", { action: "create", objective: "x" });
  await f.tick(); // the create kick finds pi busy
  await settle({ aborted: true });
  assert.equal(f.sent.length, 0, "aborted: no round");
  assert.equal(f.status().armed, false, "aborted: disarmed");
  await f.control("goal", { action: "resume" });
  await f.tick();
  assert.equal(f.sent.length, 1, "resume kicks a round");

  await settle({ stop: "error" });
  assert.equal(f.sent.length, 1, "error: left to subscription-fallback");
  assert.equal(f.status().armed, true, "error keeps it armed");
  await settle();
  assert.equal(f.sent.length, 2, "next clean settle continues");

  f.pending = true;
  await settle();
  assert.equal(f.sent.length, 2, "queued messages: no round");
  f.pending = false;

  await f.control("goal", { action: "pause" });
  await settle();
  assert.equal(f.sent.length, 2, "paused: no round");
  assert.match(f.sent[1], /Round: 2\/30/);
});

test("session_start disarms; a person's action re-arms", async () => {
  await f.control("goal", { action: "create", objective: "x" });
  await f.tick();
  assert.equal(f.sent.length, 1);
  // A resume / fork / reload: the same branch, a fresh extension instance.
  const branch = f.branch;
  f = makeFake();
  f.branch.push(...branch);
  goalExt(f.pi);
  await f.emit("session_start", { reason: "resume" });
  const s = f.status();
  assert.equal(s.phase, "active");
  assert.equal(s.armed, false);
  assert.equal(s.rounds, 1);
  await settle();
  assert.equal(f.sent.length, 0, "not driven while disarmed");
  await f.emit("input", { text: "/goal resume", source: "rpc" });
  await f.tick();
  assert.equal(f.status().armed, true);
  assert.equal(f.sent.length, 1);
  assert.match(f.sent[0], /Round: 2\/30/);

  // The same instance on session_start disarms too.
  await f.emit("session_start", { reason: "reload" });
  assert.equal(f.status().armed, false);
});

test("round cap blocks the goal with round-limit", async () => {
  f.idle = false;
  await f.control("goal", { action: "create", objective: "x", maxRounds: 2 });
  await f.tick(); // the create kick finds pi busy
  await settle();
  await settle();
  assert.equal(f.sent.length, 2);
  await settle();
  assert.equal(f.sent.length, 2);
  assert.equal(f.status().phase, "blocked");
  assert.equal(f.status().blockedReason, "round-limit");
  await assert.rejects(f.control("goal", { action: "resume" }), /raise the cap/);
  await f.control("goal", { action: "edit", maxRounds: 4 });
  await f.control("goal", { action: "resume" });
  await f.tick();
  assert.equal(f.sent.length, 3);
  assert.match(f.sent[2], /Round: 3\/4/);
});

test("cost cap blocks the goal with cost-limit, counting only cost since creation", async () => {
  f.addAssistant(100); // before the goal: not counted
  await new Promise((r) => setTimeout(r, 3));
  f.idle = false;
  await f.control("goal", { action: "create", objective: "x", maxCost: 1 });
  await f.tick(); // the create kick finds pi busy
  await settle({ cost: 0.4 });
  assert.equal(f.sent.length, 1);
  assert.equal(f.status().cost, 0.4);
  await settle({ cost: 0.7 });
  assert.equal(f.sent.length, 1);
  assert.equal(f.status().phase, "blocked");
  assert.equal(f.status().blockedReason, "cost-limit");
  await assert.rejects(f.control("goal", { action: "resume" }), /cost cap/);
});

test("state is rebuilt from the last entry on the branch; a tombstone clears it", () => {
  const e = (data: any) => ({ type: "custom", customType: "pocketpi-goal", data });
  const g = { id: "g1", revision: 1, objective: "a", phase: "active", rounds: 0, maxRounds: 3, maxCost: 1, createdAt: 0 };
  assert.equal(goalFromEntries([]), null);
  assert.equal(goalFromEntries([e(g), e({ ...g, revision: 2, objective: "b" })])!.objective, "b");
  assert.equal(goalFromEntries([e(g), e({ id: "g1", revision: 2, cleared: true })]), null);
  assert.equal(goalFromEntries([e(g), { type: "custom", customType: "other", data: {} }])!.id, "g1");
});

test("costSince sums assistant and usage cost after the start", () => {
  const t = Date.parse("2026-01-01T00:00:00Z");
  const msg = (ms: number, c: number, role = "assistant") => ({ type: "message", timestamp: new Date(ms).toISOString(), message: { role, timestamp: ms, usage: { cost: { total: c } } } });
  const entries = [msg(t - 1, 5), msg(t, 1), msg(t + 1, 2, "user"), { type: "usage", timestamp: new Date(t + 2).toISOString(), usage: { cost: { total: 0.5 } } }, { type: "message", timestamp: new Date(t + 3).toISOString(), message: { role: "assistant" } }];
  assert.equal(costSince(entries, t), 1.5);
});

test("typed /goal: status, create, control words only as the whole input", async () => {
  const r = await f.emit("input", { text: "/goal", source: "rpc" });
  assert.deepEqual(r[0], { action: "handled" });
  assert.match(f.notes.pop()!.msg, /No goal/);
  f.idle = false;
  await f.emit("input", { text: "/goal pause the deploy until monday", source: "rpc" });
  assert.equal(f.status().objective, "pause the deploy until monday");
  assert.equal(f.status().phase, "active");
  await f.emit("input", { text: "/goal pause", source: "rpc" });
  assert.equal(f.status().phase, "paused");
  await f.emit("input", { text: "/goal", source: "rpc" });
  assert.match(f.notes.pop()!.msg, /Goal \(paused\): pause the deploy/);
  await f.emit("input", { text: "/goal clear", source: "rpc" });
  assert.equal(f.status(), null);
  // Not ours.
  assert.deepEqual((await f.emit("input", { text: "/goals", source: "rpc" }))[0], { action: "continue" });
  assert.deepEqual((await f.emit("input", { text: "/goal x", source: "extension" }))[0], { action: "continue" });
});

test("system prompt section while a goal exists", async () => {
  const opts: any = { sections: { other: "keep" } };
  await f.emit("before_agent_start", { systemPromptOptions: opts });
  assert.equal(opts.sections.goal, undefined);
  f.idle = false;
  await f.control("goal", { action: "create", objective: "x" });
  await f.emit("before_agent_start", { systemPromptOptions: opts });
  assert.equal(opts.sections.other, "keep");
  assert.match(opts.sections.goal, /Mark complete only when the objective is actually achieved\. Mark blocked only after the same blocking condition persists for at least 3 consecutive goal rounds/);
});

test("round prompt matches dsh's text", () => {
  const p = roundPrompt({ id: "g", revision: 1, objective: 'say "hi"', phase: "active", rounds: 2, maxRounds: 9, maxCost: 1, createdAt: 0 });
  assert.ok(p.startsWith('<goal_round>\nObjective: "say \\"hi\\""\nRound: 2/9\n\nContinue working toward the objective in this same session.'));
  assert.ok(p.endsWith("If work remains, leave the goal active for the next round.\n</goal_round>"));
});
