// pocketpi-control: the commands pocketpi needs that pi's RPC doesn't have.
//
// pocketpi loads this into every normal chat pi with `-e` (not the Chat tab's
// tool-less pis, not workflow stages). The server runs a command by sending
// the RPC `prompt` "/pp-<name> <reqId> [json args]"; the command answers with
// a hidden custom session entry
//
//     {type:"custom", customType:"pocketpi-control", data:{reqId, ok, data|error}}
//
// which pi announces on stdout as `entry_appended`. pocketpi matches the reqId
// to the waiting `POST /api/s/{key}/control` and hands `data` back, so to a
// client it looks like an ordinary command call. Custom entries never reach
// the model. pocketpi hides the /pp-* commands from the get_commands it relays.
//
// Why a session entry and not an HTTP call back to pocketpi: the reply goes
// down the same stdout pipe as everything else, so it needs no port, no URL
// and no auth, and it can't be confused with another pocketpi on the machine.

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

  // The chat's tools: all of them (name, description, where from) and which
  // are on. With args `{"active":["read","bash"]}`, turn exactly those on.
  command("pp-tools", "list this chat's tools, or set which are active", (args) => {
    if (args && Array.isArray(args.active)) {
      const known = new Set(pi.getAllTools().map((t: any) => t.name));
      const unknown = args.active.filter((n: unknown) => typeof n !== "string" || !known.has(n));
      if (unknown.length) throw new Error(`unknown tools: ${unknown.join(", ")}`);
      pi.setActiveTools(args.active);
    }
    const active = new Set(pi.getActiveTools());
    return {
      tools: pi.getAllTools().map((t: any) => ({
        name: t.name,
        description: t.description,
        exposure: t.exposure,
        source: t.sourceInfo?.source,
        path: t.sourceInfo?.path,
        active: active.has(t.name),
      })),
      active: [...active],
    };
  });
}
