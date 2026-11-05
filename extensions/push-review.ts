// push-review: a pi extension that reviews outgoing commits before the agent
// runs `git push`. The diff goes to a strong reviewer model via a one-shot
// `pi -p` (extensions disabled in the child, so it can't recurse). Serious
// problems block the push; the user can still choose "Push anyway".
//
// Settings (env): PI_PUSH_REVIEW=0 disables it, PI_PUSH_REVIEW_MODEL picks the
// reviewer (default opencode-go/deepseek-v4-pro).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const MODEL = process.env.PI_PUSH_REVIEW_MODEL || "opencode-go/deepseek-v4-pro";
const MAX_DIFF = 300_000;
const EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

const PROMPT = `You are a senior engineer doing the final review before commits are pushed to a shared remote.
Review ONLY the diff you are given. Report real problems a careful reviewer would stop a push for:
- bugs and logic errors, crashes, broken builds, obviously wrong code
- security holes (injection, auth bypass, unsafe input handling, path traversal)
- committed secrets or credentials (API keys, tokens, passwords, private keys, .env contents)
- data loss or destructive behaviour, risky migrations
- PRIVACY: if the repository is PUBLIC, personal details (personal emails, home directory paths, private hostnames, internal IPs, tailnet names) are high severity
Ignore style, naming, formatting, missing docs and matters of taste. Do not invent problems; if unsure, use low severity.
severity: "high" = must fix before pushing, "medium" = should fix soon, "low" = minor.
verdict: "block" if there is at least one high-severity issue, otherwise "pass".
Output ONLY JSON, no prose:
{"verdict":"pass|block","summary":"one sentence","issues":[{"severity":"high|medium|low","file":"path","line":0,"title":"short","detail":"what and why, and how to fix"}]}`;

type Issue = { severity: string; file?: string; line?: number; title: string; detail?: string };
type Review = { verdict: string; summary?: string; issues?: Issue[] };

/** Finds `git ... push` in a shell command; returns the -C dir if one is given. */
function findPush(command: string): { dir?: string } | null {
  for (const part of command.split(/&&|\|\||;|\||\n/)) {
    const m = part.match(/(?:^|\s)git((?:\s+-[Cc]\s+\S+|\s+--[\w-]+=\S+)*)\s+push\b(.*)$/);
    if (!m) continue;
    const args = m[2];
    if (/\s--dry-run\b|\s-n\b|\s--delete\b|\s-d\b/.test(args)) return null;
    const dir = m[1].match(/-C\s+(\S+)/)?.[1];
    return { dir: dir?.replace(/^["']|["']$/g, "") };
  }
  return null;
}

export default function (pi: ExtensionAPI) {
  if (process.env.PI_PUSH_REVIEW === "0") return;

  const git = async (cwd: string, args: string[], signal?: AbortSignal) => {
    const r = await pi.exec("git", ["-c", "core.fsmonitor=false", ...args], { cwd, signal, timeout: 20_000 });
    return { ok: r.code === 0, out: (r.stdout || "").trim() };
  };

  pi.on("tool_call", async (event, ctx) => {
    if (!isToolCallEventType("bash", event)) return;
    const push = findPush(event.input.command);
    if (!push) return;
    const cwd = push.dir ? resolve(ctx.cwd, push.dir) : ctx.cwd;
    const signal = ctx.signal;

    // Work out what is being pushed: HEAD against its upstream, else the
    // remote's default branch, else (new repo) everything.
    let base: string | null = null;
    const up = await git(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], signal);
    if (up.ok && up.out) base = up.out;
    if (!base) {
      const def = await git(cwd, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], signal);
      if (def.ok && def.out) base = def.out;
    }
    let from = EMPTY_TREE;
    if (base) {
      const mb = await git(cwd, ["merge-base", "HEAD", base], signal);
      if (mb.ok && mb.out) from = mb.out;
    }
    const range = from === EMPTY_TREE ? "HEAD" : `${from}..HEAD`;
    const log = await git(cwd, ["log", "--oneline", "--no-decorate", "-n", "50", range], signal);
    if (!log.ok) return; // not a git repo or no commits: let git report it
    if (!log.out) return; // nothing to push

    const exclude = [":(exclude)*.lock", ":(exclude)package-lock.json", ":(exclude)pnpm-lock.yaml", ":(exclude)yarn.lock", ":(exclude)*.min.js"];
    const stat = await git(cwd, ["diff", "--stat", from, "HEAD", "--", ".", ...exclude], signal);
    let diff = (await git(cwd, ["diff", "--no-color", "-U4", from, "HEAD", "--", ".", ...exclude], signal)).out;
    const truncated = diff.length > MAX_DIFF;
    if (truncated) diff = diff.slice(0, MAX_DIFF);
    const remote = (await git(cwd, ["remote", "get-url", "origin"], signal)).out;
    let visibility = "unknown";
    try {
      const v = await pi.exec("gh", ["repo", "view", "--json", "visibility", "-q", ".visibility"], { cwd, signal, timeout: 8000 });
      if (v.code === 0 && v.stdout.trim()) visibility = v.stdout.trim();
    } catch {}

    const dir = mkdtempSync(join(tmpdir(), "push-review-"));
    const file = join(dir, "push.diff");
    writeFileSync(file, `Repository: ${remote || cwd}\nVisibility: ${visibility}\n\nCommits being pushed:\n${log.out}\n\nFiles:\n${stat.out}\n\nDiff${truncated ? " (truncated)" : ""}:\n${diff}\n`);

    ctx.ui.notify(`Reviewing push with ${MODEL.split("/").pop()}…`, "info");
    let review: Review | null = null;
    let failure = "";
    try {
      const r = await pi.exec("pi", [
        "--no-session", "-p", "--model", MODEL, "--thinking", "high",
        "--no-tools", "--no-context-files", "--no-skills", "--no-extensions", "--no-prompt-templates",
        "--system-prompt", PROMPT, `@${file}`, "Review this push.",
      ], { cwd: dir, signal, timeout: 300_000 });
      const text = r.stdout || "";
      const a = text.indexOf("{"), b = text.lastIndexOf("}");
      if (a >= 0 && b > a) review = JSON.parse(text.slice(a, b + 1));
      else failure = (r.stderr || text || `exit ${r.code}`).slice(-400);
    } catch (e) {
      failure = String(e);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }

    if (!review) {
      if (ctx.hasUI && await ctx.ui.confirm("Push review failed", `The reviewer could not run:\n${failure}\n\nPush without a review?`)) return;
      return { block: true, reason: `Push review could not run (${failure.slice(0, 200)}). Ask the user before pushing.` };
    }

    const issues = (review.issues || []).filter((i) => i && i.title);
    const high = issues.filter((i) => i.severity === "high");
    const fmt = (i: Issue) => `- [${i.severity}] ${i.file ? `${i.file}${i.line ? `:${i.line}` : ""} ` : ""}${i.title}${i.detail ? ` — ${i.detail}` : ""}`;
    if (review.verdict !== "block" && !high.length) {
      const extra = issues.length ? ` (${issues.length} minor note${issues.length === 1 ? "" : "s"})` : "";
      ctx.ui.notify(`Push review passed${extra}: ${review.summary || "no blocking issues"}`, "info");
      return;
    }

    const list = (high.length ? high : issues).map(fmt).join("\n");
    if (ctx.hasUI) {
      const anyway = await ctx.ui.confirm(
        `Push review: ${high.length || issues.length} issue${(high.length || issues.length) === 1 ? "" : "s"}`,
        `${review.summary || ""}\n\n${list}\n\nPush anyway?`,
      );
      if (anyway) return;
    }
    return {
      block: true,
      reason: `Push blocked by pre-push review (${MODEL}).\n${review.summary || ""}\n${issues.map(fmt).join("\n")}\nFix the high-severity issues, commit, then push again. If you disagree with a finding, explain why to the user instead of pushing.`,
    };
  });
}
