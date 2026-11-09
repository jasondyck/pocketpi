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

/** dsh's rule for @-mentions (docs/dsh-features-plan.md §3.5): the files
 * panel's `@` picker inserts a path only, and the model reads the file itself. */
export const FILE_REFERENCE_PROMPT =
  "Tokens prefixed with @ are paths the user explicitly referenced. Relative paths resolve from the working directory; absolute paths identify files or directories on the host. A trailing slash marks a directory: list it when its contents matter. Anything else is a file: use the read tool when its contents are needed, and do not claim to have inspected it before reading. @\"...\" quotes a path containing spaces.";

type Handler = (args: any, ctx: any) => Promise<unknown> | unknown;

export default function (pi: ExtensionAPI) {
  // The same section on every turn, so the prompt cache stays warm.
  pi.on("before_agent_start", async (event: any) => {
    const sections = event.systemPromptOptions?.sections;
    if (sections) sections.pocketpi_file_references = FILE_REFERENCE_PROMPT;
  });

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

  // Move to another point of the session tree (pi's /tree): args
  // `{"entryId": "…", "summarize": true, "instructions": "…"}`. In RPC mode
  // navigateTree answers only `{cancelled}`, not what goes back into the
  // editor, so this works it out the way pi does: a user message (or an
  // extension message) comes back to edit and resend, and the chat carries
  // on from the entry before it; anything else is carried on from.
  // Summarizing the branch being left needs a model and takes a while.
  command("pp-goto", "move to another point in the session tree", async (args, ctx) => {
    const id = args?.entryId;
    if (typeof id !== "string" || !id) throw new Error("entryId is required");
    const target = ctx.sessionManager.getEntry(id);
    if (!target) throw new Error(`Entry ${id} not found`);
    const instructions = typeof args.instructions === "string" && args.instructions.trim() ? args.instructions.trim() : undefined;
    const r = await ctx.navigateTree(id, { summarize: !!args.summarize, customInstructions: instructions });
    if (r?.cancelled) return { cancelled: true };
    let editorText: string | null = null;
    if (target.type === "message" && target.message?.role === "user") editorText = textOf(target.message.content);
    else if (target.type === "custom_message") editorText = textOf(target.content);
    return { cancelled: false, editorText, leafId: ctx.sessionManager.getLeafId() };
  });

  // Set (`{"entryId": "…", "label": "checkpoint"}`) or clear (no or an empty
  // label) an entry's label; get_tree reports labels on their entries.
  command("pp-label", "set or clear a label on a session entry", (args, ctx) => {
    const id = args?.entryId;
    if (typeof id !== "string" || !id) throw new Error("entryId is required");
    if (!ctx.sessionManager.getEntry(id)) throw new Error(`Entry ${id} not found`);
    const label = typeof args.label === "string" && args.label.trim() ? args.label.trim() : undefined;
    pi.setLabel(id, label);
    return { entryId: id, label: label ?? null };
  });
}

// pi's contentText(content, ""): a string, or its text blocks joined.
function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b: any) => b?.type === "text").map((b: any) => b.text ?? "").join("");
}
