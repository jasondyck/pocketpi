// A stand-in for pi's ExtensionAPI and context, for pocketpi-modes.ts tests.
// It records what the extension does (entries, messages, statuses, dialogs)
// and keeps a session as a flat list of entries, with `branch` naming the
// entries on the current branch (all of them unless a test says otherwise).

export type Entry = { type: string; customType?: string; data?: any; message?: any; id: string };

export function fakePi() {
  const handlers: Record<string, Function[]> = {};
  const commands: Record<string, any> = {};
  const tools: Record<string, any> = {};
  const entries: Entry[] = [];
  let branch: Entry[] | null = null; // null = every entry
  const sent: { message: any; options: any }[] = [];
  const userMessages: { text: string; options: any }[] = [];
  const status = new Map<string, string>();
  const dialogs: { method: string; title: string; options?: string[] }[] = [];
  /** Answers for the next dialogs, in order (undefined = dismissed). */
  const answers: (string | undefined)[] = [];
  let n = 0;
  let idle = true;

  const ui = {
    setStatus(key: string, text: string | undefined) { if (text === undefined) status.delete(key); else status.set(key, text); },
    async select(title: string, options: string[]) { dialogs.push({ method: "select", title, options }); return answers.shift(); },
    async input(title: string) { dialogs.push({ method: "input", title }); return answers.shift(); },
    notify() {},
  };
  const ctx = {
    hasUI: true,
    ui,
    isIdle: () => idle,
    sessionManager: {
      getEntries: () => entries,
      getBranch: () => branch ?? entries,
    },
  };

  const pi: any = {
    on(ev: string, h: Function) { (handlers[ev] ||= []).push(h); },
    registerCommand(name: string, opts: any) { commands[name] = opts; },
    registerTool(def: any) { tools[def.name] = def; },
    appendEntry(customType: string, data: any) { entries.push({ type: "custom", customType, data, id: `e${++n}` }); },
    sendMessage(message: any, options: any) { sent.push({ message, options }); },
    sendUserMessage(text: string, options: any) { userMessages.push({ text, options }); },
  };

  const api = {
    pi, ctx, ui, entries, sent, userMessages, status, dialogs, answers, tools, commands,
    setIdle(v: boolean) { idle = v; },
    setBranch(b: Entry[] | null) { branch = b; },
    async emit(ev: string, event: any = {}) {
      let out: any;
      for (const h of handlers[ev] || []) { const r = await h({ type: ev, ...event }, ctx); if (r !== undefined) out = r; }
      return out;
    },
    toolCall(toolName: string, input: any) { return api.emit("tool_call", { toolName, input, toolCallId: `t${++n}` }); },
    /** Runs a tool and, like pi, records its result as a toolResult entry. */
    async runTool(name: string, params: any) {
      const r = await tools[name].execute(`c${++n}`, params, undefined, undefined, ctx);
      entries.push({ type: "message", id: `e${++n}`, message: { role: "toolResult", toolName: name, details: r.details, isError: !!r.isError, content: r.content } });
      return r;
    },
    userMessage(text: string) { entries.push({ type: "message", id: `e${++n}`, message: { role: "user", content: text } }); },
    /** A pocketpi control command; returns its reply data (or throws its error). */
    async control(name: string, args?: any) {
      await commands[`pp-${name}`].handler(`r${++n}${args === undefined ? "" : " " + JSON.stringify(args)}`, ctx);
      const reply = [...entries].reverse().find((e) => e.customType === "pocketpi-control")!.data;
      if (!reply.ok) throw new Error(reply.error);
      return reply.data;
    },
    async startPrompt(prompt = "hi") {
      const opts = { sections: {} as Record<string, string> };
      await api.emit("before_agent_start", { messageType: "user", prompt, systemPromptOptions: opts, systemPrompt: "" });
      return opts.sections;
    },
    statusJSON(key: string) { const s = status.get(key); return s === undefined ? undefined : JSON.parse(s); },
    modeEntries() { return entries.filter((e) => e.customType === "pocketpi-mode"); },
  };
  return api;
}
