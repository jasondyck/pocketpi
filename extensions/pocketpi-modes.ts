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

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const REPLY = "pocketpi-control";

type Handler = (args: any, ctx: any) => Promise<unknown> | unknown;

export default function (pi: ExtensionAPI) {
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

  // Filled in by wave D1b. Until then the commands report the defaults.
  command("pp-mode", "read or set this chat's permission preset", () => ({ preset: "auto" }));
  command("pp-plan", "turn plan mode on or off", () => ({ plan: false }));
  command("pp-todo", "read this chat's todo list", () => ({ todos: null }));
}
