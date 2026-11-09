// pocketpi-goal.ts: goal mode, pi keeps taking turns until a goal is met.
//
// pocketpi loads this into every normal chat pi with `-e`, after
// pocketpi-control.ts (src/main.rs FEATURE_EXTENSIONS; POCKETPI_GOAL=0 turns it off).
// Plan: docs/dsh-features-plan.md §3.1.
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
// How it works (dsh's design):
// - One goal per chat. Every change appends a full snapshot as a
//   "pocketpi-goal" entry with a bumped revision; the last one on the branch
//   wins, and clearing leaves a tombstone. Changes from the model are
//   compare-and-set on {goalId, revision}.
// - `armed` lives only in memory. session_start (startup, resume, fork,
//   reload), tree navigation and an aborted run disarm; only a person
//   (pp-goal control, a typed `/goal …`, or the model acting on a message
//   the person sent this run) arms it again.
// - When a run settles, the goal is active and armed, and the run neither
//   was aborted nor ended in an error (subscription-fallback.ts handles
//   those), the driver bumps `rounds` and sends the <goal_round> prompt.
//   Hitting maxRounds or maxCost blocks the goal ("round-limit" /
//   "cost-limit") instead.
// - The model reports progress with goal_get / goal_create / goal_update.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const REPLY = "pocketpi-control";
const ENTRY = "pocketpi-goal";
const STATUS = "pp-goal";
const BLOCKED_FLOOR = 3;
const DEFAULTS = { maxRounds: 30, maxCost: 5 };

export type Phase = "active" | "paused" | "blocked" | "complete";

export interface Goal {
  id: string;
  revision: number;
  objective: string;
  phase: Phase;
  rounds: number;
  maxRounds: number;
  maxCost: number;
  /** ms since epoch; cost is summed from assistant messages after this. */
  createdAt: number;
  blockedReason?: string | null;
}

type Handler = (args: any, ctx: any) => Promise<unknown> | unknown;

/** The goal defaults from ~/.config/pocketpi/features.json (key "goal"). */
export function readDefaults(): { maxRounds: number; maxCost: number } {
  const dir = process.env.XDG_CONFIG_HOME || join(homedir(), ".config");
  let g: any = {};
  try {
    g = JSON.parse(readFileSync(join(dir, "pocketpi/features.json"), "utf8"))?.goal ?? {};
  } catch {}
  return {
    maxRounds: posInt(g?.maxRounds) ?? DEFAULTS.maxRounds,
    maxCost: posNum(g?.maxCost) ?? DEFAULTS.maxCost,
  };
}

export function roundPrompt(g: Goal): string {
  return [
    "<goal_round>",
    `Objective: ${JSON.stringify(g.objective)}`,
    `Round: ${g.rounds}/${g.maxRounds}`,
    "",
    "Continue working toward the objective in this same session. Treat the current workspace, tool results, and durable session state as authoritative; inspect them instead of assuming earlier narration is still current. Make concrete progress and verify the result. Before claiming completion, gather evidence that the whole objective is achieved, read the current goal, and mark it complete. If work remains, leave the goal active for the next round.",
    "</goal_round>",
  ].join("\n");
}

const WRAP_UP = {
  complete:
    "<goal_complete>\nThe goal is now complete. Write the closing message for the user: the outcome and the evidence for it, stating only what this session establishes. Do not call any more tools.\n</goal_complete>",
  blocked:
    "<goal_blocked>\nThe goal is now blocked. Write the closing message for the user: what blocks it, what was tried and the evidence, stating only what this session establishes. Do not call any more tools.\n</goal_blocked>",
};

const SYSTEM_RULES =
  "Mark complete only when the objective is actually achieved. Mark blocked only after the same blocking condition persists for at least 3 consecutive goal rounds; difficulty, uncertainty or remaining work is not blocked.";

function posInt(v: unknown): number | undefined {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) && n >= 1 ? Math.floor(n) : undefined;
}
function posNum(v: unknown): number | undefined {
  const n = typeof v === "string" ? Number(v) : v;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : undefined;
}
function newId(): string {
  return "g" + Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
}
const text = (s: string, details: Record<string, unknown> = {}) => ({ content: [{ type: "text" as const, text: s }], details });

/** The last goal snapshot on a branch (null when there is none or it was cleared). */
export function goalFromEntries(entries: any[]): Goal | null {
  let g: Goal | null = null;
  for (const e of entries || []) {
    if (e?.type !== "custom" || e.customType !== ENTRY) continue;
    const d = e.data;
    g = d && !d.cleared && typeof d.id === "string" && typeof d.objective === "string" ? { ...d } : null;
  }
  return g;
}

/** Model cost on the branch since `since` (ms): assistant messages and usage entries. */
export function costSince(entries: any[], since: number): number {
  let total = 0;
  for (const e of entries || []) {
    let usage: any = null, at = Date.parse(e?.timestamp ?? "");
    if (e?.type === "message" && e.message?.role === "assistant") {
      usage = e.message.usage;
      if (typeof e.message.timestamp === "number") at = e.message.timestamp;
    } else if (e?.type === "usage") usage = e.usage;
    if (!usage || !(at >= since)) continue;
    const c = Number(usage.cost?.total);
    if (Number.isFinite(c)) total += c;
  }
  return total;
}

export default function (pi: ExtensionAPI) {
  let goal: Goal | null = null;
  let armed = false;
  // A person sent a message in the current run (the input event saw a
  // non-extension source). Reset when the run settles.
  let userTurn = false;
  // The last assistant message's stop reason ("error" leaves the turn to
  // subscription-fallback.ts).
  let lastStop = "";
  // The latest context, for setStatus / branch reads outside a handler.
  let lastCtx: any = null;

  const entries = (ctx: any): any[] => {
    const sm = ctx?.sessionManager;
    if (!sm) return [];
    return typeof sm.getBranch === "function" ? sm.getBranch() : sm.getEntries?.() ?? [];
  };
  const cost = (ctx: any) => (goal ? costSince(entries(ctx ?? lastCtx), goal.createdAt) : 0);

  const view = (ctx?: any) =>
    goal && {
      id: goal.id,
      revision: goal.revision,
      objective: goal.objective,
      phase: goal.phase,
      rounds: goal.rounds,
      maxRounds: goal.maxRounds,
      cost: Math.round(cost(ctx) * 1e6) / 1e6,
      maxCost: goal.maxCost,
      blockedReason: goal.blockedReason ?? null,
      armed: armed && goal.phase === "active",
    };

  const publish = (ctx?: any) => {
    const c = ctx ?? lastCtx;
    if (!c?.ui?.setStatus) return;
    const v = view(c);
    c.ui.setStatus(STATUS, v ? JSON.stringify(v) : undefined);
  };

  const remember = (ctx: any) => {
    if (ctx) lastCtx = ctx;
  };

  /** Writes the next snapshot (revision + 1) and publishes it. */
  const save = (next: Goal, ctx: any) => {
    goal = next;
    pi.appendEntry(ENTRY, { ...next });
    publish(ctx);
    return goal;
  };
  const change = (patch: Partial<Goal>, ctx: any) => save({ ...goal!, ...patch, revision: goal!.revision + 1 }, ctx);

  const rebuild = (ctx: any) => {
    remember(ctx);
    goal = goalFromEntries(entries(ctx));
    armed = false;
    userTurn = false;
    publish(ctx);
  };

  const create = (objective: string, opts: { maxRounds?: unknown; maxCost?: unknown }, ctx: any) => {
    const o = String(objective ?? "").trim();
    if (!o) throw new Error("objective is required");
    const d = readDefaults();
    const revision = goal ? goal.revision + 1 : 1;
    armed = true;
    return save(
      {
        id: newId(),
        revision,
        objective: o,
        phase: "active",
        rounds: 0,
        maxRounds: posInt(opts.maxRounds) ?? d.maxRounds,
        maxCost: posNum(opts.maxCost) ?? d.maxCost,
        createdAt: Date.now(),
        blockedReason: null,
      },
      ctx,
    );
  };

  const clear = (ctx: any) => {
    if (goal) pi.appendEntry(ENTRY, { id: goal.id, revision: goal.revision + 1, cleared: true });
    goal = null;
    armed = false;
    publish(ctx);
  };

  /** Blocks the goal with `reason` if a cap is reached; true when it did. */
  const capped = (ctx: any): boolean => {
    if (!goal) return false;
    if (goal.rounds >= goal.maxRounds) {
      armed = false;
      change({ phase: "blocked", blockedReason: "round-limit" }, ctx);
      return true;
    }
    if (cost(ctx) >= goal.maxCost) {
      armed = false;
      change({ phase: "blocked", blockedReason: "cost-limit" }, ctx);
      return true;
    }
    return false;
  };

  /** One goal round, when everything allows it. Returns whether it sent one. */
  const drive = (ctx: any): boolean => {
    if (!goal || goal.phase !== "active" || !armed) return false;
    if (ctx?.isIdle && !ctx.isIdle()) return false;
    if (ctx?.hasPendingMessages?.()) return false;
    if (capped(ctx)) return false;
    change({ rounds: goal.rounds + 1 }, ctx);
    pi.sendUserMessage(roundPrompt(goal));
    return true;
  };
  // After a person's action outside a run (control, typed /goal): start the
  // next round once the command or input handler has returned.
  const kick = (ctx: any) => setTimeout(() => drive(ctx), 0);

  // ------------------------------------------------------------ lifecycle
  pi.on("session_start", async (_e: any, ctx: any) => rebuild(ctx));
  pi.on("session_tree", async (_e: any, ctx: any) => rebuild(ctx));

  pi.on("message_end", async (e: any, ctx: any) => {
    remember(ctx);
    if (e?.message?.role !== "assistant") return;
    lastStop = e.message.stopReason || "";
    if (goal) publish(ctx); // cost moved
  });

  pi.on("agent_settled", async (e: any, ctx: any) => {
    remember(ctx);
    const stop = lastStop;
    lastStop = "";
    userTurn = false;
    if (!goal || goal.phase !== "active") return;
    if (e?.aborted) {
      // Never pick a goal back up on its own after the person stopped it.
      if (armed) {
        armed = false;
        publish(ctx);
      }
      return;
    }
    if (stop === "error") return;
    drive(ctx);
  });

  pi.on("before_agent_start", async (e: any, ctx: any) => {
    remember(ctx);
    if (!goal || !e?.systemPromptOptions) return;
    e.systemPromptOptions.sections = {
      ...(e.systemPromptOptions.sections || {}),
      goal:
        `This chat has a goal (${goal.phase}): ${JSON.stringify(goal.objective)}\n` +
        "Use goal_get to read it and goal_update to report on it. " +
        SYSTEM_RULES,
    };
  });

  // ------------------------------------------------------------ typed /goal
  pi.on("input", async (e: any, ctx: any) => {
    remember(ctx);
    if (e?.source === "extension") return { action: "continue" };
    const raw = String(e?.text ?? "").trim();
    const m = /^\/goal(?:\s+([\s\S]*))?$/.exec(raw);
    if (!m) {
      userTurn = true;
      return { action: "continue" };
    }
    const arg = (m[1] ?? "").trim();
    const say = (msg: string, type = "info") => ctx.ui?.notify?.(msg, type);
    try {
      if (!arg) {
        const v = view(ctx);
        say(
          v
            ? `Goal (${v.phase}${v.phase === "active" && !v.armed ? ", waiting for you to resume" : ""}${v.blockedReason ? `: ${v.blockedReason}` : ""}): ${v.objective}\nRound ${v.rounds}/${v.maxRounds} · $${v.cost.toFixed(2)} of $${v.maxCost}`
            : "No goal. Start one with /goal <objective>.",
        );
      } else if (arg === "pause" || arg === "resume" || arg === "clear") {
        runAction({ action: arg }, ctx);
        say(arg === "clear" ? "Goal cleared" : arg === "pause" ? "Goal paused" : "Goal resumed");
      } else {
        runAction({ action: "create", objective: arg }, ctx);
        say("Goal started");
      }
    } catch (err: any) {
      say(String(err?.message ?? err), "error");
    }
    return { action: "handled" };
  });

  // ------------------------------------------------------------ person's actions
  /** A person's goal action (control command or typed /goal). */
  const runAction = (args: any, ctx: any) => {
    remember(ctx);
    const action = args?.action ?? "get";
    if (["edit", "pause", "resume"].includes(action)) {
      if (!goal) throw new Error("this chat has no goal");
      if (args.id != null && args.id !== goal.id) throw new Error("that goal was replaced");
      if (args.revision != null && args.revision !== goal.revision) throw new Error(`stale revision: the goal is at revision ${goal.revision}`);
    }
    switch (action) {
      case "get":
        break;
      case "defaults":
        return readDefaults();
      case "create":
        create(args.objective, args, ctx);
        kick(ctx);
        break;
      case "edit": {
        const patch: Partial<Goal> = {};
        if (args.objective != null) {
          const o = String(args.objective).trim();
          if (!o) throw new Error("objective can't be empty");
          patch.objective = o;
        }
        if (args.maxRounds != null) patch.maxRounds = posInt(args.maxRounds) ?? goal!.maxRounds;
        if (args.maxCost != null) patch.maxCost = posNum(args.maxCost) ?? goal!.maxCost;
        change(patch, ctx);
        break;
      }
      case "pause":
        if (goal!.phase === "complete") throw new Error("the goal is complete");
        armed = false;
        change({ phase: "paused" }, ctx);
        break;
      case "resume":
        if (goal!.phase === "complete") throw new Error("the goal is complete; start a new one");
        if (goal!.rounds >= goal!.maxRounds) throw new Error(`the goal used all ${goal!.maxRounds} rounds; raise the cap first`);
        if (cost(ctx) >= goal!.maxCost) throw new Error(`the goal reached its $${goal!.maxCost} cost cap; raise the cap first`);
        armed = true;
        if (goal!.phase !== "active") change({ phase: "active", blockedReason: null }, ctx);
        else publish(ctx);
        kick(ctx);
        break;
      case "clear":
        clear(ctx);
        break;
      default:
        throw new Error(`unknown action: ${action}`);
    }
    return { goal: view(ctx) };
  };

  // Every /pp-* command parses "<reqId> [json]" and always replies, even when
  // it throws, so the server is never left waiting until its timeout.
  const command = (name: string, description: string, run: Handler) => {
    pi.registerCommand(name, {
      description: `pocketpi: ${description}`,
      handler: async (raw: string, ctx: any) => {
        const t = (raw || "").trim();
        const sp = t.indexOf(" ");
        const reqId = sp < 0 ? t : t.slice(0, sp);
        const rest = sp < 0 ? "" : t.slice(sp + 1).trim();
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

  // args {action: "get"|"create"|"edit"|"pause"|"resume"|"clear"|"defaults",
  //       objective?, maxRounds?, maxCost?, id?, revision?}
  command("pp-goal", "read or change this chat's goal", (args, ctx) => runAction(args ?? {}, ctx));

  // ------------------------------------------------------------ model tools
  const needUser = (what: string) => {
    if (!userTurn) throw new Error(`${what} needs a message from the user in this turn; automatic goal rounds can only mark the goal complete or blocked`);
  };

  pi.registerTool({
    name: "goal_get",
    label: "Read goal",
    description: "Read this chat's goal: objective, phase, rounds used, cost so far, and the id and revision that goal_update needs.",
    parameters: { type: "object", properties: {}, additionalProperties: false } as any,
    async execute(_id: string, _p: any, _s: any, _u: any, ctx: any) {
      remember(ctx);
      const v = view(ctx);
      return text(v ? JSON.stringify(v, null, 1) : "No goal in this chat.", { goal: v });
    },
  } as any);

  pi.registerTool({
    name: "goal_create",
    label: "Create goal",
    description:
      "Start a goal for this chat: pi then keeps taking rounds until it is complete. Use when the user's direct request is a long-running objective, not for single-turn work.",
    parameters: {
      type: "object",
      properties: {
        objective: { type: "string", description: "The whole objective, in the user's terms, with how to tell it is achieved." },
        maxRounds: { type: "integer", minimum: 1, description: "Round cap (defaults to the user's setting)." },
      },
      required: ["objective"],
      additionalProperties: false,
    } as any,
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      remember(ctx);
      needUser("goal_create");
      if (goal && (goal.phase === "active" || goal.phase === "paused")) {
        throw new Error(`this chat already has a goal (${goal.phase}); use goal_update to change it`);
      }
      create(p?.objective, { maxRounds: p?.maxRounds }, ctx);
      const v = view(ctx);
      return text(`Goal created.\n${JSON.stringify(v, null, 1)}`, { goal: v });
    },
  } as any);

  pi.registerTool({
    name: "goal_update",
    label: "Update goal",
    description:
      "Change this chat's goal. Pass the goalId and revision from goal_get (compare-and-set). Actions: edit (new objective), pause, resume, complete (only when the whole objective is achieved, with evidence), blocked (only after the same blocking condition persisted for 3 rounds; give blockedReason).",
    parameters: {
      type: "object",
      properties: {
        goalId: { type: "string" },
        revision: { type: "integer" },
        action: { type: "string", enum: ["edit", "pause", "resume", "complete", "blocked"] },
        objective: { type: "string" },
        blockedReason: { type: "string" },
      },
      required: ["goalId", "revision", "action"],
      additionalProperties: false,
    } as any,
    async execute(_id: string, p: any, _s: any, _u: any, ctx: any) {
      remember(ctx);
      if (!goal) throw new Error("this chat has no goal");
      if (p.goalId !== goal.id) throw new Error(`goalId doesn't match the current goal (${goal.id}); call goal_get`);
      if (p.revision !== goal.revision) throw new Error(`stale revision ${p.revision}: the goal is at revision ${goal.revision}; call goal_get`);
      const auto = !userTurn;
      switch (p.action) {
        case "edit": {
          needUser("edit");
          const o = String(p.objective ?? "").trim();
          if (!o) throw new Error("edit needs an objective");
          change({ objective: o }, ctx);
          break;
        }
        case "pause":
          needUser("pause");
          armed = false;
          change({ phase: "paused" }, ctx);
          break;
        case "resume":
          needUser("resume");
          if (goal.phase === "complete") throw new Error("the goal is complete");
          armed = true;
          change({ phase: "active", blockedReason: null }, ctx);
          break;
        case "complete":
          if (goal.phase === "complete") throw new Error("the goal is already complete");
          armed = false;
          change({ phase: "complete", blockedReason: null }, ctx);
          break;
        case "blocked": {
          if (goal.rounds < BLOCKED_FLOOR) {
            throw new Error(`blocked is refused before ${BLOCKED_FLOOR} goal rounds (this is round ${goal.rounds}); keep working on the objective`);
          }
          const reason = String(p.blockedReason ?? "").trim();
          if (!reason) throw new Error("blocked needs a blockedReason");
          armed = false;
          change({ phase: "blocked", blockedReason: reason }, ctx);
          break;
        }
        default:
          throw new Error(`unknown action: ${p.action}`);
      }
      const v = view(ctx);
      let msg = `Goal updated (${p.action}).\n${JSON.stringify(v, null, 1)}`;
      if (auto && (p.action === "complete" || p.action === "blocked")) msg += "\n\n" + WRAP_UP[p.action as "complete" | "blocked"];
      return text(msg, { goal: v });
    },
  } as any);
}
